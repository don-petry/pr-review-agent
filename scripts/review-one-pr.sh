#!/usr/bin/env bash
# Run the council + synthesizer against ONE PR.
#
# Inputs:
#   $1 — PR URL
#
# Env:
#   GH_TOKEN — set by the workflow
#   CLAUDE_CODE_OAUTH_TOKEN — set by the workflow
#   DRY_RUN — "true" or "false"
#
# Behavior:
#   1. Resolve current head SHA of the PR.
#   2. Idempotency check: scan existing reviews/comments for our marker
#      `<!-- pr-review-agent v1 sha=<SHA> -->`. If a marker for the current
#      head SHA exists, skip without spending tokens.
#   3. Otherwise: run 3 council members in parallel, each writing JSON to
#      /tmp/council/<lens>.json. Then run the synthesizer.

set -euo pipefail

PR_URL="${1:?usage: review-one-pr.sh <pr-url>}"
export PR_URL

echo "==> $PR_URL"

# 1. Current head SHA
PR_HEAD_SHA=$(gh pr view "$PR_URL" --json headRefOid --jq '.headRefOid')
export PR_HEAD_SHA
echo "    head SHA: $PR_HEAD_SHA"

# 2. Idempotency: look for our marker at this SHA in existing reviews+comments
# Extract the most recent SHA from our review marker in existing PR comments/reviews.
# Uses (array + array) to concatenate safely when either is empty, then iterates
# .body with null guard. The 2>/dev/null catches GraphQL field-access errors.
EXISTING_MARKER_SHA=$(
  gh pr view "$PR_URL" --json reviews,comments \
    --jq '((.reviews // []) + (.comments // [])) | .[].body | select(. != null)' 2>/dev/null \
  | grep -oE '<!-- pr-review-agent v1 sha=[a-f0-9]+' \
  | grep -oE '[a-f0-9]+$' \
  | tail -1 || true
)

if [ -n "${EXISTING_MARKER_SHA:-}" ] && [ "$EXISTING_MARKER_SHA" = "$PR_HEAD_SHA" ]; then
  echo "    noop: already reviewed at $PR_HEAD_SHA"
  echo "{\"pr\":\"$PR_URL\",\"sha\":\"$PR_HEAD_SHA\",\"decision\":\"noop\",\"reason\":\"already-reviewed-at-head\"}"
  exit 0
fi

if [ -n "${EXISTING_MARKER_SHA:-}" ]; then
  echo "    re-review: prior marker was $EXISTING_MARKER_SHA, head is $PR_HEAD_SHA"
fi

# Count how many review cycles we've already done on this PR (number of distinct markers).
# This prevents infinite @claude delegation loops.
REVIEW_CYCLE=$(
  gh pr view "$PR_URL" --json reviews,comments \
    --jq '((.reviews // []) + (.comments // [])) | .[].body | select(. != null)' 2>/dev/null \
  | grep -cE '<!-- pr-review-agent v1 sha=[a-f0-9]+' || echo 0
)
export REVIEW_CYCLE
echo "    review cycle: $REVIEW_CYCLE (max: ${MAX_REVIEW_CYCLES:-3})"

# Detect if the PR's repo org has Claude App (for @claude delegation).
PR_ORG=$(echo "$PR_URL" | sed -E 's|https://github.com/([^/]+)/.*|\1|')
export PR_ORG
CLAUDE_ENABLED=false
if [ -n "${CLAUDE_ORGS:-}" ]; then
  IFS=',' read -ra ORG_LIST <<< "$CLAUDE_ORGS"
  for org in "${ORG_LIST[@]}"; do
    if [ "$(echo "$org" | tr -d ' ')" = "$PR_ORG" ]; then
      CLAUDE_ENABLED=true
      break
    fi
  done
fi
export CLAUDE_ENABLED
echo "    claude delegation: $CLAUDE_ENABLED (org: $PR_ORG)"

# 3. Determine review mode based on PR size and prior review history.
#    - "small"       : PR has < SMALL_PR_THRESHOLD lines changed → single Opus call
#    - "incremental" : prior review exists at different SHA → single Opus call with prior context
#    - "full"        : first review of a non-small PR → 3-member council + synthesizer
SMALL_PR_THRESHOLD="${SMALL_PR_THRESHOLD:-10}"
PR_SIZE=$(gh pr view "$PR_URL" --json additions,deletions --jq '.additions + .deletions')
export PR_SIZE

