#!/usr/bin/env bash
set -euo pipefail
# dev-lead-retry.sh — scan open PRs for rate-limited markers and re-dispatch
#
# Called by the dev-lead-retry.yml scheduled cron workflow.
# Scans all open PRs across TARGET_ORG (plus DELEGATION_ORGS if set) for
# status=rate-limited markers on the current HEAD SHA, then re-dispatches the
# appropriate dev-lead event so the run is retried once the rate limit clears.
#
# Env (required):
#   GH_TOKEN            — PAT with repo + workflow read scopes
#   TARGET_ORG          — GitHub org to scan (default: petry-projects)
#
# Env (optional):
#   DELEGATION_ORGS     — space-separated additional orgs to scan
#   BOT_USER            — bot account name, excluded from PR author filter
#   DISPATCH_DELAY_SEC  — seconds between repo dispatches (default: 30) to
#                         prevent cascading org-wide rate-limit hits
#   DRY_RUN             — if "true", log what would be dispatched but don't send
#   NOW_ISO             — override current time for testing (ISO-8601 UTC)

TARGET_ORG="${TARGET_ORG:-petry-projects}"
DELEGATION_ORGS="${DELEGATION_ORGS:-}"
BOT_USER="${BOT_USER:-donpetry-bot}"
DISPATCH_DELAY_SEC="${DISPATCH_DELAY_SEC:-30}"
DRY_RUN="${DRY_RUN:-false}"

CI_MARKER_PREFIX="<!-- dev-lead-fix-ci sha="
REVIEWS_MARKER_PREFIX="<!-- dev-lead-fix-reviews pr="

# get_now_epoch: current UTC time as unix epoch (overridable for tests)
get_now_epoch() {
  if [ -n "${NOW_ISO:-}" ]; then
    date -u -d "$NOW_ISO" +%s 2>/dev/null || date -u +%s
  else
    date -u +%s
  fi
}

# is_reset_in_future <reset_iso>: returns 0 if reset time is still in the future
is_reset_in_future() {
  local reset_iso="$1"
  [ -z "$reset_iso" ] && return 1  # unknown reset = don't skip
  local reset_epoch
  reset_epoch=$(date -u -d "$reset_iso" +%s 2>/dev/null || echo 0)
  [ "$(get_now_epoch)" -lt "$reset_epoch" ]
}

# dispatch_ci_retry <repo> <pr_number> <head_sha> <check_name>
dispatch_ci_retry() {
  local repo="$1" pr_number="$2" head_sha="$3" check_name="${4:-CI failure}"
  echo "  -> dispatch ci-retry: repo=${repo} pr=${pr_number} sha=${head_sha:0:8}"
  if [ "$DRY_RUN" = "true" ]; then
    echo "  [dry-run] would dispatch dev-lead-ci-failure for PR ${pr_number} in ${repo}"
    return 0
  fi
  local payload
  payload=$(jq -n \
    --argjson pr_number "$pr_number" \
    --arg head_sha "$head_sha" \
    --arg repo "$repo" \
    --arg name "$check_name" \
    '{
      event_type: "dev-lead-ci-failure",
      client_payload: {
        pr_number: $pr_number,
        head_sha: $head_sha,
        repo: $repo,
        checks: [{name: $name, conclusion: "failure", details_url: "", app_slug: "github-actions"}]
      }
    }')
  echo "$payload" | gh api --method POST "repos/${repo}/dispatches" --input - 2>&1 || \
    echo "  [warn] dispatch failed for PR ${pr_number} in ${repo}"
}

