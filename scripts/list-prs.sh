#!/usr/bin/env bash
# Enumerate open, non-draft PRs the agent should consider reviewing.
#
# Two buckets, deduped:
#   1. PRs authored by @me across all repos (self-review).
#   2. PRs where @me is a requested reviewer across all repos.
#
# Filters out PRs that have already been reviewed (marked with
# <!-- pr-review-agent v1 sha=... --> in comments).
#
# Output: one PR URL per line on stdout. Drafts and already-reviewed PRs are excluded.

set -euo pipefail

authored=$(gh search prs \
  --state open \
  --author "@me" \
  --draft=false \
  --limit 100 \
  --json url \
  --jq '.[].url')

review_requested=$(gh search prs \
  --state open \
  --review-requested "@me" \
  --draft=false \
  --limit 100 \
  --json url \
  --jq '.[].url')

{
  printf '%s\n' "$authored"
  printf '%s\n' "$review_requested"
} | sort -u | grep -v '^$' || true
