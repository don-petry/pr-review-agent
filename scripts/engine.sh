#!/usr/bin/env bash
set -euo pipefail
# Engine abstraction layer for LLM invocations.
# Supports: claude, gemini, copilot
#
# Sourced by review-one-pr.sh — provides:
#   run_triage <prompt_file>       — no-tool tier (stdout capture)
#   run_agentic <prompt_file> <model>  — full-tool tier (stdout)
#   run_duck <prompt_file> <model>     — cross-engine adversarial (stdout)
#   ENGINE_* env vars for model names and labels
#   DUCK_ENGINE / DUCK_MODEL for rubber-duck cross-engine review

REVIEW_ENGINE="${REVIEW_ENGINE:-claude}"
export REVIEW_ENGINE

# Per-tier timeouts (seconds). The job-level 60min cap is a backstop — without
# per-tier timeouts a single hung model invocation burns the whole hour and
# blocks every subsequent PR in the session.
TRIAGE_TIMEOUT_SEC="${TRIAGE_TIMEOUT_SEC:-300}"
DEEP_TIMEOUT_SEC="${DEEP_TIMEOUT_SEC:-600}"
AUDIT_TIMEOUT_SEC="${AUDIT_TIMEOUT_SEC:-600}"
ACTION_TIMEOUT_SEC="${ACTION_TIMEOUT_SEC:-300}"
DUCK_TIMEOUT_SEC="${DUCK_TIMEOUT_SEC:-300}"

# Retry config for transient errors. We treat exit codes that look like
# network/process flakiness (124=GNU timeout, 137/143=signal kills, plus a
# couple of generic transient codes) as retryable. Rate-limit (engine-level)
# is NOT retryable here — the workflow's engine-fallback handles that.
RETRY_MAX_ATTEMPTS="${RETRY_MAX_ATTEMPTS:-2}"   # total attempts including first
RETRY_BASE_DELAY_SEC="${RETRY_BASE_DELAY_SEC:-5}"

case "$REVIEW_ENGINE" in
  claude)
    ENGINE_TRIAGE_MODEL="claude-haiku-4-5-20251001"
    ENGINE_DEEP_MODEL="claude-sonnet-4-6"
    ENGINE_AUDIT_MODEL="claude-opus-4-7"
    ENGINE_ACTION_MODEL="claude-sonnet-4-6"
    ENGINE_SINGLE_MODEL="claude-opus-4-7"
    ENGINE_LABEL="triage: haiku 4.5 → deep: sonnet 4.6 + duck: o4-mini → audit: opus 4.7"
    ENGINE_SINGLE_LABEL="single-reviewer mode: opus 4.7"
    # Cross-engine rubber duck: always the opposite engine
    DUCK_ENGINE="copilot"
    DUCK_MODEL="o4-mini"
    ;;
  gemini)
    ENGINE_TRIAGE_MODEL="gemini-2.0-flash"
    ENGINE_DEEP_MODEL="gemini-1.5-pro"
    ENGINE_AUDIT_MODEL="gemini-1.5-pro"
    ENGINE_ACTION_MODEL="gemini-1.5-pro"
    ENGINE_SINGLE_MODEL="gemini-1.5-pro"
    ENGINE_LABEL="triage: gemini-2.0-flash → deep: gemini-1.5-pro + duck: sonnet 4.6 → audit: gemini-1.5-pro"
    ENGINE_SINGLE_LABEL="single-reviewer mode: gemini-1.5-pro"
    # Cross-engine rubber duck: use Claude for diversity
    DUCK_ENGINE="claude"
    DUCK_MODEL="claude-sonnet-4-6"
    ;;
  copilot)
    ENGINE_TRIAGE_MODEL="o4-mini"
    ENGINE_DEEP_MODEL="o4-mini"
    ENGINE_AUDIT_MODEL="o4-mini"
    ENGINE_ACTION_MODEL="o4-mini"
    ENGINE_SINGLE_MODEL="o4-mini"
    ENGINE_LABEL="triage: o4-mini → deep: o4-mini + duck: sonnet 4.6 → audit: o4-mini"
    ENGINE_SINGLE_LABEL="single-reviewer mode: o4-mini"
    # Cross-engine rubber duck: always the opposite engine
    DUCK_ENGINE="claude"
    DUCK_MODEL="claude-sonnet-4-6"
    ;;
  *)
    echo "::error::Unknown REVIEW_ENGINE='$REVIEW_ENGINE' (expected: claude, gemini, or copilot)"
    exit 1
    ;;