if [ "$PR_SIZE" -lt "$SMALL_PR_THRESHOLD" ]; then
  REVIEW_MODE="small"
elif [ -n "${EXISTING_MARKER_SHA:-}" ]; then
  REVIEW_MODE="incremental"
else
  REVIEW_MODE="full"
fi
export REVIEW_MODE
echo "    mode: $REVIEW_MODE (${PR_SIZE} lines, threshold: $SMALL_PR_THRESHOLD)"

# For incremental mode, extract the prior review body so the single reviewer
# can see what was previously flagged and check if issues are resolved.
if [ "$REVIEW_MODE" = "incremental" ]; then
  PRIOR_REVIEW_SHA="$EXISTING_MARKER_SHA"
  export PRIOR_REVIEW_SHA
  # Extract the full body of the review/comment containing our marker for the prior SHA.
  PRIOR_REVIEW_BODY=$(
    gh pr view "$PR_URL" --json reviews,comments \
      --jq "((.reviews // []) + (.comments // [])) | .[].body | select(. != null) | select(test(\"sha=$PRIOR_REVIEW_SHA\"))" 2>/dev/null \
    | head -1 || true
  )
  export PRIOR_REVIEW_BODY
  echo "    prior review SHA: $PRIOR_REVIEW_SHA (body: ${#PRIOR_REVIEW_BODY} chars)"
fi

# --- Single-reviewer mode (small PR or incremental re-review) ---
if [ "$REVIEW_MODE" != "full" ]; then
  echo "    [single] opus (mode=$REVIEW_MODE)"
  claude \
    --print \
    --model claude-opus-4-6 \
    --permission-mode acceptEdits \
    --allowed-tools "Bash,Read,Grep,Glob" \
    < prompts/single-review.md
  echo "    [done]  $PR_URL"
  exit 0
fi

# --- Full council mode (first review of a non-small PR) ---
mkdir -p /tmp/council
rm -f /tmp/council/*.json /tmp/council/*.log

run_member() {
  local lens="$1"
  local model="$2"
  local prompt_path="$3"
  local out="/tmp/council/${lens}.json"
  local log="/tmp/council/${lens}.log"
  local prompt_file="/tmp/council/${lens}.prompt"

  cat prompts/shared.md "$prompt_path" > "$prompt_file"
  local prompt_bytes
  prompt_bytes=$(wc -c < "$prompt_file")
  echo "    [start] $lens ($model) prompt=${prompt_bytes}b"

  LENS="$lens" \
  OUTPUT_FILE="$out" \
  claude \
    --print \
    --model "$model" \
    --permission-mode acceptEdits \
    --allowed-tools "Bash,Read,Grep,Glob" \
    < "$prompt_file" \
    > "$log" 2>&1
  local rc=$?
  echo "    [done]  $lens (rc=$rc)"
  return $rc
}

run_member security        claude-opus-4-6           prompts/council/security.md        &
PID_SEC=$!
run_member correctness     claude-sonnet-4-6         prompts/council/correctness.md     &
PID_COR=$!
run_member maintainability claude-sonnet-4-6 prompts/council/maintainability.md &
PID_MAI=$!

FAILED=0
wait "$PID_SEC" || { echo "::warning::security council member failed"; FAILED=1; }
wait "$PID_COR" || { echo "::warning::correctness council member failed"; FAILED=1; }
wait "$PID_MAI" || { echo "::warning::maintainability council member failed"; FAILED=1; }

# Verify each member produced parseable JSON
for lens in security correctness maintainability; do
  f="/tmp/council/${lens}.json"
  if [ ! -s "$f" ]; then
    echo "::warning::$lens did not produce $f"
    echo "--- $lens log ---"
    cat "/tmp/council/${lens}.log" || true
    FAILED=1
  elif ! jq empty "$f" 2>/dev/null; then
    echo "::warning::$lens produced invalid JSON in $f"
    cat "$f"
    FAILED=1
  fi
done

if [ "$FAILED" -ne 0 ]; then
  echo "::error::council had failures, skipping synthesis for $PR_URL"
  exit 1
fi

# 4. Synthesize and (maybe) post
echo "    [synth]"
claude \
  --print \
  --model claude-sonnet-4-6 \
  --permission-mode acceptEdits \
  --allowed-tools "Bash,Read,Grep,Glob" \
  < prompts/synthesize.md

echo "    [done]  $PR_URL"
