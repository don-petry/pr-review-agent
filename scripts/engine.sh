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

# run_duck <prompt_file> <model>
# Cross-engine adversarial "rubber duck" review.
# Always uses the OPPOSITE engine from REVIEW_ENGINE. Output to stdout.
run_duck() {
  local prompt_file="$1"
  local model="$2"
  case "$DUCK_ENGINE" in
    claude)
      claude --print \
        --model "$model" \
        --permission-mode acceptEdits \
        --allowed-tools "Bash,Read,Grep,Glob" \
        --max-turns 25 \
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
