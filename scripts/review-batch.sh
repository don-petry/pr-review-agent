#!/usr/bin/env bash
# Run the cascading review against every PR listed in $PRS_FILE (default
# prs.txt). One PR per line. Empty input is a no-op.
#
# Env (passed through from the workflow):
#   PRS_FILE          — path to candidate list (default: prs.txt)
#   MAX_PRS           — stop after this many actual reviews (no-ops don't count)
#   CANDIDATE_LIMIT   — hard cap on candidates inspected (timeout backstop)
#   REVIEW_ENGINE     — primary engine (claude|gemini|copilot); may follow
#                       fallback chain claude -> gemini -> copilot
#   GH_TOKEN          — workflow auth (set at job level)
#
# Exit:
#   0 — finished cleanly (zero or more reviews posted)
#   1 — session aborted early (a non-skip failure on some PR; remaining
#       candidates are deferred to the next scheduled run)

set -euo pipefail

PRS_FILE="${PRS_FILE:-prs.txt}"
MAX_PRS="${MAX_PRS:-10}"
CANDIDATE_LIMIT="${CANDIDATE_LIMIT:-100}"

if [ ! -s "$PRS_FILE" ]; then
  echo "::notice::No candidate PRs to review."
  exit 0
fi

actual=0
skipped_noops=0
failed=0
engine_fallbacks=0
fallback_engines=""
processed=0
session_aborted=0
abort_pr=""
abort_reason=""
total_candidates=$(grep -c . "$PRS_FILE" || true)

while IFS= read -r pr_url; do
  [ -z "$pr_url" ] && continue
  processed=$((processed + 1))

  if [ "$processed" -gt "$CANDIDATE_LIMIT" ]; then
    echo "::notice::Hit CANDIDATE_LIMIT=$CANDIDATE_LIMIT, stopping batch"
    break
  fi
  if [ "$actual" -ge "$MAX_PRS" ]; then
    echo "::notice::Reached MAX_PRS=$MAX_PRS actual reviews, stopping batch"
    break
  fi

  echo "::group::Reviewing $pr_url"
  rc=0
  bash scripts/review-one-pr.sh "$pr_url" || rc=$?

  # Exit code 2 = engine rate-limited.
  # Fallback chain: claude -> gemini -> copilot
  if [ "$rc" -eq 2 ] && [ "${REVIEW_ENGINE:-claude}" = "claude" ]; then
    if command -v gemini >/dev/null 2>&1 && [ -n "${GOOGLE_API_KEY:-}" ]; then
      echo "::warning::Claude rate limit hit — switching to Gemini engine for remaining PRs"
      export REVIEW_ENGINE=gemini
      engine_fallbacks=$((engine_fallbacks + 1))
      fallback_engines="${fallback_engines:+$fallback_engines, }gemini"
      rc=0
      bash scripts/review-one-pr.sh "$pr_url" || rc=$?
    else
      echo "::warning::Claude rate limit hit but Gemini fallback unavailable (CLI not installed or GOOGLE_API_KEY missing) — falling through to Copilot"
      rc=2
      export REVIEW_ENGINE=gemini # Set to gemini so the next block catches it
    fi
  fi

  if [ "$rc" -eq 2 ] && [ "${REVIEW_ENGINE}" = "gemini" ]; then
    if ! gh extension list 2>/dev/null | grep -q copilot && ! gh copilot --version > /dev/null 2>&1; then
      echo "::warning::Copilot fallback engine unavailable — skipping $pr_url and continuing batch"
      failed=$((failed + 1))
      echo "::endgroup::"
      continue
    fi
    echo "::warning::Gemini rate limit hit — switching to Copilot engine for remaining PRs"
    export REVIEW_ENGINE=copilot
    engine_fallbacks=$((engine_fallbacks + 1))
    fallback_engines="${fallback_engines:+$fallback_engines, }copilot"
    rc=0
    bash scripts/review-one-pr.sh "$pr_url" || rc=$?
  fi

  case "$rc" in
    0)
      actual=$((actual + 1))
      echo "::notice::Review posted ($actual/$MAX_PRS)"
      ;;
    100)
      skipped_noops=$((skipped_noops + 1))
      echo "::notice::No-op (already reviewed)"
      ;;
    2)
      failed=$((failed + 1))
      echo "::error::Rate limit hit on $REVIEW_ENGINE engine, no fallback available for $pr_url"
      session_aborted=1
      abort_pr="$pr_url"
      abort_reason="rate-limit on fallback engine"
      ;;
    *)
      # Other failure — session-fatal. A systemic problem (model degraded,
      # prompt regression, malformed verdicts) shouldn't burn the queue.
      failed=$((failed + 1))
      echo "::error::Review failed for $pr_url (exit code $rc)"
      session_aborted=1
      abort_pr="$pr_url"
      abort_reason="exit code $rc"
      ;;
  esac

  echo "::endgroup::"
  [ "$session_aborted" -eq 1 ] && break
done < "$PRS_FILE"

remaining=$((total_candidates - processed))
summary="Summary: $actual reviews posted, $skipped_noops no-ops skipped, $failed failures"
[ "$engine_fallbacks" -gt 0 ] && summary="$summary, $engine_fallbacks engine fallback(s) to $fallback_engines"
summary="$summary (processed $processed/$total_candidates candidates)"

if [ "$session_aborted" -eq 1 ]; then
  echo "::error::Session aborted early after failure on $abort_pr ($abort_reason). Skipped $remaining remaining candidate(s); will retry on next scheduled run."
  echo "$summary [SESSION ABORTED EARLY]"
  exit 1
fi

echo "$summary"
