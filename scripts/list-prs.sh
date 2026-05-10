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
# AGENT_USER is the GitHub identity the workflow PAT belongs to (typically a
# bot account, e.g. don-petry-bot). It is distinct from REVIEWER_USER, which
# is the human who owns the personal repos being scanned and to whom escalations
# are routed. Self-authored PRs by AGENT_USER are filtered out below.
AGENT_USER="${AGENT_USER:-don-petry-bot}"

# Reject AGENT_USER values that aren't valid GitHub usernames before
# interpolating into a jq program. GitHub usernames are 1–39 chars of
# [A-Za-z0-9-] and may not start or end with a hyphen. Anything else is
# either a misconfiguration or an injection attempt — fail loud rather
# than silently dropping PRs.
if ! [[ "$AGENT_USER" =~ ^[A-Za-z0-9](-?[A-Za-z0-9]){0,38}$ ]]; then
  echo "::error::AGENT_USER='$AGENT_USER' is not a valid GitHub username" >&2
  exit 1
fi

all_prs=""

# Filter: exclude PRs authored by AGENT_USER. The workflow PAT authenticates
# as AGENT_USER; GitHub's GraphQL API rejects self-approval unconditionally,
# so any PR authored by the agent is unreviewable by this runner and would
# otherwise burn session capacity (and previously triggered a fatal session
# abort — see issue #96). Filter at enumeration time so self-authored PRs
# never enter the queue.
JQ_NOT_SELF=".[] | select(.author.login != \"$AGENT_USER\") | .url"

# Get all repos in personal account and search each
while IFS= read -r repo; do
  prs=$(gh search prs \
    --state open \
    --repo "$repo" \
    --draft=false \
    --limit 100 \
    --json url,author \
    --jq "$JQ_NOT_SELF" 2>/dev/null || true)
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
    --json url,author \
    --jq "$JQ_NOT_SELF" 2>/dev/null || true)
  all_prs="${all_prs}${prs}"$'\n'
done < <(gh repo list "$TARGET_ORG" --json nameWithOwner --jq '.[].nameWithOwner' 2>/dev/null || true)

printf '%s\n' "$all_prs" | sort -u | grep -v '^$' || true
