#!/usr/bin/env bash
# Org-wide Actions Fleet Monitor.
#
# Dynamically discovers all non-archived repos in an org, all active
# workflows per repo, and fetches run telemetry for each over the lookback
# window. Writes a fleet summary to GITHUB_STEP_SUMMARY and
# fleet_monitor_report.md. Sets HAS_FAILURES=true in GITHUB_ENV when any
# workflow has failed runs.
#
# Env vars consumed:
#   GH_TOKEN        — must have actions:read across the org
#   ORG             — GitHub org to scan (default: petry-projects)
#   LOOKBACK_DAYS   — days of history to consider (default: 1)
#   GITHUB_ENV      — written by Actions runner
#   GITHUB_STEP_SUMMARY — written by Actions runner

set -euo pipefail

ORG="${ORG:-petry-projects}"
LOOKBACK_DAYS="${LOOKBACK_DAYS:-1}"
REPORT_FILE="fleet_monitor_report.md"
TODAY=$(date -u +%Y-%m-%d)

echo "=== Actions Fleet Monitor ==="
echo "  Org:      $ORG"
echo "  Lookback: ${LOOKBACK_DAYS} day(s)"
echo "  Date:     $TODAY"
echo ""

# ---------------------------------------------------------------------------
# 0. Token check
# ---------------------------------------------------------------------------
if ! gh api "orgs/${ORG}" >/dev/null 2>&1; then
  echo "::error::GH_TOKEN cannot access org ${ORG}."
  exit 1
fi

# ---------------------------------------------------------------------------
# 1. Discover repos
# ---------------------------------------------------------------------------
CUTOFF=$(date -u -d "${LOOKBACK_DAYS} days ago" +%Y-%m-%dT%H:%M:%SZ 2>/dev/null \
  || date -u -v-"${LOOKBACK_DAYS}"d +%Y-%m-%dT%H:%M:%SZ)

echo "Discovering repos in ${ORG}..."
# --paginate handles multi-page orgs; filter here so we never load archived repos into memory
mapfile -t repos < <(
  gh api "orgs/${ORG}/repos?per_page=100&type=all" --paginate \
    --jq '.[] | select(.archived == false) | .full_name' 2>/dev/null | sort
)
repo_count="${#repos[@]}"
echo "Found ${repo_count} non-archived repos — window: since ${CUTOFF}"
echo ""

# ---------------------------------------------------------------------------
# 2. Helpers
# ---------------------------------------------------------------------------
fmt_dur() {
  local s="$1"
  if [ "$s" -ge 60 ]; then
    printf '%dm%ds' $(( s / 60 )) $(( s % 60 ))
  else
    printf '%ds' "$s"
  fi
}

status_label() {
  local rate="$1"
  if   [ "$(printf '%s == 0' "$rate" | bc)" -eq 1 ]; then printf 'HEALTHY'
  elif [ "$(printf '%s > 50' "$rate" | bc)" -eq 1 ]; then printf 'CRITICAL'
  elif [ "$(printf '%s > 20' "$rate" | bc)" -eq 1 ]; then printf 'DEGRADED'
  else printf 'WARNING'
  fi
}

# Sort key: CRITICAL=0, DEGRADED=1, WARNING=2, HEALTHY=3, none=4
status_sort_key() {
  case "$1" in
    CRITICAL) printf '0' ;;
    DEGRADED) printf '1' ;;
    WARNING)  printf '2' ;;
    HEALTHY)  printf '3' ;;
    *)        printf '4' ;;
  esac
}

# ---------------------------------------------------------------------------
# 3. Collect metrics per repo → per workflow
# ---------------------------------------------------------------------------
metrics_file=$(mktemp)
failed_file=$(mktemp)
any_failures=0
total_workflows=0

