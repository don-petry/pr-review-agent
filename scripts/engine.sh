#!/usr/bin/env bash
# Engine abstraction layer for LLM invocations.
# Supports: claude, copilot
#
# Sourced by review-one-pr.sh — provides:
#   run_triage <prompt_file>       — no-tool tier (stdout capture)
#   run_agentic <prompt_file> <model>  — full-tool tier (stdout)
#   run_duck <prompt_file> <model>     — cross-engine adversarial (stdout)
#   ENGINE_* env vars for model names and labels
#   DUCK_ENGINE / DUCK_MODEL for rubber-duck cross-engine review

REVIEW_ENGINE="${REVIEW_ENGINE:-claude}"
export REVIEW_ENGINE

case "$REVIEW_ENGINE" in
  claude)
    ENGINE_TRIAGE_MODEL="claude-haiku-4-5-20251001"
    ENGINE_DEEP_MODEL="claude-sonnet-4-6"
    ENGINE_AUDIT_MODEL="claude-opus-4-6"
    ENGINE_ACTION_MODEL="claude-sonnet-4-6"
    ENGINE_SINGLE_MODEL="claude-opus-4-6"
    ENGINE_LABEL="triage: haiku 4.5 → deep: sonnet 4.6 + duck: gpt-5.4 → audit: opus 4.6"
    ENGINE_SINGLE_LABEL="single-reviewer mode: opus 4.6"
    # Cross-engine rubber duck: always the opposite engine
    DUCK_ENGINE="copilot"
    DUCK_MODEL="gpt-5.4"
    ;;
  copilot)
    ENGINE_TRIAGE_MODEL="gpt-5-mini"
    ENGINE_DEEP_MODEL="gpt-5.2"
    ENGINE_AUDIT_MODEL="gpt-5.4"
    ENGINE_ACTION_MODEL="gpt-5.2"
    ENGINE_SINGLE_MODEL="gpt-5.4"
    ENGINE_LABEL="triage: gpt-5-mini → deep: gpt-5.2 + duck: sonnet 4.6 → audit: gpt-5.4"
    ENGINE_SINGLE_LABEL="single-reviewer mode: gpt-5.4"
    # Cross-engine rubber duck: always the opposite engine
    DUCK_ENGINE="claude"
    DUCK_MODEL="claude-sonnet-4-6"
    ;;
  *)
    echo "::error::Unknown REVIEW_ENGINE='$REVIEW_ENGINE' (expected: claude or copilot)"
    exit 1
    ;;
esac

export ENGINE_TRIAGE_MODEL ENGINE_DEEP_MODEL ENGINE_AUDIT_MODEL
export ENGINE_ACTION_MODEL ENGINE_SINGLE_MODEL
export ENGINE_LABEL ENGINE_SINGLE_LABEL
export DUCK_ENGINE DUCK_MODEL

echo "    engine: $REVIEW_ENGINE ($ENGINE_LABEL)"

# is_rate_limited <text>
# Returns 0 (true) if the text looks like a Claude or Copilot rate-limit message.
# review-one-pr.sh exits with code 2 when this fires so the caller can switch engines.
is_rate_limited() {
  local text="$1"
  echo "$text" | grep -qiE "(hit your limit|rate[ -]?limit|resets [0-9]+(am|pm)|usage limit|quota exceeded|too many requests|exceeded.*quota)"
}

# run_triage <prompt_file>
# No-tool mode: reads pre-fetched context from env vars only.
# Captures stdout (the model's JSON response).
run_triage() {
  local prompt_file="$1"
  case "$REVIEW_ENGINE" in
    claude)
      claude --print \
        --model "$ENGINE_TRIAGE_MODEL" \
        --permission-mode plan \
        < "$prompt_file"
      ;;
    copilot)
      copilot \
        -p "$(cat "$prompt_file")" \
        --model "$ENGINE_TRIAGE_MODEL" \
        -s --no-ask-user
      ;;
  esac
}

# run_agentic <prompt_file> <model>
# Full tool access (Bash, Read, Grep, Glob). Output to stdout.
run_agentic() {
  local prompt_file="$1"
  local model="$2"
  case "$REVIEW_ENGINE" in
    claude)
      claude --print \
        --model "$model" \
        --permission-mode acceptEdits \
        --allowed-tools "Bash,Read,Grep,Glob" \
        < "$prompt_file"
      ;;
    copilot)
      copilot \
        -p "$(cat "$prompt_file")" \
        --model "$model" \
        -s --allow-all --no-ask-user
      ;;
  esac
}

# extract_verdict_json <raw_file> <dest_file>
# Resolves the verdict JSON from an agentic run, handling two output styles:
#   1. Agent wrote JSON to $dest via Bash tool (dest already valid — use it as-is).
#   2. Agent printed JSON to stdout captured in raw_file (scan for first valid
#      JSON object containing a 'decision' field, ignoring preamble text).
extract_verdict_json() {
  local raw="$1" dest="$2"
  # Style 1: agent wrote to $dest via Bash tool (our stdout redirect didn't clobber it).
  if jq empty "$dest" 2>/dev/null; then
    return 0
  fi
  # Style 2: agent printed JSON to stdout.
  if jq empty "$raw" 2>/dev/null; then
    cp "$raw" "$dest"
    return 0
  fi
  python3 -c "
import sys, json
text = open(sys.argv[1]).read()
decoder = json.JSONDecoder()
pos = text.find('{')
while pos >= 0:
    try:
        obj, _ = decoder.raw_decode(text, pos)
        if isinstance(obj, dict) and 'decision' in obj:
            print(json.dumps(obj))
            sys.exit(0)
    except Exception:
        pass
    pos = text.find('{', pos + 1)
sys.exit(1)
" "$raw" > "$dest" 2>/dev/null
}

# run_duck <prompt_file> <model>
# Cross-engine adversarial "rubber duck" review.
# Always uses the OPPOSITE engine from REVIEW_ENGINE. Output to stdout.
# Strips the opposing engine's credentials to prevent cross-engine leakage.
run_duck() {
  local prompt_file="$1"
  local model="$2"
  case "$DUCK_ENGINE" in
    claude)
      unset COPILOT_GITHUB_TOKEN 2>/dev/null || true
      timeout 300 claude --print \
        --model "$model" \
        --permission-mode acceptEdits \
        --allowed-tools "Bash,Read,Grep,Glob" \
        --max-turns 25 \
        < "$prompt_file"
      ;;
    copilot)
      unset CLAUDE_CODE_OAUTH_TOKEN 2>/dev/null || true
      timeout 300 copilot \
        -p "$(cat "$prompt_file")" \
        --model "$model" \
        -s --allow-all --no-ask-user
      ;;
    *)
      echo "::error::Unknown DUCK_ENGINE='$DUCK_ENGINE'" >&2
      return 1
      ;;
  esac
}
