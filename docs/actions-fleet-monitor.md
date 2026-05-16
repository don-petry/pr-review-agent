# Actions Fleet Monitor

A reusable GitHub Actions workflow that discovers all active workflows in a repo, collects run telemetry for each, and surfaces results as a Step Summary and (on failure) a GitHub Issue. No external infrastructure required.

## What it measures

For each active workflow in the target repo:

| Signal | Detail |
|---|---|
| Total / success / failed / cancelled | Run counts over the lookback window |
| Failure rate | `failed / total` |
| Duration p50 / p95 | Computed from `created_at` → `updated_at` on completed runs |
| Status | `HEALTHY` / `WARNING` / `DEGRADED` / `CRITICAL` (see thresholds) |

## Delivery

- **Step Summary** — fleet table written on every run; visible in the Actions UI without leaving GitHub.
- **GitHub Issue** — opened in `.github-private` when any workflow has failed runs; title references the monitored repo.

## Invoking from another repo

Copy [`docs/examples/fleet-monitor-caller.yml`](examples/fleet-monitor-caller.yml) into `.github/workflows/` of the target repo and commit. No other configuration needed.

```yaml
jobs:
  monitor:
    uses: petry-projects/.github-private/.github/workflows/actions-fleet-monitor.yml@main
    with:
      workflow_repo: ${{ github.repository }}
      lookback_days: ${{ inputs.lookback_days || '1' }}
    secrets: inherit
```

`secrets: inherit` passes `DON_PETRY_BOT_GH_PAT` (an org secret) through to the shared workflow so it can read run history across repos.

## Inputs

| Input | Required | Default | Description |
|---|---|---|---|
| `workflow_repo` | yes (workflow_call) | `petry-projects/.github-private` | `owner/repo` to monitor — all active workflows discovered automatically |
| `lookback_days` | no | `1` | Rolling window of run history to inspect |

## Environment variables (script)

| Variable | Source | Description |
|---|---|---|
| `GH_TOKEN` | `secrets.DON_PETRY_BOT_GH_PAT` | PAT with `actions:read` on `WORKFLOW_REPO` |
| `WORKFLOW_REPO` | workflow input | Target repo |
| `LOOKBACK_DAYS` | workflow input | Lookback window |
| `GH_PAT_FALLBACK` | optional secret | Secondary token if primary lacks access |

## Thresholds

| Status | Failure rate |
|---|---|
| `HEALTHY` | 0% |
| `WARNING` | > 0% and ≤ 20% |
| `DEGRADED` | > 20% and ≤ 50% |
| `CRITICAL` | > 50% |

Thresholds are defined in `scripts/fleet_monitor.sh`.

## Linting

`shellcheck` runs on all PRs that touch `scripts/` or `.github/workflows/` via `.github/workflows/lint.yml`.

## Extending to the full org fleet

See [Discussion #193](https://github.com/petry-projects/.github-private/discussions/193) for the RFC on evolving this into a multi-repo aggregated fleet monitor.
