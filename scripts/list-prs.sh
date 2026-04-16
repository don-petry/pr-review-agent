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

# Collect all unique PR URLs
{
  printf '%s\n' "$authored"
  printf '%s\n' "$review_requested"
} | sort -u | grep -v '^$' | while read -r pr_url; do
  # Query the PR for review markers
  # If it has a marker, skip it (continue to next iteration)
  if gh pr view "$pr_url" --json reviews,comments \
    --jq '((.reviews // []) + (.comments // [])) | .[].body | select(. != null)' 2>/dev/null \
    | grep -q "<!-- pr-review-agent v1 sha="; then
    continue
  fi
  # No marker found, output the URL
  echo "$pr_url"
done || true
