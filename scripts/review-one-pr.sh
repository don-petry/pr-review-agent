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

# For re-reviews, extract the prior review body for context.
PRIOR_REVIEW_BODY=""
PRIOR_REVIEW_SHA=""
if [ -n "${EXISTING_MARKER_SHA:-}" ]; then
  PRIOR_REVIEW_SHA="$EXISTING_MARKER_SHA"
  PRIOR_REVIEW_BODY=$(
    gh pr view "$PR_URL" --json reviews,comments \
      --jq "((.reviews // []) + (.comments // [])) | .[].body | select(. != null) | select(test(\"sha=$PRIOR_REVIEW_SHA\"))" 2>/dev/null \
    | head -1 || true
  )
  echo "    prior review: SHA=$PRIOR_REVIEW_SHA body=${#PRIOR_REVIEW_BODY}chars"
fi
export PRIOR_REVIEW_BODY PRIOR_REVIEW_SHA

# ==========================================================================
# 3. Cascading review: Haiku triage → Sonnet deep review → Opus security audit
#    Each tier only fires if the previous one escalated.
# ==========================================================================

mkdir -p /tmp/cascade

# --- Tier 1: Haiku triage (no tools, pre-fetched context) ---
echo "    [tier1] haiku triage"

# Pre-fetch all context so Haiku needs no tool access.
PR_METADATA=$(gh pr view "$PR_URL" --json number,title,body,author,isDraft,baseRefName,headRefName,headRefOid,url,repository,labels,reviewDecision,mergeable,mergeStateStatus,statusCheckRollup,reviewRequests,reviews,comments,commits,closingIssuesReferences,additions,deletions,changedFiles,files 2>/dev/null || echo '{}')
export PR_METADATA

PR_DIFF=$(gh pr diff "$PR_URL" 2>/dev/null | head -3000 || echo "")
export PR_DIFF

export REVIEW_MODE="triage"

TRIAGE_LOG="/tmp/cascade/triage.log"
TRIAGE_RESULT=$(
  claude \
    --print \
    --model claude-haiku-4-5-20251001 \
    --permission-mode plan \
    < prompts/triage.md 2>"$TRIAGE_LOG"
) || true

# Validate triage output is JSON
if ! echo "$TRIAGE_RESULT" | jq empty 2>/dev/null; then
  echo "    [tier1] haiku returned non-JSON, escalating by default"
  echo "    haiku output: $TRIAGE_RESULT"
  TRIAGE_RESULT='{"escalate":true,"risk":"MEDIUM","signals":["triage-output-invalid"],"summary":"triage failed, escalating"}'
fi

export TRIAGE_RESULT
TRIAGE_ESCALATE=$(echo "$TRIAGE_RESULT" | jq -r '.escalate')
TRIAGE_RISK=$(echo "$TRIAGE_RESULT" | jq -r '.risk')
TRIAGE_SIGNALS=$(echo "$TRIAGE_RESULT" | jq -r '.signals | join(", ")')
echo "    [tier1] escalate=$TRIAGE_ESCALATE risk=$TRIAGE_RISK signals=[$TRIAGE_SIGNALS]"

# If triage says no concerns → use single-review prompt (Haiku approved, Opus confirms briefly)
if [ "$TRIAGE_ESCALATE" = "false" ]; then
  echo "    [approve] haiku cleared — running single Opus confirmation"
  export REVIEW_MODE="triage-approved"
  claude \
    --print \
    --model claude-opus-4-6 \
    --permission-mode acceptEdits \
    --allowed-tools "Bash,Read,Grep,Glob" \
    < prompts/single-review.md
  echo "    [done]  $PR_URL"
  exit 0
fi

# --- Tier 2: Sonnet deep review ---
echo "    [tier2] sonnet deep review"
OUTPUT_FILE="/tmp/cascade/sonnet.json"
export OUTPUT_FILE
claude \
  --print \
  --model claude-sonnet-4-6 \
  --permission-mode acceptEdits \
  --allowed-tools "Bash,Read,Grep,Glob" \
  < prompts/deep-review.md \
  > /tmp/cascade/sonnet.log 2>&1
SONNET_RC=$?

if [ ! -s "$OUTPUT_FILE" ] || ! jq empty "$OUTPUT_FILE" 2>/dev/null; then
  echo "::warning::sonnet did not produce valid JSON at $OUTPUT_FILE"
  cat /tmp/cascade/sonnet.log || true
  echo "::error::cascade failed at tier 2 for $PR_URL"
  exit 1
fi

SONNET_ESCALATE=$(jq -r '.escalate_to_opus' "$OUTPUT_FILE")
SONNET_DECISION=$(jq -r '.decision' "$OUTPUT_FILE")
SONNET_RISK=$(jq -r '.risk' "$OUTPUT_FILE")
echo "    [tier2] escalate_to_opus=$SONNET_ESCALATE decision=$SONNET_DECISION risk=$SONNET_RISK"

# If Sonnet approves or escalates without needing Opus → go straight to action
if [ "$SONNET_ESCALATE" != "true" ]; then
  echo "    [action] sonnet resolved — posting review"
  FINAL_RESULT="$OUTPUT_FILE"
  export FINAL_RESULT
  export FINAL_TIER="sonnet"
  claude \
    --print \
    --model claude-sonnet-4-6 \
    --permission-mode acceptEdits \
    --allowed-tools "Bash,Read,Grep,Glob" \
    < prompts/cascade-action.md
  echo "    [done]  $PR_URL"
  exit 0
fi

# --- Tier 3: Opus security audit ---
echo "    [tier3] opus security audit"
SONNET_RESULT="$OUTPUT_FILE"
export SONNET_RESULT
OUTPUT_FILE="/tmp/cascade/opus.json"
export OUTPUT_FILE
claude \
  --print \
  --model claude-opus-4-6 \
  --permission-mode acceptEdits \
  --allowed-tools "Bash,Read,Grep,Glob" \
  < prompts/security-audit.md \
  > /tmp/cascade/opus.log 2>&1

if [ ! -s "$OUTPUT_FILE" ] || ! jq empty "$OUTPUT_FILE" 2>/dev/null; then
  echo "::warning::opus did not produce valid JSON at $OUTPUT_FILE"
  cat /tmp/cascade/opus.log || true
  echo "::error::cascade failed at tier 3 for $PR_URL"
  exit 1
fi

OPUS_DECISION=$(jq -r '.decision' "$OUTPUT_FILE")
OPUS_RISK=$(jq -r '.risk' "$OUTPUT_FILE")
echo "    [tier3] decision=$OPUS_DECISION risk=$OPUS_RISK"

# Opus makes the final call — post the review
echo "    [action] opus resolved — posting review"
FINAL_RESULT="$OUTPUT_FILE"
export FINAL_RESULT
export FINAL_TIER="opus"
claude \
  --print \
  --model claude-sonnet-4-6 \
  --permission-mode acceptEdits \
  --allowed-tools "Bash,Read,Grep,Glob" \
  < prompts/cascade-action.md

echo "    [done]  $PR_URL"
