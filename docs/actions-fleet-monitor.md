# Actions Fleet Monitor

A reusable GitHub Actions workflow that dynamically discovers all non-archived repos in an org, all active workflows per repo, and collects run telemetry for each. Surfaces a fleet summary as a Step Summary and (on failure) a GitHub Issue. No external infrastructure required.

## What it measures

For each active workflow across every non-archived repo in the org:

| Signal | Detail |
|---|---|
| Total / success / failed / cancelled | Run counts over the lookback window |
| Failure rate | `failed / total` |
| Duration p50 / p95 | Computed from `created_at` → `updated_at` on completed runs |
| Status | `HEALTHY` / `WARNING` / `DEGRADED` / `CRITICAL` (see thresholds) |

The fleet summary table is sorted by severity so the worst performers appear first.

## Delivery

- **Step Summary** — fleet table written on every run; visible in the Actions UI without leaving GitHub.
- **GitHub Issue** — opened in `.github-private` when any workflow has failed runs; title references the org.

## Usage

The monitor runs automatically on a daily schedule from `.github-private`. No per-repo configuration needed — repos and workflows are discovered dynamically.

To trigger manually:

```bash
gh workflow run actions-fleet-monitor.yml \
  --repo petry-projects/.github-private \
  --field org=petry-projects \
  --field lookback_days=7
```bash

To invoke from another workflow:

```yaml
jobs:
  monitor:
    uses: petry-projects/.github-private/.github/workflows/actions-fleet-monitor.yml@main
    with:
      org: petry-projects
      lookback_days: '7'
    secrets: inherit
```bash

## Inputs

| Input | Required | Default | Description |
|---|---|---|---|
| `org` | no | `petry-projects` | GitHub org to scan — all non-archived repos discovered automatically |
| `lookback_days` | no | `1` | Rolling window of run history to inspect |

## Environment variables (script)

| Variable | Source | Description |
|---|---|---|
| `GH_TOKEN` | `secrets.DON_PETRY_BOT_GH_PAT` | PAT with `actions:read` across the org |
| `ORG` | workflow input | Target org |
| `LOOKBACK_DAYS` | workflow input | Lookback window |

## Thresholds

| Status | Condition |
|---|---|
| `HEALTHY` | 0% failure rate |
| `WARNING` | > 0% and ≤ 20% |
| `DEGRADED` | > 20% and ≤ 50% |
| `CRITICAL` | > 50% |
| `—` | No runs in the lookback window |

Thresholds are defined in `scripts/fleet_monitor.sh`.

## Linting

`shellcheck` runs on all PRs that touch `scripts/` or `.github/workflows/` via `.github/workflows/lint.yml`.

## RFC

See [Discussion #193](https://github.com/petry-projects/.github-private/discussions/193) for the design discussion behind this monitor.
