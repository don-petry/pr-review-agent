#!/usr/bin/env bash
set -euo pipefail
# dev-lead-intent.sh — Event classifier for the dev-lead agent.
#
# Reads GITHUB_EVENT_NAME and GITHUB_EVENT_PATH, classifies the event into
# an intent, and writes INTENT_TYPE / INTENT_REASON / INTENT_CONTEXT to
# GITHUB_ENV and GITHUB_OUTPUT.
#
# Phase 1: STUB — only anti-loop guards are fully implemented.
#   All other events emit skip("not-implemented").
#
# Intents (for future phases):
#   fix-ci          — CI failure to auto-fix
#   fix-reviews     — Bot review comments to address
#   fix-bot-comment — Bot issue comment to address
#   human           — Human-directed @mention task
#   human-pr        — Human review changes-requested
#   issue           — Issue labeled dev-lead/claude
#   rebase          — Rebase conflict sentinel
#   ci-relay        — check_run relay (handled by ci-relay job, not this script)
#   skip            — Event should be ignored

# ── helpers ──────────────────────────────────────────────────────────────────

GITHUB_ENV="${GITHUB_ENV:-/dev/null}"
GITHUB_OUTPUT="${GITHUB_OUTPUT:-/dev/null}"

emit_intent() {
  local intent="$1" reason="${2:-}" context="${3:-}"
  echo "INTENT_TYPE=${intent}" >> "$GITHUB_ENV"
  echo "INTENT_REASON=${reason}" >> "$GITHUB_ENV"
  echo "INTENT_CONTEXT=${context}" >> "$GITHUB_ENV"
  echo "intent_type=${intent}" >> "$GITHUB_OUTPUT"
  echo "intent_reason=${reason}" >> "$GITHUB_OUTPUT"
  echo "intent_context=${context}" >> "$GITHUB_OUTPUT"
  echo "  [intent] type=${intent} reason=${reason} context=${context}"
}

emit_skip() {
  local reason="${1:-not-implemented}"
  emit_intent "skip" "$reason" ""
}

# ── read event ───────────────────────────────────────────────────────────────

EVENT_NAME="${GITHUB_EVENT_NAME:-}"
EVENT_PATH="${GITHUB_EVENT_PATH:-}"
BOT_USER="${BOT_USER:-donpetry-bot}"

if [ -z "$EVENT_NAME" ]; then
  echo "::error::GITHUB_EVENT_NAME is not set"
  exit 1
fi

echo "dev-lead-intent: processing event=$EVENT_NAME"

# ── check_run: not handled here (ci-relay job) ───────────────────────────────

if [ "$EVENT_NAME" = "check_run" ]; then
  emit_skip "check-run-handled-by-ci-relay"
  exit 0
fi

# ── anti-loop guard: pull_request synchronize ────────────────────────────────
# If the synchronize event was triggered by BOT_USER's own commit, skip to
# prevent an infinite fix → push → trigger → fix loop.

if [ "$EVENT_NAME" = "pull_request" ] && [ -n "$EVENT_PATH" ] && [ -f "$EVENT_PATH" ]; then
  pr_action=$(jq -r '.action // empty' "$EVENT_PATH" 2>/dev/null || true)
  if [ "$pr_action" = "synchronize" ]; then
    sender_login=$(jq -r '.sender.login // empty' "$EVENT_PATH" 2>/dev/null || true)
    if [ "$sender_login" = "$BOT_USER" ]; then
      emit_skip "dev-lead-own-commit"
      exit 0
    fi
    # Also skip if the commit message starts with fix(ci): or fix(dev-lead):
    head_commit_msg=$(jq -r '.pull_request.head.sha // empty' "$EVENT_PATH" 2>/dev/null || true)
    # Note: full commit message check would require a git fetch; check via
    # event context only (pusher commits are not embedded in the event payload).
    # Future phases can add a git-based check after checkout.
  fi
fi

# ── stub: everything else ─────────────────────────────────────────────────────
# Phase 1 stub: emit skip for all unimplemented intents.
# Future phases will implement the full routing logic.

emit_skip "not-implemented"
