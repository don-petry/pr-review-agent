#!/usr/bin/env bash
# Post a PR review based on a verdict JSON.
#
# Inputs:
#   $1 — PR URL
#   $2 — path to verdict JSON (contains decision, risk, summary, findings, body)
#   $3 — DRY_RUN (true/false)
#
# Verdict JSON format:
#   {
#     "decision": "approve|escalate",
#     "risk": "LOW|MEDIUM|HIGH",
#     "summary": "...",
#     "findings": [...],
#     "body": "full markdown review body",
#     "escalate_to_ai": false
#   }

set -euo pipefail

PR_URL="${1:?usage: post-pr-review.sh <pr-url> <verdict-json> <dry-run>}"
VERDICT_JSON="${2:?}"
DRY_RUN="${3:-false}"
PR_HEAD_SHA="${PR_HEAD_SHA:?PR_HEAD_SHA must be set}"

if [ ! -f "$VERDICT_JSON" ]; then
  echo "ERROR: verdict JSON not found at $VERDICT_JSON"
  exit 1
fi

# Extract fields from verdict
DECISION=$(jq -r '.decision' "$VERDICT_JSON")
RISK=$(jq -r '.risk' "$VERDICT_JSON")
BODY=$(jq -r '.body' "$VERDICT_JSON")

