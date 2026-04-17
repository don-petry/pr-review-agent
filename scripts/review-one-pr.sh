#!/usr/bin/env bash
# Run the cascading PR review against ONE PR.
#
# Inputs:
#   $1 — PR URL
#
# Env:
#   GH_TOKEN              — set by the workflow
#   REVIEW_ENGINE         — "claude" or "copilot" (default: claude)
#   CLAUDE_CODE_OAUTH_TOKEN — (claude engine) set by the workflow
#   COPILOT_GITHUB_TOKEN    — (copilot engine) set by the workflow
#   DRY_RUN               — "true" or "false"
#
# Behavior:
#   1. Resolve current head SHA of the PR.
#   2. Idempotency check: scan existing reviews/comments for our marker
#      `<!-- pr-review-agent v1 sha=<SHA> -->`. If a marker for the current
#      head SHA exists, skip without spending tokens.
#   3. Run cascading review: triage → deep review → security audit.

set -euo pipefail

# Source the engine abstraction (sets ENGINE_* vars, defines run_triage/run_agentic).
SCRIPT_DIR="$(cd "$(dirname "${BASH_SOURCE[0]}")" && pwd)"
# shellcheck source=engine.sh
source "$SCRIPT_DIR/engine.sh"

PR_URL="${1:?usage: review-one-pr.sh <pr-url>}"
export PR_URL

echo "==> $PR_URL"

# 1. Current head SHA
PR_HEAD_SHA=$(gh pr view "$PR_URL" --json headRefOid --jq '.headRefOid')
export PR_HEAD_SHA
echo "    head SHA: $PR_HEAD_SHA"

