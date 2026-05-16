#!/usr/bin/env bash
# Fleet monitor — reports telemetry for all active workflows in a repo.
#
# Discovers every active workflow in WORKFLOW_REPO, fetches run data for
# each over the lookback window, and writes a fleet summary to both
# GITHUB_STEP_SUMMARY and fleet_monitor_report.md.
# Sets HAS_FAILURES=true in GITHUB_ENV when any workflow has failed runs.
#
# Env vars consumed:
#   GH_TOKEN        — must have actions:read on WORKFLOW_REPO
#   WORKFLOW_REPO   — owner/repo to inspect (default: petry-projects/.github-private)
#   LOOKBACK_DAYS   — days of history to consider (default: 1)
#   GITHUB_ENV      — written by Actions runner
#   GITHUB_STEP_SUMMARY — written by Actions runner

set -euo pipefail

WORKFLOW_REPO="${WORKFLOW_REPO:-petry-projects/.github-private}"
LOOKBACK_DAYS="${LOOKBACK_DAYS:-1}"
REPORT_FILE="fleet_monitor_report.md"
TODAY=$(date -u +%Y-%m-%d)

echo "=== Actions Fleet Monitor ==="
echo "  Repo:     $WORKFLOW_REPO"
echo "  Lookback: ${LOOKBACK_DAYS} day(s)"
echo "  Date:     $TODAY"
echo ""

# ---------------------------------------------------------------------------
# 0. Token selection
# ---------------------------------------------------------------------------
if ! gh api "repos/${WORKFLOW_REPO}/actions/workflows" >/dev/null 2>&1; then
  if [ -n "${GH_PAT_FALLBACK:-}" ]; then
    echo "::warning::GH_TOKEN cannot access ${WORKFLOW_REPO} — using GH_PAT_FALLBACK"
    export GH_TOKEN="$GH_PAT_FALLBACK"
  else
    echo "::error::GH_TOKEN cannot access ${WORKFLOW_REPO} and GH_PAT_FALLBACK is not set."
    exit 1
  fi
fi

# ---------------------------------------------------------------------------
# 1. Discover active workflows
# ---------------------------------------------------------------------------
CUTOFF=$(date -u -d "${LOOKBACK_DAYS} days ago" +%Y-%m-%dT%H:%M:%SZ 2>/dev/null \
  || date -u -v-"${LOOKBACK_DAYS}"d +%Y-%m-%dT%H:%M:%SZ)

workflows=$(gh api "repos/${WORKFLOW_REPO}/actions/workflows" \
  --jq '[.workflows[] | select(.state == "active") | {id: (.id | tostring), name: .name, file: (.path | split("/") | last)}]')

workflow_count=$(echo "$workflows" | jq 'length')
echo "Found $workflow_count active workflow(s) — window: since $CUTOFF"
echo ""

# ---------------------------------------------------------------------------
# 2. Helpers
# ---------------------------------------------------------------------------
fmt_dur() {
  local s=$1
  [ "$s" -ge 60 ] && printf '%dm%ds' $((s/60)) $((s%60)) || printf '%ds' "$s"
}

status_label() {
  local rate=$1
  if   [ "$(echo "$rate == 0"   | bc)" -eq 1 ]; then echo "HEALTHY"
  elif [ "$(echo "$rate > 50"   | bc)" -eq 1 ]; then echo "CRITICAL"
  elif [ "$(echo "$rate > 20"   | bc)" -eq 1 ]; then echo "DEGRADED"
  else echo "WARNING"
  fi
}

# ---------------------------------------------------------------------------
# 3. Collect metrics; build report incrementally
# ---------------------------------------------------------------------------
{
  printf '# Actions Fleet Monitor — %s\n\n' "$TODAY"
  printf '**Repo:** `%s` | **Lookback:** %s day(s) | **Workflows:** %s\n\n' \
    "$WORKFLOW_REPO" "$LOOKBACK_DAYS" "$workflow_count"
  printf '## Fleet Summary\n\n'
  printf '| Workflow | Total | ✅ | ❌ | ⚪ | Failure Rate | p50 | p95 | Status |\n'
  printf '|---|---|---|---|---|---|---|---|---|\n'
} > "$REPORT_FILE"