# dispatch_reviews_retry <repo> <pr_number> <head_sha> <intent_type>
dispatch_reviews_retry() {
  local repo="$1" pr_number="$2" head_sha="$3" intent_type="$4"
  echo "  -> dispatch reviews-retry: repo=${repo} pr=${pr_number} sha=${head_sha:0:8} intent=${intent_type}"
  if [ "$DRY_RUN" = "true" ]; then
    echo "  [dry-run] would dispatch dev-lead-reviews-retry for PR ${pr_number} in ${repo} intent=${intent_type}"
    return 0
  fi
  local payload
  payload=$(jq -n \
    --argjson pr_number "$pr_number" \
    --arg head_sha "$head_sha" \
    --arg repo "$repo" \
    --arg intent_type "$intent_type" \
    '{
      event_type: "dev-lead-reviews-retry",
      client_payload: {
        pr_number: $pr_number,
        head_sha: $head_sha,
        repo: $repo,
        intent_type: $intent_type
      }
    }')
  echo "$payload" | gh api --method POST "repos/${repo}/dispatches" --input - 2>&1 || \
    echo "  [warn] dispatch failed for PR ${pr_number} in ${repo}"
}

# scan_pr_for_rate_limits <repo> <pr_number>
# Checks the PR's comments for rate-limited markers and dispatches retries.
# Returns number of retries dispatched (0 = nothing to retry).
scan_pr_for_rate_limits() {
  local repo="$1" pr_number="$2"

  # Get the current HEAD SHA of the PR
  local head_sha
  head_sha=$(gh api "repos/${repo}/pulls/${pr_number}" --jq '.head.sha' 2>/dev/null || true)
  if [ -z "$head_sha" ]; then
    echo "  [warn] could not resolve HEAD SHA for PR ${pr_number} in ${repo} — skipping"
    return 0
  fi

  # Fetch all comment bodies for this PR
  local comments_json
  comments_json=$(gh api "repos/${repo}/issues/${pr_number}/comments" \
    --jq '[.[].body]' 2>/dev/null || echo "[]")

  local dispatched=0

  # ── Check for fix-ci rate-limited marker on current HEAD SHA ──────────────
  local ci_pattern="${CI_MARKER_PREFIX}${head_sha} status=rate-limited"
  if echo "$comments_json" | jq -e --arg pat "$ci_pattern" '[.[] | select(. | test($pat))] | length > 0' >/dev/null 2>&1; then
    # Extract reset time from the marker (format: reset=<ISO>)
    local reset_time
    reset_time=$(echo "$comments_json" | jq -r \
      --arg pat "$ci_pattern" \
      '[.[] | select(. | test($pat))] | .[0] | capture("reset=(?P<r>[0-9T:Z-]+)") | .r // ""' \
      2>/dev/null || true)

    if is_reset_in_future "$reset_time"; then
      echo "  [skip] fix-ci rate-limit for PR ${pr_number} not yet cleared (resets ${reset_time})"
    else
      # Also check if a terminal marker was already posted for this SHA (retry succeeded)
      local terminal_pattern="${CI_MARKER_PREFIX}${head_sha} status=(applied|failed|no-changes)"
      if echo "$comments_json" | jq -e --arg pat "$terminal_pattern" '[.[] | select(. | test($pat))] | length > 0' >/dev/null 2>&1; then
        echo "  [skip] fix-ci already has terminal result for PR ${pr_number} SHA ${head_sha:0:8}"
      else
        local check_name="CI failure"
        check_name=$(echo "$comments_json" | jq -r \
          --arg pat "$ci_pattern" \
          '[.[] | select(. | test($pat))] | .[0] | capture("check=(?P<c>[^\"\\s]+)") | .c // "CI failure"' \
          2>/dev/null || echo "CI failure")
        dispatch_ci_retry "$repo" "$pr_number" "$head_sha" "$check_name"
        dispatched=$(( dispatched + 1 ))
      fi
    fi
  fi

  # ── Check for fix-reviews rate-limited markers on current HEAD SHA ─────────
  for intent_type in fix-reviews fix-bot-comment human human-pr rebase; do
    local reviews_pattern="${REVIEWS_MARKER_PREFIX}${pr_number} sha=${head_sha} intent=${intent_type} status=rate-limited"
    if echo "$comments_json" | jq -e --arg pat "$reviews_pattern" '[.[] | select(. | test($pat))] | length > 0' >/dev/null 2>&1; then
      local reset_time
      reset_time=$(echo "$comments_json" | jq -r \
        --arg pat "$reviews_pattern" \
        '[.[] | select(. | test($pat))] | .[0] | capture("reset=(?P<r>[0-9T:Z-]+)") | .r // ""' \
        2>/dev/null || true)

      if is_reset_in_future "$reset_time"; then
        echo "  [skip] ${intent_type} rate-limit for PR ${pr_number} not yet cleared (resets ${reset_time})"
        continue
      fi

      dispatch_reviews_retry "$repo" "$pr_number" "$head_sha" "$intent_type"
      dispatched=$(( dispatched + 1 ))
    fi
  done

  echo "$dispatched"
}

