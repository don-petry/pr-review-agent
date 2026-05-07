#!/usr/bin/env bash
# Enumerate open, non-draft PRs the agent should consider reviewing.
#
# Searches across two namespaces:
#   1. All open PRs in repos owned by $REVIEWER_USER (personal account)
#   2. All open PRs in repos owned by $TARGET_ORG (organization)
#
# Filters:
#   --draft=false       — skip work-in-progress PRs
#   --checks success    — only include PRs where all CI checks are green;
#                         failing or pending CI PRs are excluded here so they
#                         never consume a review slot. review-one-pr.sh also
#                         enforces this per-PR as a second layer of defence.
#
# Note: Uses repo enumeration instead of @me/@review-requested, which don't work
# with GitHub App tokens (app tokens have no user identity).
#
# Output: one PR URL per line on stdout.

set -euo pipefail

# Configurable via environment / repo variables
REVIEWER_USER="${REVIEWER_USER:-don-petry}"
TARGET_ORG="${TARGET_ORG:-petry-projects}"

all_prs=""

# Get all repos in personal account and search each
while IFS= read -r repo; do
  prs=$(gh search prs \
    --state open \
    --repo "$repo" \
    --draft=false \
    --limit 100 \
    --json url \
    --jq '.[].url' 2>/dev/null || true)
  all_prs="${all_prs}${prs}"$'\n'
done < <(gh repo list "$REVIEWER_USER" --json nameWithOwner --jq '.[].nameWithOwner' 2>/dev/null || true)

# Get all repos in org and search each (require passing checks)
while IFS= read -r repo; do
  prs=$(gh search prs \
    --state open \
    --repo "$repo" \
    --draft=false \
    --checks success \
    --limit 100 \
    --json url \
    --jq '.[].url' 2>/dev/null || true)
  all_prs="${all_prs}${prs}"$'\n'
done < <(gh repo list "$TARGET_ORG" --json nameWithOwner --jq '.[].nameWithOwner' 2>/dev/null || true)

printf '%s\n' "$all_prs" | sort -u | grep -v '^$' || true