any_failures=0
failed_details=$(mktemp)

while IFS=$'\t' read -r wf_id wf_name wf_file; do
  echo "  $wf_file"

  runs_json=$(gh api \
    "repos/${WORKFLOW_REPO}/actions/workflows/${wf_id}/runs?per_page=100&created=>=${CUTOFF}" \
    --jq '.workflow_runs | map({
      run_number: .run_number,
      conclusion: .conclusion,
      status: .status,
      created_at: .created_at,
      html_url: .html_url,
      duration_s: ((.updated_at | fromdate) - (.created_at | fromdate))
    })' 2>/dev/null || echo '[]')

  total=$(echo "$runs_json" | jq 'length')
  failed=$(echo "$runs_json" | jq '[.[] | select(.conclusion == "failure")] | length')
  success=$(echo "$runs_json" | jq '[.[] | select(.conclusion == "success")] | length')
  cancelled=$(echo "$runs_json" | jq '[.[] | select(.conclusion == "cancelled")] | length')

  if [ "$total" -gt 0 ]; then
    rate=$(echo "scale=1; $failed * 100 / $total" | bc)
  else
    rate="n/a"
  fi

  read -r p50 p95 < <(echo "$runs_json" | jq -r '
    [.[] | select(.conclusion != null and .duration_s > 0) | .duration_s] | sort |
    if length == 0 then "0 0"
    else . as $d | ($d | length) as $n |
      "\($d[$n * 50 / 100 | floor]) \($d[$n * 95 / 100 | floor])"
    end')

  if [ "$rate" = "n/a" ]; then
    label="—"
  else
    label=$(status_label "$rate")
  fi

  rate_display="${rate}%"
  [ "$rate" = "n/a" ] && rate_display="n/a"

  printf '| `%s` | %s | %s | %s | %s | %s | %s | %s | %s |\n' \
    "$wf_file" "$total" "$success" "$failed" "$cancelled" \
    "$rate_display" "$(fmt_dur "$p50")" "$(fmt_dur "$p95")" "$label" \
    >> "$REPORT_FILE"

  if [ "$failed" -gt 0 ]; then
    any_failures=1
    {
      printf '\n### `%s`\n\n' "$wf_file"
      printf '| Run | Date | Duration | Link |\n|---|---|---|---|\n'
      while IFS=$'\t' read -r run_num created_at dur_s url; do
        printf '| #%s | %s | %s | [view](%s) |\n' \
          "$run_num" "${created_at%%T*}" "$(fmt_dur "$dur_s")" "$url"
      done < <(echo "$runs_json" | jq -r '
        [.[] | select(.conclusion == "failure")] | sort_by(.run_number) | reverse[] |
        [(.run_number | tostring), .created_at, (.duration_s | tostring), .html_url] | @tsv')
    } >> "$failed_details"
  fi
done < <(echo "$workflows" | jq -r '.[] | [.id, .name, .file] | @tsv')

if [ "$any_failures" -eq 1 ]; then
  printf '\n## Failed Runs\n' >> "$REPORT_FILE"
  cat "$failed_details" >> "$REPORT_FILE"
fi
rm -f "$failed_details"

# ---------------------------------------------------------------------------
# 4. Emit step summary and export env flags
# ---------------------------------------------------------------------------
[ -n "${GITHUB_STEP_SUMMARY:-}" ] && cat "$REPORT_FILE" >> "$GITHUB_STEP_SUMMARY"

if [ "$any_failures" -eq 1 ]; then
  [ -n "${GITHUB_ENV:-}" ] && echo "HAS_FAILURES=true" >> "$GITHUB_ENV"
fi

echo ""
echo "Report written to $REPORT_FILE ($(wc -c < "$REPORT_FILE") bytes)"
echo "=== Fleet monitor complete ==="
