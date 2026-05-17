#!/usr/bin/env bash
# validate-engines.sh — Pre-flight availability check for review engines.
#
# Provides:
#   validate_engines()   — checks Claude, Gemini, and Copilot availability
#
# After validate_engines() returns the following vars are exported:
#   CLAUDE_AVAILABLE   — "true" if claude CLI + CLAUDE_CODE_OAUTH_TOKEN are present
#   GEMINI_AVAILABLE   — "true" if gemini CLI + GOOGLE_API_KEY are present
#   COPILOT_AVAILABLE  — "true" if gh copilot is usable with COPILOT_GITHUB_TOKEN
#
# For each unavailable fallback engine a ::warning:: annotation is emitted that
# includes the exact command an operator needs to fix the gap — so the log is
# self-contained and there is no silent skip.
#
# If GITHUB_STEP_SUMMARY is set (normal in GitHub Actions) an engine-availability
# table is appended to the job summary so the degraded state is always visible
# in the run UI without needing to dig into logs.
#
# Always exits 0.  Degraded state is recorded but never aborts the run.

validate_engines() {
  local claude_ok=false gemini_ok=false copilot_ok=false

  # ── Claude ──────────────────────────────────────────────────────────────────
  if command -v claude >/dev/null 2>&1 && [ -n "${CLAUDE_CODE_OAUTH_TOKEN:-}" ]; then
    claude_ok=true
  fi

  # ── Gemini ──────────────────────────────────────────────────────────────────
  # Collect every reason the engine is unavailable so the warning is precise.
  local gemini_reasons=""
  if ! command -v gemini >/dev/null 2>&1; then
    gemini_reasons="Gemini CLI not installed (fix: npm install -g @google/gemini-cli)"
  fi
  if [ -z "${GOOGLE_API_KEY:-}" ]; then
    if [ -n "$gemini_reasons" ]; then
      gemini_reasons="$gemini_reasons; GOOGLE_API_KEY secret not set"
    else
      gemini_reasons="GOOGLE_API_KEY secret not set"
    fi
  fi
  if [ "${GEMINI_CLI_TRUST_WORKSPACE:-false}" != "true" ]; then
    if [ -n "$gemini_reasons" ]; then
      gemini_reasons="$gemini_reasons; GEMINI_CLI_TRUST_WORKSPACE is not true"
    else
      gemini_reasons="GEMINI_CLI_TRUST_WORKSPACE is not true (fix: set in env or pass --skip-trust)"
    fi
  fi

  if [ -z "$gemini_reasons" ]; then
    gemini_ok=true
  else
    echo "::warning::Gemini fallback unavailable — ${gemini_reasons}. When Claude is rate-limited, runs will fall through directly to Copilot."
  fi

  # ── Copilot ─────────────────────────────────────────────────────────────────
  # gh copilot is now a built-in; auth via COPILOT_GITHUB_TOKEN (user PAT with
  # Copilot subscription).  Fall back to GH_TOKEN for non-production test paths.
  if env GH_TOKEN="${COPILOT_GITHUB_TOKEN:-${GH_TOKEN:-}}" \
       gh copilot --version >/dev/null 2>&1; then
    copilot_ok=true
  fi

  export CLAUDE_AVAILABLE="$claude_ok"
  export GEMINI_AVAILABLE="$gemini_ok"
  export COPILOT_AVAILABLE="$copilot_ok"

  _emit_engine_summary "$claude_ok" "$gemini_ok" "$copilot_ok"
}

# _engine_badge <bool>  →  "ok" or "unavailable"
_engine_badge() {
  [ "$1" = "true" ] && printf 'ok' || printf 'unavailable'
}

# _emit_engine_summary <claude_ok> <gemini_ok> <copilot_ok>
# Appends an engine-availability Markdown table to GITHUB_STEP_SUMMARY.
# No-ops when GITHUB_STEP_SUMMARY is unset (local runs, unit tests without
# a summary file).
_emit_engine_summary() {
  local claude_ok="$1" gemini_ok="$2" copilot_ok="$3"
  local dest="${GITHUB_STEP_SUMMARY:-}"
  [ -z "$dest" ] && return 0
  {
    printf '### Engine availability (pre-flight)\n\n'
    printf '| Engine  | Status |\n'
    printf '|---------|--------|\n'
    printf '| Claude  | %s |\n' "$(_engine_badge "$claude_ok")"
    printf '| Gemini  | %s |\n' "$(_engine_badge "$gemini_ok")"
    printf '| Copilot | %s |\n' "$(_engine_badge "$copilot_ok")"
    printf '\n'
  } >> "$dest"
}