esac

export ENGINE_TRIAGE_MODEL ENGINE_DEEP_MODEL ENGINE_AUDIT_MODEL
export ENGINE_ACTION_MODEL ENGINE_SINGLE_MODEL
export ENGINE_LABEL ENGINE_SINGLE_LABEL
export DUCK_ENGINE DUCK_MODEL

echo "    engine: $REVIEW_ENGINE ($ENGINE_LABEL)"

# is_rate_limited <text>
# Returns 0 (true) if the text looks like a provider usage/rate-limit block —
# API-level (429), subscription/billing caps (plan limit, out of tokens, HTTP 402),
# or service overload acting as a hard block (529).
# review-one-pr.sh exits with code 2 when this fires so the caller can switch engines.
is_rate_limited() {
  local text="$1"
  echo "$text" | grep -qiE \
    "(hit your limit|rate[ -]?limit|resets [0-9]+(am|pm)|usage limit|quota exceeded|too many requests|exceeded.*quota|([^0-9]|^)429([^0-9]|$)|exhausted|out of.*token|token.*exhaust|claude.*usage|usage.*claude|plan.*limit|subscription.*limit|billing.*limit|daily.*limit|monthly.*limit|([^0-9]|^)402([^0-9]|$)|([^0-9]|^)529([^0-9]|$))"
}

# is_transient_failure <exit_code>
# Returns 0 (true) for exit codes suggesting a flaky network/process state:
# 124 (GNU timeout) and 137/143 (signal kills). JSON parse failures and
# generic exit-1s are NOT retried — those are deterministic problems.
is_transient_failure() {
  local rc="$1"
  case "$rc" in
    124|137|143) return 0 ;;
    *)           return 1 ;;
  esac
}

# run_triage <prompt_file>
# No-tool mode. The prompt file already has all PR context inlined by the
# caller (review-one-pr.sh builds it). Every tool is denied so the model
# can't wander into the working directory and discover prs.txt or other
# state.
#
# `--permission-mode plan` is intentionally NOT set — under --print it makes
# the model propose a plan and ask for approval, which surfaces as
# conversational text and breaks the JSON contract. With every tool denied,
# permission mode is moot anyway.
#
# Wrapped in a transient-retry loop because the caller captures stdout via
# $(...), so re-running on a timeout/kill is safe — the variable receives only
# the last attempt's output. Per-tier timeout from TRIAGE_TIMEOUT_SEC.
run_triage() {
  local prompt_file="$1"
  local attempt=1 rc=0
  while [ "$attempt" -le "$RETRY_MAX_ATTEMPTS" ]; do
    rc=0
    case "$REVIEW_ENGINE" in
      claude)
        timeout "$TRIAGE_TIMEOUT_SEC" claude --print \
          --model "$ENGINE_TRIAGE_MODEL" \
          --disallowed-tools "Bash,Read,Write,Edit,Grep,Glob,WebFetch,WebSearch,Task,TodoWrite,NotebookEdit" \
          < "$prompt_file" || rc=$?
        ;;
      gemini)
        timeout "$TRIAGE_TIMEOUT_SEC" gemini --prompt "" \
          --model "$ENGINE_TRIAGE_MODEL" \
          --approval-mode auto_edit \
          --output-format text \
          < "$prompt_file" || rc=$?
        ;;
      copilot)
        # gh copilot is now a built-in; auth via GH_PAT (user token with Copilot subscription).
        # Model selection is not supported by gh copilot suggest — uses Copilot's default.
        ( export GH_TOKEN="$COPILOT_GITHUB_TOKEN"
          timeout "$TRIAGE_TIMEOUT_SEC" gh copilot suggest -p "$(cat "$prompt_file")"
        ) || rc=$?
        ;;
    esac
    if [ "$rc" -eq 0 ]; then
      return 0
    fi
    if [ "$attempt" -lt "$RETRY_MAX_ATTEMPTS" ] && is_transient_failure "$rc"; then
      local delay=$(( RETRY_BASE_DELAY_SEC * (2 ** (attempt - 1)) ))
      echo "    [triage] transient failure (exit $rc), retrying in ${delay}s (attempt $((attempt + 1))/$RETRY_MAX_ATTEMPTS)" >&2
      sleep "$delay"
      attempt=$((attempt + 1))
      continue
    fi
    return "$rc"
  done
  return "$rc"
}

