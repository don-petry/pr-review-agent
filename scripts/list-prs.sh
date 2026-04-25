#!/usr/bin/env bash
# Enumerate open, non-draft PRs the agent should consider reviewing.
#
# Three buckets, deduped:
#   1. PRs authored by @me across all repos (self-review) — includes those
#      requiring review (e.g., compliance fixes). CI validation happens
#      per-PR in review-one-pr.sh as a second layer of defence.
#   2. PRs where @me is a requested reviewer across all repos.
#
# Filters:
#   --draft=false       — skip work-in-progress PRs
#   --checks success    — only include PRs where all CI checks are green;
#                         failing or pending CI PRs are excluded here so they
#                         never consume a review slot. review-one-pr.sh also
#                         enforces this per-PR as a second layer of defence.
#
# Output: one PR URL per line on stdout.

set -euo pipefail

# PRs authored by @me (no --checks filter to include those awaiting review)
authored=$(gh search prs \
  --state open \
  --author "@me" \
  --draft=false \
  --limit 100 \
  --json url \
  --jq '.[].url')

# PRs where @me is requested as reviewer (require passing checks)
review_requested=$(gh search prs \
  --state open \
  --review-requested "@me" \
  --draft=false \
  --checks success \
  --limit 100 \
  --json url \
  --jq '.[].url')

{
  printf '%s\n' "$authored"
  printf '%s\n' "$review_requested"
} | sort -u | grep -v '^$' || true