# mark_prior_agent_items_obsolete <pr_url>
# After successfully posting a new review/comment, dismiss prior agent reviews
# (state != DISMISSED) and collapse prior agent comments. Identifies agent
# items by the body marker `<!-- pr-review-agent v1 sha=<HEX> -->`. The newest
# agent item by timestamp (which is the just-posted one) is preserved.
# Idempotent: prior comments already wrapped in a `<!-- pr-review-agent
# superseded -->` sentinel are skipped to avoid recursive nesting.
# All API calls are best-effort — failures here must not break the workflow.
mark_prior_agent_items_obsolete() {
  local pr_url="$1"
  local owner_repo pr_num
  owner_repo=$(echo "$pr_url" | sed -E 's|.*/([^/]+)/([^/]+)/pull/.*|\1/\2|')
  pr_num=$(echo "$pr_url" | sed -E 's|.*/([0-9]+)$|\1|')

  local reviews_json comments_json
  reviews_json=$(gh api --paginate "repos/$owner_repo/pulls/$pr_num/reviews" 2>/dev/null || echo '[]')
  comments_json=$(gh api --paginate "repos/$owner_repo/issues/$pr_num/comments" 2>/dev/null || echo '[]')

  # Reviews: dismiss every prior agent review except the newest. State must
  # be APPROVED, COMMENTED, or CHANGES_REQUESTED to be dismissable; DISMISSED
  # ones are already handled, and PENDING ones aren't ours.
  local stale_review_ids
  stale_review_ids=$(echo "$reviews_json" | jq -r '
    sort_by(.submitted_at)
    | map(select(.body != null and (.body | test("<!-- pr-review-agent v1 sha=[a-f0-9]+"))))
    | .[:-1]
    | .[]
    | select(.state == "APPROVED" or .state == "COMMENTED" or .state == "CHANGES_REQUESTED")
    | .id
  ' 2>/dev/null || true)

  if [ -n "$stale_review_ids" ]; then
    while IFS= read -r review_id; do
      [ -z "$review_id" ] && continue
      echo "  dismissing prior agent review $review_id (superseded by $PR_HEAD_SHA)"
      gh api -X PUT "repos/$owner_repo/pulls/$pr_num/reviews/$review_id/dismissals" \
        -f message="Superseded by automated re-review at $PR_HEAD_SHA." \
        -f event=DISMISS >/dev/null 2>&1 || true
    done <<< "$stale_review_ids"
  fi

  # Comments: edit each prior agent comment to wrap its body in a collapsed
  # <details> block. The sentinel `<!-- pr-review-agent superseded -->`
  # prevents re-wrapping on subsequent runs.
  local stale_comments
  stale_comments=$(echo "$comments_json" | jq -c '
    sort_by(.created_at)
    | map(select(.body != null and (.body | test("<!-- pr-review-agent v1 sha=[a-f0-9]+"))))
    | .[:-1]
    | .[]
    | select(.body | test("<!-- pr-review-agent superseded -->") | not)
    | {id: .id, body: .body}
  ' 2>/dev/null || true)

  if [ -n "$stale_comments" ]; then
    while IFS= read -r entry; do
      [ -z "$entry" ] && continue
      local cid old_body new_body
      cid=$(echo "$entry" | jq -r '.id')
      old_body=$(echo "$entry" | jq -r '.body')
      echo "  collapsing prior agent comment $cid (superseded by $PR_HEAD_SHA)"
      new_body=$(printf '<!-- pr-review-agent superseded -->\n<details><summary><em>Superseded by automated re-review at <code>%s</code> — click to expand prior review.</em></summary>\n\n%s\n\n</details>' \
        "$PR_HEAD_SHA" "$old_body")
      jq -n --arg b "$new_body" '{body: $b}' \
        | gh api -X PATCH "repos/$owner_repo/issues/comments/$cid" --input - >/dev/null 2>&1 \
        || true
    done <<< "$stale_comments"
  fi
}

if [ "$DRY_RUN" = "true" ]; then
  echo "=== DRY RUN: Would post review ==="
  echo "Decision: $DECISION"
  echo "Risk: $RISK"
  echo "Body:"
  echo "$BODY"
  exit 0
fi

if [ "$DECISION" != "approve" ] && [ "$DECISION" != "escalate" ]; then
  echo "ERROR: invalid decision '$DECISION'"
  exit 1
fi

# Post the review/comment based on decision
if [ "$DECISION" = "approve" ]; then
  # Post an APPROVED review
  BODY_FILE="/tmp/pr-review-body-$$.txt"
  echo "$BODY" > "$BODY_FILE"

  echo "Posting APPROVED review..."
  gh pr review "$PR_URL" --approve --body "$(cat "$BODY_FILE")" || {
    rc=$?
    echo "ERROR: gh pr review failed with exit code $rc"
    rm -f "$BODY_FILE"
    exit 1
  }
  rm -f "$BODY_FILE"

  # Dismiss prior agent reviews / collapse prior agent comments now that the
  # newest review has landed. Best-effort: failures here don't break the run.
  mark_prior_agent_items_obsolete "$PR_URL"

  # Check merge state and rebase if needed
  MERGE_STATE=$(gh pr view "$PR_URL" --json mergeStateStatus --jq '.mergeStateStatus')
  if [ "$MERGE_STATE" = "BEHIND" ]; then
    OWNER_REPO=$(echo "$PR_URL" | sed -E 's|.*/([^/]+)/([^/]+)/pull/.*|\1/\2|')
    PR_NUM=$(echo "$PR_URL" | sed -E 's|.*/([0-9]+)$|\1|')

    echo "Branch is BEHIND, requesting rebase..."
    gh api -X PUT "repos/$OWNER_REPO/pulls/$PR_NUM/update-branch" -f expected_head_sha="$PR_HEAD_SHA" 2>/dev/null || true

    # Poll for rebase completion (up to 30s)
    for i in 1 2 3 4 5 6; do
      MERGE_STATE=$(gh pr view "$PR_URL" --json mergeStateStatus --jq '.mergeStateStatus')
      [ "$MERGE_STATE" != "BEHIND" ] && break
      sleep 5
    done

    if [ "$MERGE_STATE" = "BEHIND" ]; then
      echo "Still BEHIND after rebase, skipping auto-merge"
      exit 0
    fi
  fi

  # Enable auto-merge
  echo "Enabling auto-merge..."
  gh pr merge "$PR_URL" --auto --squash 2>/dev/null || true

  # Clean up label
  gh pr edit "$PR_URL" --remove-label needs-human-review 2>/dev/null || true

  echo "Review posted and auto-merge enabled"

elif [ "$DECISION" = "escalate" ]; then
  # Check if AI delegation should be used
  if [ "${AI_DELEGATION_ENABLED:-false}" = "true" ] && [ "${REVIEW_CYCLE:-0}" -lt "${MAX_REVIEW_CYCLES:-3}" ] && [ "$RISK" != "HIGH" ]; then
    # Post fix-request comment
    COMMENT_FILE="/tmp/pr-comment-$$.txt"
    NEXT_CYCLE=$((REVIEW_CYCLE + 1))
    cat > "$COMMENT_FILE" <<COMMENT_END
## Review — fix requested (cycle $NEXT_CYCLE/$MAX_REVIEW_CYCLES)

The automated review identified the following issues. Please address each one:

### Findings to fix
[Findings would be inserted here]

### Additional tasks
1. Resolve all unresolved review thread comments from other reviewers
2. Ensure all CI checks pass after your changes
3. Rebase on the target branch if behind
4. Do NOT modify files unrelated to the findings above

_The review cascade will automatically re-review after new commits are pushed._
COMMENT_END

    echo "Posting fix-request comment..."
    gh pr comment "$PR_URL" --body "$(cat "$COMMENT_FILE")" || true
    rm -f "$COMMENT_FILE"

    # Supersede prior agent reviews/comments now that the newest fix-request
    # has landed. A new fix-request also invalidates any prior approval.
    mark_prior_agent_items_obsolete "$PR_URL"
  else
    # Escalate to human
    echo "Escalating to human review..."
    gh pr edit "$PR_URL" --add-label needs-human-review 2>/dev/null || true
    gh pr request-review "$PR_URL" --user don-petry 2>/dev/null || true
  fi
fi

echo "Review action completed"
