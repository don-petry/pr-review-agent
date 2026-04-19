#!/usr/bin/env bash
# Enumerate open, non-draft PRs the agent should consider reviewing.
#
# Two buckets, deduped:
#   1. PRs authored by @me across all repos (self-review).
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

authored=$(gh search prs \
  --state open \
  --author "@me" \
  --draft=false \
  --checks success \
  --limit 100 \
  --json url \
  --jq '.[].url')

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
