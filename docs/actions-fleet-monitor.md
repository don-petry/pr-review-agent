# Actions Fleet Monitor

A reusable GitHub Actions workflow that collects run telemetry for any workflow in the org and surfaces it as a Step Summary and (on failure) a GitHub Issue. No external infrastructure required.

## What it measures

| Signal | Detail |
|---|---|
| Failure rate | `failed / total` runs over the lookback window |
| Duration min / p50 / p95 / max | Computed from `created_at` → `updated_at` on completed runs |
| Per-run table | Run number, conclusion, date, duration, link |
| Overall status | `HEALTHY` / `WARNING` (>10%) / `DEGRADED` (>20%) / `CRITICAL` (>50%) |

## Delivery

- **Step Summary** — written on every run; visible in the Actions UI without leaving GitHub.
- **GitHub Issue** — opened in `.github-private` when any failures are detected; title includes the monitored workflow and repo.

## Invoking from another repo

Copy [`docs/examples/fleet-monitor-caller.yml`](examples/fleet-monitor-caller.yml) into `.github/workflows/` of the target repo, update `workflow_file`, and commit.

```yaml
jobs:
  monitor:
    uses: petry-projects/.github-private/.github/workflows/actions-fleet-monitor.yml@main
    with:
      workflow_repo: ${{ github.repository }}
      workflow_file: my-workflow.yml
      lookback_days: ${{ inputs.lookback_days || '1' }}
    secrets: inherit
```

`secrets: inherit` passes `DON_PETRY_BOT_GH_PAT` (an org secret) through to the shared workflow so it can read run history across repos.

## Inputs

| Input | Required | Default | Description |
|---|---|---|---|
| `workflow_repo` | yes (workflow_call) | `petry-projects/.github-private` | `owner/repo` of the workflow to monitor |
| `workflow_file` | yes (workflow_call) | `pr-review.yml` | Filename of the workflow to monitor |
| `lookback_days` | no | `1` | Rolling window of run history to inspect |

## Environment variables (script)

| Variable | Source | Description |
|---|---|---|
| `GH_TOKEN` | `secrets.DON_PETRY_BOT_GH_PAT` | PAT with `actions:read` on `WORKFLOW_REPO` |
| `WORKFLOW_REPO` | workflow input | Target repo |
| `WORKFLOW_FILE` | workflow input | Target workflow filename |
| `LOOKBACK_DAYS` | workflow input | Lookback window |
| `GH_PAT_FALLBACK` | optional secret | Secondary token if primary lacks access |

## Thresholds

| Status | Failure rate |
|---|---|
| `HEALTHY` | 0% |
| `WARNING` | > 0% and ≤ 20% |
| `DEGRADED` | > 20% and ≤ 50% |
| `CRITICAL` | > 50% |

Thresholds are defined in `scripts/pr_review_health.sh` and can be adjusted per-deployment.

## Linting

`shellcheck` runs on all PRs that touch `scripts/` or `.github/workflows/` via `.github/workflows/lint.yml`.

## Extending to the full org fleet

See [Discussion #193](https://github.com/petry-projects/.github-private/discussions/193) for the RFC on evolving this into a multi-repo aggregated fleet monitor.
