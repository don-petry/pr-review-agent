#!/usr/bin/env bash
set -euo pipefail
# Pre-flight checks for the dev-lead agent workflow.
# Validates required and optional secrets/tokens before the agent runs.
#
# Usage: bash scripts/dev-lead-preflight.sh
# Outputs: status messages + GITHUB_STEP_SUMMARY table (if running in Actions)

# ── helpers ──────────────────────────────────────────────────────────────────

PASS="ok"
FAIL="missing"
WARN="optional"

# check_required <var_name> <purpose>
# Exits 1 if the variable is unset or empty.
check_required() {
  local var="$1" purpose="$2"
  if [ -z "${!var:-}" ]; then
    echo "::error::Required secret not set: $var ($purpose)"
    return 1
  fi
  echo "  [ok] $var — $purpose"
}

# check_optional <var_name> <purpose>
# Emits a warning if the variable is unset but does not exit.
check_optional() {
  local var="$1" purpose="$2"
  if [ -z "${!var:-}" ]; then
    echo "  [warn] $var not set — $purpose will be unavailable"
  else
    echo "  [ok] $var — $purpose"
  fi
}

# ── checks ────────────────────────────────────────────────────────────────────

echo "dev-lead pre-flight checks"
echo "────────────────────────────────────────"

FAILED=0

check_required "CLAUDE_CODE_OAUTH_TOKEN" "Claude Code CLI authentication" || FAILED=1

check_optional "GH_PAT_WORKFLOWS" "workflow file pushes and repository_dispatch"
check_optional "GOOGLE_API_KEY" "Gemini engine fallback"
check_optional "GH_PAT" "Copilot engine"

echo "────────────────────────────────────────"

# ── step summary ──────────────────────────────────────────────────────────────

if [ -n "${GITHUB_STEP_SUMMARY:-}" ]; then
  {
    echo "## Dev-Lead Pre-Flight Check"
    echo ""
    echo "| Secret | Status | Purpose |"
    echo "| ------ | ------ | ------- |"

    _row() {
      local var="$1" purpose="$2" required="${3:-optional}"
      if [ -n "${!var:-}" ]; then
        echo "| \`$var\` | $PASS | $purpose |"
      elif [ "$required" = "required" ]; then
        echo "| \`$var\` | $FAIL | $purpose |"
      else
        echo "| \`$var\` | $WARN | $purpose |"
      fi
    }

    _row "CLAUDE_CODE_OAUTH_TOKEN" "Claude Code CLI authentication" "required"
    _row "GH_PAT_WORKFLOWS" "Workflow file pushes and repository_dispatch"
    _row "GOOGLE_API_KEY" "Gemini engine fallback"
    _row "GH_PAT" "Copilot engine"

  } >> "$GITHUB_STEP_SUMMARY"
fi

# ── exit ──────────────────────────────────────────────────────────────────────

if [ "$FAILED" -ne 0 ]; then
  echo "Pre-flight FAILED — required secrets are missing"
  exit 1
fi

echo "Pre-flight OK"