# scan_repo <repo>: scan all open PRs in a repo for rate-limited markers
scan_repo() {
  local repo="$1"
  echo "[retry] scanning ${repo}..."

  local prs_json
  prs_json=$(gh api "repos/${repo}/pulls?state=open&per_page=100" \
    --jq '[.[] | {number: .number, head_sha: .head.sha}]' 2>/dev/null || echo "[]")

  local pr_count
  pr_count=$(echo "$prs_json" | jq 'length')
  if [ "$pr_count" -eq 0 ]; then
    echo "  no open PRs in ${repo}"
    return 0
  fi

  echo "  found ${pr_count} open PR(s)"
  local total_dispatched=0

  while IFS= read -r pr_entry; do
    local pr_number
    pr_number=$(echo "$pr_entry" | jq -r '.number')
    local dispatched
    dispatched=$(scan_pr_for_rate_limits "$repo" "$pr_number")
    total_dispatched=$(( total_dispatched + dispatched ))
  done < <(echo "$prs_json" | jq -c '.[]')

  echo "  dispatched ${total_dispatched} retries from ${repo}"
}

# list_repos_for_org <org>: list all non-fork repos in the org
list_repos_for_org() {
  local org="$1"
  gh repo list "$org" --limit 200 --json nameWithOwner,isFork \
    --jq '[.[] | select(.isFork == false) | .nameWithOwner]' 2>/dev/null || echo "[]"
}

main() {
  echo "[retry] dev-lead-retry starting at $(date -u +%Y-%m-%dT%H:%M:%SZ)"
  echo "[retry] dry_run=${DRY_RUN} dispatch_delay=${DISPATCH_DELAY_SEC}s"

  local all_repos=()

  # Collect repos from TARGET_ORG
  while IFS= read -r repo; do
    all_repos+=("$repo")
  done < <(list_repos_for_org "$TARGET_ORG" | jq -r '.[]')

  # Collect repos from DELEGATION_ORGS
  if [ -n "$DELEGATION_ORGS" ]; then
    for org in $DELEGATION_ORGS; do
      while IFS= read -r repo; do
        all_repos+=("$repo")
      done < <(list_repos_for_org "$org" | jq -r '.[]')
    done
  fi

  local repo_count="${#all_repos[@]}"
  echo "[retry] scanning ${repo_count} repo(s) across org(s)"

  local repo_index=0
  for repo in "${all_repos[@]}"; do
    if [ "$repo_index" -gt 0 ] && [ "$DISPATCH_DELAY_SEC" -gt 0 ]; then
      # Stagger dispatches to avoid hammering the rate-limited API simultaneously
      echo "[retry] waiting ${DISPATCH_DELAY_SEC}s before next repo (stagger)..."
      sleep "$DISPATCH_DELAY_SEC"
    fi
    scan_repo "$repo"
    repo_index=$(( repo_index + 1 ))
  done

  echo "[retry] done at $(date -u +%Y-%m-%dT%H:%M:%SZ)"
}

main "$@"