# 1b. CI gate: skip PRs with failing or still-running checks.
#     We only spend review tokens on PRs where all checks are conclusive and green.
#     No checks at all (empty statusCheckRollup) is treated as passing.
CI_STATUS=$(gh pr view "$PR_URL" --json statusCheckRollup --jq '
  if (.statusCheckRollup | length) == 0 then "passing"
  elif ([.statusCheckRollup[] | select(
         .conclusion == "FAILURE" or
         .conclusion == "ACTION_REQUIRED" or
         .conclusion == "TIMED_OUT" or
         .conclusion == "CANCELLED"
       )] | length) > 0 then "failing"
  elif ([.statusCheckRollup[] | select(
         .status == "IN_PROGRESS" or
         .status == "QUEUED" or
         .status == "WAITING" or
         (.status == "COMPLETED" and (.conclusion == null or .conclusion == ""))
       )] | length) > 0 then "pending"
  else "passing"
  end
')
echo "    CI status: $CI_STATUS"
if [ "$CI_STATUS" = "failing" ]; then
  echo "    skip: CI checks are failing — will re-evaluate after fixes are pushed"
  echo "{\"pr\":\"$PR_URL\",\"sha\":\"$PR_HEAD_SHA\",\"decision\":\"skip\",\"reason\":\"ci-failing\"}"
  exit 100
fi
if [ "$CI_STATUS" = "pending" ]; then
  echo "    skip: CI checks still in progress — will re-evaluate when checks complete"
  echo "{\"pr\":\"$PR_URL\",\"sha\":\"$PR_HEAD_SHA\",\"decision\":\"skip\",\"reason\":\"ci-pending\"}"
  exit 100
fi

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
  # Exit 100 is the no-op sentinel: the caller can skip this PR without
  # counting it against the MAX_PRS budget of actual reviews.
  exit 100
fi

if [ -n "${EXISTING_MARKER_SHA:-}" ]; then
  echo "    re-review: prior marker was $EXISTING_MARKER_SHA, head is $PR_HEAD_SHA"
fi

# Count how many review cycles we've already done on this PR (number of distinct markers).
# This prevents infinite AI delegation loops.
REVIEW_CYCLE=$(
  gh pr view "$PR_URL" --json reviews,comments \
    --jq '((.reviews // []) + (.comments // [])) | .[].body | select(. != null)' 2>/dev/null \
  | grep -cE '<!-- pr-review-agent v1 sha=[a-f0-9]+' || echo 0
)
export REVIEW_CYCLE
echo "    review cycle: $REVIEW_CYCLE (max: ${MAX_REVIEW_CYCLES:-3})"

# Detect if the PR's repo org supports AI delegation for automated fix requests.
# Reads DELEGATION_ORGS (falls back to CLAUDE_ORGS for backward compat).
PR_ORG=$(echo "$PR_URL" | sed -E 's|https://github.com/([^/]+)/.*|\1|')
export PR_ORG
AI_DELEGATION_ENABLED=false
DELEGATION_ORGS="${DELEGATION_ORGS:-${CLAUDE_ORGS:-}}"
if [ -n "${DELEGATION_ORGS:-}" ]; then
  IFS=',' read -ra ORG_LIST <<< "$DELEGATION_ORGS"
  for org in "${ORG_LIST[@]}"; do
    if [ "$(echo "$org" | tr -d ' ')" = "$PR_ORG" ]; then
      AI_DELEGATION_ENABLED=true
      break
    fi
  done
fi
export AI_DELEGATION_ENABLED
echo "    AI delegation: $AI_DELEGATION_ENABLED (org: $PR_ORG)"

# For re-reviews, extract the prior review body for context.
# Write to a temp file to avoid hitting OS env size limits (E2BIG) on large reviews.
PRIOR_REVIEW_BODY=""
PRIOR_REVIEW_SHA=""
PRIOR_REVIEW_FILE="/tmp/cascade/prior-review-body.txt"
mkdir -p /tmp/cascade
if [ -n "${EXISTING_MARKER_SHA:-}" ]; then
  PRIOR_REVIEW_SHA="$EXISTING_MARKER_SHA"
  PRIOR_REVIEW_BODY=$(
    gh pr view "$PR_URL" --json reviews,comments \
      --jq "((.reviews // []) + (.comments // [])) | .[].body | select(. != null) | select(test(\"sha=$PRIOR_REVIEW_SHA\"))" 2>/dev/null \
    | tail -1 || true
  )
  # Validate that the matched body actually contains our marker to reduce
  # prompt-injection surface area.
  if [ -n "$PRIOR_REVIEW_BODY" ] && ! echo "$PRIOR_REVIEW_BODY" | grep -qE '<!-- pr-review-agent v1 sha=[a-f0-9]+ -->'; then
    echo "    prior review body missing valid marker, discarding"
    PRIOR_REVIEW_BODY=""
  fi
  echo "    prior review: SHA=$PRIOR_REVIEW_SHA body=${#PRIOR_REVIEW_BODY}chars"
  if [ -n "$PRIOR_REVIEW_BODY" ]; then
    echo "$PRIOR_REVIEW_BODY" > "$PRIOR_REVIEW_FILE"
  fi
fi
export PRIOR_REVIEW_SHA PRIOR_REVIEW_FILE
# Export a truncated summary for env; full body is in PRIOR_REVIEW_FILE.
export PRIOR_REVIEW_BODY="${PRIOR_REVIEW_BODY:0:4000}"

# ==========================================================================
# 3. Cascading review: triage → deep review → security audit
#    Each tier only fires if the previous one escalated.
# ==========================================================================

mkdir -p /tmp/cascade

# --- Tier 1: Triage (fast, no tools, pre-fetched context) ---
echo "    [tier1] triage ($ENGINE_TRIAGE_MODEL)"

# Pre-fetch all context so the triage tier needs no tool access.
PR_METADATA=$(gh pr view "$PR_URL" --json number,title,body,author,isDraft,baseRefName,headRefName,headRefOid,url,headRepository,headRepositoryOwner,labels,reviewDecision,mergeable,mergeStateStatus,statusCheckRollup,reviewRequests,reviews,comments,commits,closingIssuesReferences,additions,deletions,changedFiles,files 2>/dev/null || echo '{}')
export PR_METADATA

PR_DIFF=$(gh pr diff "$PR_URL" 2>/dev/null | head -3000 || echo "")
export PR_DIFF

export REVIEW_MODE="triage"

TRIAGE_LOG="/tmp/cascade/triage.log"
TRIAGE_RESULT=$(
  run_triage prompts/triage.md 2>"$TRIAGE_LOG"
) || true

# Unset large pre-fetched env vars now that triage has consumed them.
# PR_DIFF and PR_METADATA can be hundreds of KB; keeping them exported causes
# E2BIG (Argument list too long) when later subprocesses (jq, claude) are forked.
unset PR_DIFF PR_METADATA

# Detect rate limit before JSON validation — exit 2 so the caller can fall back
# to a different engine rather than burning through the remaining PR queue.
if is_rate_limited "$TRIAGE_RESULT"; then
  echo "    [tier1] rate limit detected — exiting with code 2 for engine fallback"
  echo "    rate limit message: $TRIAGE_RESULT"
  exit 2
fi

# Validate triage output is JSON
if ! echo "$TRIAGE_RESULT" | jq empty 2>/dev/null; then
  echo "    [tier1] triage returned non-JSON, escalating by default"
  echo "    triage output: $TRIAGE_RESULT"
  TRIAGE_RESULT='{"escalate":true,"risk":"MEDIUM","signals":["triage-output-invalid"],"summary":"triage failed, escalating"}'
fi

export TRIAGE_RESULT
TRIAGE_ESCALATE=$(echo "$TRIAGE_RESULT" | jq -r '.escalate')
TRIAGE_RISK=$(echo "$TRIAGE_RESULT" | jq -r '.risk')
TRIAGE_SIGNALS=$(echo "$TRIAGE_RESULT" | jq -r '.signals | join(", ")')
echo "    [tier1] escalate=$TRIAGE_ESCALATE risk=$TRIAGE_RISK signals=[$TRIAGE_SIGNALS]"

# If triage says no concerns → use single-review prompt for quick confirmation
if [ "$TRIAGE_ESCALATE" = "false" ]; then
  echo "    [approve] triage cleared — running single confirmation ($ENGINE_SINGLE_MODEL)"
  export REVIEW_MODE="triage-approved"
  run_agentic prompts/single-review.md "$ENGINE_SINGLE_MODEL"
  echo "    [done]  $PR_URL"
  exit 0
fi

# --- Tier 2: Deep review + Rubber duck (parallel, cross-engine) ---
echo "    [tier2] deep review ($ENGINE_DEEP_MODEL) + rubber duck ($DUCK_MODEL via $DUCK_ENGINE)"

# Launch both reviewers in parallel — different model families for diversity.
# Stdout (model text output) and stderr (process errors) are kept separate so
# the rate-limit check below inspects only the model's own words, not PR content
# or tool-execution noise that could cause false positives.
OUTPUT_FILE="/tmp/cascade/deep.json"
export OUTPUT_FILE
run_agentic prompts/deep-review.md "$ENGINE_DEEP_MODEL" \
  > /tmp/cascade/deep-stdout.txt 2>/tmp/cascade/deep.log &
DEEP_PID=$!

DUCK_OUTPUT="/tmp/cascade/rubber-duck.json"
(
  export OUTPUT_FILE="$DUCK_OUTPUT"
  run_duck prompts/rubber-duck.md "$DUCK_MODEL" \
    > /tmp/cascade/duck.log 2>&1
) &
DUCK_PID=$!

# Wait for deep review first — if it fails, kill the duck and exit early.
wait $DEEP_PID || true

# Validate primary deep review (required)
OUTPUT_FILE="/tmp/cascade/deep.json"
if [ ! -s "$OUTPUT_FILE" ] || ! jq empty "$OUTPUT_FILE" 2>/dev/null; then
  # Check the model's stdout for a rate-limit message.  We intentionally do NOT
  # check deep.log (stderr/process noise) to avoid false positives from PR diff
  # content that happens to mention rate-limiting in code or comments.
  DEEP_STDOUT_CONTENT=$(cat /tmp/cascade/deep-stdout.txt 2>/dev/null || true)
  kill $DUCK_PID 2>/dev/null || true
  wait $DUCK_PID 2>/dev/null || true
  if is_rate_limited "$DEEP_STDOUT_CONTENT"; then
    echo "    [tier2] rate limit detected — exiting with code 2 for engine fallback"
    echo "$DEEP_STDOUT_CONTENT"
    exit 2
  fi
  echo "::warning::deep review did not produce valid JSON at $OUTPUT_FILE"
  cat /tmp/cascade/deep-stdout.txt 2>/dev/null || true
  cat /tmp/cascade/deep.log 2>/dev/null || true
  echo "::error::cascade failed at tier 2 for $PR_URL"
  exit 1
fi

# Wait for duck to finish (deep succeeded)
wait $DUCK_PID || true

DEEP_DECISION=$(jq -r '.decision' "$OUTPUT_FILE")
DEEP_RISK=$(jq -r '.risk' "$OUTPUT_FILE")
echo "    [tier2] deep: decision=$DEEP_DECISION risk=$DEEP_RISK"

# Validate rubber duck (optional — graceful degradation if it fails)
DUCK_VALID=false
if [ -s "$DUCK_OUTPUT" ] && jq empty "$DUCK_OUTPUT" 2>/dev/null; then
  DUCK_DECISION=$(jq -r '.decision' "$DUCK_OUTPUT")
  DUCK_RISK=$(jq -r '.risk' "$DUCK_OUTPUT")
  DUCK_VALID=true
  echo "    [tier2] duck: decision=$DUCK_DECISION risk=$DUCK_RISK"
else
  echo "    [tier2] rubber duck did not produce valid JSON — continuing with deep review only"
  cat /tmp/cascade/duck.log 2>/dev/null || true
fi

# --- Tier 2b: Synthesize deep + duck verdicts ---
if [ "$DUCK_VALID" = "true" ]; then
  echo "    [tier2b] synthesizing deep + duck verdicts ($ENGINE_ACTION_MODEL)"
  DEEP_RESULT="/tmp/cascade/deep.json"
  DUCK_RESULT="$DUCK_OUTPUT"
  OUTPUT_FILE="/tmp/cascade/combined.json"
  export DEEP_RESULT DUCK_RESULT OUTPUT_FILE
  run_agentic prompts/synthesize-duck.md "$ENGINE_ACTION_MODEL" \
    > /tmp/cascade/synth.log 2>&1 || true

  if [ -s "$OUTPUT_FILE" ] && jq empty "$OUTPUT_FILE" 2>/dev/null; then
    COMBINED_DECISION=$(jq -r '.decision' "$OUTPUT_FILE")
    COMBINED_RISK=$(jq -r '.risk' "$OUTPUT_FILE")
    COMBINED_AGREEMENT=$(jq -r '.agreement' "$OUTPUT_FILE")
    COMBINED_ESCALATE=$(jq -r '.escalate_to_opus' "$OUTPUT_FILE")
    echo "    [tier2b] combined: decision=$COMBINED_DECISION risk=$COMBINED_RISK agreement=$COMBINED_AGREEMENT escalate_to_opus=$COMBINED_ESCALATE"
  else
    echo "    [tier2b] synthesis failed — falling back to deep review only"
    cat /tmp/cascade/synth.log 2>/dev/null || true
    OUTPUT_FILE="/tmp/cascade/deep.json"
    DUCK_VALID=false
    COMBINED_ESCALATE=$(jq -r '.escalate_to_opus' "$OUTPUT_FILE")
  fi
else
  OUTPUT_FILE="/tmp/cascade/deep.json"
  COMBINED_ESCALATE=$(jq -r '.escalate_to_opus' "$OUTPUT_FILE")
fi

# If tier 2 resolves without needing security audit → go straight to action
if [ "$COMBINED_ESCALATE" != "true" ]; then
  echo "    [action] tier 2 resolved — posting review"
  FINAL_RESULT="$OUTPUT_FILE"
  export FINAL_RESULT
  if [ "$DUCK_VALID" = "true" ]; then
    export FINAL_TIER="deep+duck"
  else
    export FINAL_TIER="deep"
  fi
  run_agentic prompts/cascade-action.md "$ENGINE_ACTION_MODEL"
  echo "    [done]  $PR_URL"
  exit 0
fi

# --- Tier 3: Security audit ---
echo "    [tier3] security audit ($ENGINE_AUDIT_MODEL)"
# TIER2_RESULT may point to combined.json (deep+duck) or deep.json (duck failed).
TIER2_RESULT="$OUTPUT_FILE"
export TIER2_RESULT
# Backward compat: security-audit.md reads $DEEP_RESULT
DEEP_RESULT="$TIER2_RESULT"
export DEEP_RESULT
OUTPUT_FILE="/tmp/cascade/audit.json"
export OUTPUT_FILE
run_agentic prompts/security-audit.md "$ENGINE_AUDIT_MODEL" \
  > /tmp/cascade/audit.log 2>&1

if [ ! -s "$OUTPUT_FILE" ] || ! jq empty "$OUTPUT_FILE" 2>/dev/null; then
  echo "::warning::security audit did not produce valid JSON at $OUTPUT_FILE"
  cat /tmp/cascade/audit.log || true
  echo "::error::cascade failed at tier 3 for $PR_URL"
  exit 1
fi

AUDIT_DECISION=$(jq -r '.decision' "$OUTPUT_FILE")
AUDIT_RISK=$(jq -r '.risk' "$OUTPUT_FILE")
echo "    [tier3] decision=$AUDIT_DECISION risk=$AUDIT_RISK"

# Security audit makes the final call — post the review
echo "    [action] security audit resolved — posting review"
FINAL_RESULT="$OUTPUT_FILE"
export FINAL_RESULT
export FINAL_TIER="audit"
run_agentic prompts/cascade-action.md "$ENGINE_ACTION_MODEL"

echo "    [done]  $PR_URL"