# run_agentic <prompt_file> <model>
# Full tool access (Bash, Read, Grep, Glob). Output to stdout.
#
# No retry here: callers redirect stdout to a file, so a retry inside this
# function would append the second attempt's output to a partial first-attempt
# file. Transient failures here become session-fatal via the workflow circuit
# breaker — that's the intended trade-off for the long, expensive tier.
# Per-tier timeout from DEEP_TIMEOUT_SEC (also applies to action/audit calls;
# they're all the same agentic shape and similarly priced).
run_agentic() {
  local prompt_file="$1"
  local model="$2"
  case "$REVIEW_ENGINE" in
    claude)
      timeout "$DEEP_TIMEOUT_SEC" claude --print \
        --model "$model" \
        --permission-mode acceptEdits \
        --allowed-tools "Bash,Read,Grep,Glob" \
        < "$prompt_file"
      ;;
    gemini)
      timeout "$DEEP_TIMEOUT_SEC" gemini --prompt "" \
        --model "$model" \
        --approval-mode auto_edit \
        --output-format text \
        < "$prompt_file"
      ;;
    copilot)
      # gh copilot is now a built-in; auth via GH_PAT (user token with Copilot subscription).
      # Model selection is not supported by gh copilot suggest — uses Copilot's default.
      ( export GH_TOKEN="$COPILOT_GITHUB_TOKEN"
        timeout "$DEEP_TIMEOUT_SEC" gh copilot suggest -p "$(cat "$prompt_file")"
      )
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
# Always uses a different model family from REVIEW_ENGINE. Output to stdout.
# Strips the opposing engine's credentials to prevent cross-engine leakage.
run_duck() {
  local prompt_file="$1"
  local model="$2"
  case "$DUCK_ENGINE" in
    claude)
      unset COPILOT_GITHUB_TOKEN 2>/dev/null || true
      unset GOOGLE_API_KEY 2>/dev/null || true
      timeout "$DUCK_TIMEOUT_SEC" claude --print \
        --model "$model" \
        --permission-mode acceptEdits \
        --allowed-tools "Bash,Read,Grep,Glob" \
        --max-turns 25 \
        < "$prompt_file"
      ;;
    gemini)
      unset CLAUDE_CODE_OAUTH_TOKEN 2>/dev/null || true
      unset COPILOT_GITHUB_TOKEN 2>/dev/null || true
      timeout "$DUCK_TIMEOUT_SEC" gemini --prompt "" \
        --model "$model" \
        --approval-mode auto_edit \
        --output-format text \
        < "$prompt_file"
      ;;
    copilot)
      unset CLAUDE_CODE_OAUTH_TOKEN 2>/dev/null || true
      unset GOOGLE_API_KEY 2>/dev/null || true
      # gh copilot is now a built-in; auth via GH_PAT (user token with Copilot subscription).
      ( export GH_TOKEN="$COPILOT_GITHUB_TOKEN"
        timeout "$DUCK_TIMEOUT_SEC" gh copilot suggest -p "$(cat "$prompt_file")"
      )
      ;;
    *)
      echo "::error::Unknown DUCK_ENGINE='$DUCK_ENGINE'" >&2
      return 1
      ;;
  esac
}
