#!/usr/bin/env bash
# Run the adversarial feature ideation loop against ONE GitHub issue.
#
# Inputs:
#   $1 or $ISSUE_URL_OVERRIDE — issue URL
#
# Env:
#   GH_TOKEN — set by the workflow
#   CLAUDE_CODE_OAUTH_TOKEN — set by the workflow
#   DRY_RUN — "true" or "false"
#
# Flow:
#   1. Resolve issue metadata and check idempotency.
#   2. Proposer (Sonnet): expands the idea into a full proposal.
#   3. Challenger (Sonnet): adversarially challenges the proposal.
#   4. Synthesizer (Opus): reconciles and posts the refined spec to the issue.

set -euo pipefail

ISSUE_URL="${ISSUE_URL_OVERRIDE:-${1:?usage: ideate-feature.sh <issue-url>}}"
export ISSUE_URL

echo "==> $ISSUE_URL"

# 1. Resolve issue metadata
ISSUE_JSON=$(gh issue view "$ISSUE_URL" \
  --json number,title,body,state,labels,comments,url,repository \
  2>/dev/null)

ISSUE_NUM=$(echo "$ISSUE_JSON" | jq -r '.number')
ISSUE_TITLE=$(echo "$ISSUE_JSON" | jq -r '.title')
ISSUE_BODY=$(echo "$ISSUE_JSON" | jq -r '.body // ""')
ISSUE_STATE=$(echo "$ISSUE_JSON" | jq -r '.state')
REPO=$(echo "$ISSUE_JSON" | jq -r '.repository.nameWithOwner')

export ISSUE_NUM ISSUE_TITLE ISSUE_BODY ISSUE_STATE REPO

echo "    issue #$ISSUE_NUM: $ISSUE_TITLE"
echo "    repo:  $REPO"
echo "    state: $ISSUE_STATE"

# Skip closed issues
if [ "$ISSUE_STATE" = "CLOSED" ]; then
  echo "    skip: issue is closed"
  exit 0
fi

# 2. Idempotency: count prior ideation cycles from existing comments
ISSUE_IDEATION_CYCLE=$(
  echo "$ISSUE_JSON" \
  | jq -r '.comments[].body | select(. != null)' 2>/dev/null \
  | grep -cE '<!-- feature-ideation-agent v1 issue=[0-9]+ cycle=[0-9]+ -->' \
  || echo 0
)
ISSUE_IDEATION_CYCLE=$(( ISSUE_IDEATION_CYCLE + 1 ))
export ISSUE_IDEATION_CYCLE

# Check if we already ran this cycle (same comment already exists)
EXISTING_CYCLE=$(
  echo "$ISSUE_JSON" \
  | jq -r '.comments[].body | select(. != null)' 2>/dev/null \
  | grep -oE "<!-- feature-ideation-agent v1 issue=${ISSUE_NUM} cycle=[0-9]+ -->" \
  | grep -oE 'cycle=[0-9]+' \
  | grep -oE '[0-9]+$' \
  | sort -n \
  | tail -1 \
  || echo 0
)

if [ "$EXISTING_CYCLE" -ge "$ISSUE_IDEATION_CYCLE" ] 2>/dev/null; then
  echo "    noop: already ran ideation cycle $EXISTING_CYCLE for issue #$ISSUE_NUM"
  echo "{\"issue\":\"$ISSUE_URL\",\"decision\":\"noop\",\"reason\":\"already-ran-cycle-$EXISTING_CYCLE\"}"
  exit 0
fi

echo "    ideation cycle: $ISSUE_IDEATION_CYCLE"

# 3. Set up working directory
mkdir -p /tmp/ideation
PROPOSER_OUTPUT="/tmp/ideation/proposal.json"
CHALLENGER_OUTPUT="/tmp/ideation/challenges.json"
export PROPOSER_OUTPUT CHALLENGER_OUTPUT

# --- Stage 1: Proposer (Sonnet) ---
echo "    [stage1] proposer (sonnet)"
PROPOSER_LOG="/tmp/ideation/proposer.log"

claude \
  --print \
  --model claude-sonnet-4-6 \
  --permission-mode acceptEdits \
  --allowed-tools "Bash,Read,Grep,Glob" \
  < prompts/ideation/proposer.md \
  > "$PROPOSER_LOG" 2>&1 || true

if [ ! -s "$PROPOSER_OUTPUT" ] || ! jq empty "$PROPOSER_OUTPUT" 2>/dev/null; then
  echo "::warning::proposer did not produce valid JSON at $PROPOSER_OUTPUT"
  cat "$PROPOSER_LOG" || true
  echo "::error::ideation failed at stage 1 for $ISSUE_URL"
  exit 1
fi

PROPOSAL_TITLE=$(jq -r '.title' "$PROPOSER_OUTPUT")
echo "    [stage1] proposal: $PROPOSAL_TITLE"

# --- Stage 2: Challenger (Sonnet) ---
echo "    [stage2] challenger (sonnet)"
CHALLENGER_LOG="/tmp/ideation/challenger.log"

claude \
  --print \
  --model claude-sonnet-4-6 \
  --permission-mode acceptEdits \
  --allowed-tools "Bash,Read,Grep,Glob" \
  < prompts/ideation/challenger.md \
  > "$CHALLENGER_LOG" 2>&1 || true

if [ ! -s "$CHALLENGER_OUTPUT" ] || ! jq empty "$CHALLENGER_OUTPUT" 2>/dev/null; then
  echo "::warning::challenger did not produce valid JSON at $CHALLENGER_OUTPUT"
  cat "$CHALLENGER_LOG" || true
  echo "::error::ideation failed at stage 2 for $ISSUE_URL"
  exit 1
fi

CHALLENGE_VERDICT=$(jq -r '.overall_verdict' "$CHALLENGER_OUTPUT")
echo "    [stage2] verdict: $CHALLENGE_VERDICT"

# --- Stage 3: Synthesizer (Opus) ---
echo "    [stage3] synthesizer (opus)"

claude \
  --print \
  --model claude-opus-4-6 \
  --permission-mode acceptEdits \
  --allowed-tools "Bash,Read,Grep,Glob" \
  < prompts/ideation/synthesize-idea.md

echo "    [done]  $ISSUE_URL"
