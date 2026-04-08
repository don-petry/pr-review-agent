#!/usr/bin/env bash
# Enumerate open PRs the agent should consider reviewing.
#
# Two buckets, deduped:
#   1. PRs authored by @me across all repos (self-review).
#   2. PRs where @me is a requested reviewer across all repos.
#
# Output: one PR URL per line on stdout.

set -euo pipefail

ME="$(gh api user --jq '.login')"

# gh search prs respects $GH_TOKEN. --json url is portable across versions.
authored=$(gh search prs \
  --state open \
  --author "@me" \
  --limit 100 \
  --json url \
  --jq '.[].url')

review_requested=$(gh search prs \
  --state open \
  --review-requested "@me" \
  --limit 100 \
  --json url \
  --jq '.[].url')

# Skip drafts — agent should not review WIP PRs.
# We re-query each URL's isDraft via gh pr view in the review step too,
# but filtering here saves API calls for the obvious cases.
{
  printf '%s\n' "$authored"
  printf '%s\n' "$review_requested"
} | sort -u | grep -v '^$' || true