for repo in "${repos[@]}"; do
  printf '  %s\n' "$repo"

  workflows=$(gh api "repos/${repo}/actions/workflows?per_page=100" \
    --jq '[.workflows[] | select(.state == "active") | {id: (.id | tostring), file: (.path | split("/") | last)}]' \
    2>/dev/null || echo '[]')

  wf_count=$(echo "$workflows" | jq 'length')
  [ "$wf_count" -eq 0 ] && continue
  total_workflows=$(( total_workflows + wf_count ))

  while IFS=$'\t' read -r wf_id wf_file; do
    runs_json=$(gh api \
      "repos/${repo}/actions/workflows/${wf_id}/runs?per_page=100&created=>=${CUTOFF}" \
      --jq '.workflow_runs | map({
        run_number: .run_number,
        conclusion: .conclusion,
        created_at: .created_at,
        html_url: .html_url,
        duration_s: ((.updated_at | fromdate) - (.created_at | fromdate))
      })' 2>/dev/null || echo '[]')

    total=$(echo "$runs_json" | jq 'length')
    failed=$(echo "$runs_json" | jq '[.[] | select(.conclusion == "failure")] | length')
    success=$(echo "$runs_json" | jq '[.[] | select(.conclusion == "success")] | length')
    cancelled=$(echo "$runs_json" | jq '[.[] | select(.conclusion == "cancelled")] | length')

    if [ "$total" -gt 0 ]; then
      rate=$(printf 'scale=1; %s * 100 / %s' "$failed" "$total" | bc)
      label=$(status_label "$rate")
      rate_display="${rate}%"
    else
      rate_display="n/a"
      label="—"
    fi

    read -r p50 p95 < <(echo "$runs_json" | jq -r '
      [.[] | select(.conclusion != null and .duration_s > 0) | .duration_s] | sort |
      if length == 0 then "0 0"
      else . as $d | ($d | length) as $n |
        "\($d[$n * 50 / 100 | floor]) \($d[$n * 95 / 100 | floor])"
      end')

    sort_key=$(status_sort_key "$label")

    printf '%s\t%s\t%s\t%s\t%s\t%s\t%s\t%s\t%s\t%s\t%s\n' \
      "$sort_key" "$repo" "$wf_file" \
      "$total" "$success" "$failed" "$cancelled" \
      "$rate_display" "$p50" "$p95" "$label" \
      >> "$metrics_file"

    if [ "$failed" -gt 0 ]; then
      any_failures=1
      {
        printf '\n### `%s` / `%s`\n\n' "$repo" "$wf_file"
        printf '| Run | Date | Duration | Link |\n|---|---|---|---|\n'
        while IFS=$'\t' read -r run_num created_at dur_s url; do
          printf '| #%s | %s | %s | [view](%s) |\n' \
            "$run_num" "${created_at%%T*}" "$(fmt_dur "$dur_s")" "$url"
        done < <(echo "$runs_json" | jq -r '
          [.[] | select(.conclusion == "failure")] | sort_by(.run_number) | reverse[] |
          [(.run_number | tostring), .created_at, (.duration_s | tostring), .html_url] | @tsv')
      } >> "$failed_file"
    fi
  done < <(echo "$workflows" | jq -r '.[] | [.id, .file] | @tsv')
done

# ---------------------------------------------------------------------------
# 4. Build report (table sorted by severity)
# ---------------------------------------------------------------------------
{
  printf '# Actions Fleet Monitor — %s\n\n' "$TODAY"
  printf '**Org:** `%s` | **Lookback:** %s day(s) | **Repos:** %s | **Workflows:** %s\n\n' \
    "$ORG" "$LOOKBACK_DAYS" "$repo_count" "$total_workflows"

  printf '## Fleet Summary\n\n'
  printf '| Repo | Workflow | Total | ✅ | ❌ | ⚪ | Failure Rate | p50 | p95 | Status |\n'
  printf '|---|---|---|---|---|---|---|---|---|---|\n'

  sort -t$'\t' -k1,1n "$metrics_file" | \
  while IFS=$'\t' read -r _key repo wf_file total success failed cancelled rate_display p50 p95 label; do
    printf '| `%s` | `%s` | %s | %s | %s | %s | %s | %s | %s | %s |\n' \
      "$repo" "$wf_file" "$total" "$success" "$failed" "$cancelled" \
      "$rate_display" "$(fmt_dur "$p50")" "$(fmt_dur "$p95")" "$label"
  done

  if [ "$any_failures" -eq 1 ]; then
    printf '\n## Failed Runs\n'
    cat "$failed_file"
  fi
} > "$REPORT_FILE"

rm -f "$metrics_file" "$failed_file"

# ---------------------------------------------------------------------------
# 5. Emit step summary and export env flags
# ---------------------------------------------------------------------------
[ -n "${GITHUB_STEP_SUMMARY:-}" ] && cat "$REPORT_FILE" >> "$GITHUB_STEP_SUMMARY"

if [ "$any_failures" -eq 1 ]; then
  [ -n "${GITHUB_ENV:-}" ] && echo "HAS_FAILURES=true" >> "$GITHUB_ENV"
fi

echo ""
echo "Report: $REPORT_FILE ($(wc -c < "$REPORT_FILE") bytes)"
echo "=== Fleet monitor complete ==="
