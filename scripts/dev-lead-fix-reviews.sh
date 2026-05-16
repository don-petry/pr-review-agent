#!/usr/bin/env bash
set -euo pipefail
# dev-lead-fix-reviews.sh — handles review-related intents
# Optional: PROMPTS_DIR (defaults to prompts/dev-lead relative to CWD)

source "$(dirname "$0")/engine.sh"

INTENT_TYPE="${INTENT_TYPE:-fix-reviews}"
PR_NUMBER="${PR_NUMBER:-}"
REPO="${REPO:-${GITHUB_REPOSITORY:-}}"
HEAD_SHA="${HEAD_SHA:-}"
DEV_LEAD_DRY_RUN="${DEV_LEAD_DRY_RUN:-false}"
export PROMPTS_DIR="${PROMPTS_DIR:-prompts/dev-lead}"

REVIEWS_MARKER_PREFIX="<!-- dev-lead-fix-reviews pr="

if [ -z "$PR_NUMBER" ] && [ "$INTENT_TYPE" != "rebase" ]; then
  echo "::error::PR_NUMBER is required"
  exit 1
fi

build_and_run() {
  local template_name="$1"
  local prompt_file="/tmp/dev-lead-${template_name}-prompt-$$.md"
  # Export required vars then envsubst
  envsubst < "${PROMPTS_DIR}/${template_name}.md" > "$prompt_file"

  if [ "$DEV_LEAD_DRY_RUN" = "true" ]; then
    echo "[dry-run] would run engine with prompt: $prompt_file ($(wc -l < "$prompt_file") lines)"
    rm -f "$prompt_file"
    return 0
  fi

  local rc=0
  run_writer_with_fallback "$prompt_file" || rc=$?
  rm -f "$prompt_file"
  return "$rc"
}

post_comment() {
  local body="$1"
  if [ "$DEV_LEAD_DRY_RUN" = "true" ]; then
    echo "[dry-run] would post comment: $body"
  else
    gh pr comment "$PR_NUMBER" --repo "$REPO" --body "$body"
  fi
}

# has_reviews_rate_limited_marker: returns 0 if a rate-limited marker for this
# intent+SHA already exists on the PR (dedup check).
has_reviews_rate_limited_marker() {
  local intent="$1"
  local sha="${HEAD_SHA:-}"
  [ -z "$sha" ] && return 1  # no SHA means no dedup possible
  local pattern="${REVIEWS_MARKER_PREFIX}${PR_NUMBER} sha=${sha} intent=${intent} status=rate-limited"
  local count
  count=$(gh api "repos/${REPO}/issues/${PR_NUMBER}/comments" 2>/dev/null \
    | jq "[.[] | select(.body | test(\"${pattern}\"))] | length" 2>/dev/null \
    || echo "0")
  [ "${count:-0}" -gt 0 ]
}

# post_reviews_rate_limited: posts a rate-limited marker for fix-reviews intents
# and (for user-triggered intents) a visible acknowledgment comment.
post_reviews_rate_limited() {
  local intent="$1"

  # Dedup: don't accumulate multiple rate-limited markers for the same SHA+intent
  if has_reviews_rate_limited_marker "$intent"; then
    echo "::notice::rate-limited marker already posted for intent=${intent} SHA=${HEAD_SHA:-none} — skipping duplicate"
    return 0
  fi

  local reset_time
  reset_time=$(cat /tmp/dev-lead-rate-limit-reset 2>/dev/null || true)
  local reset_detail=""
  if [ -n "$reset_time" ]; then
    reset_detail=" reset=${reset_time}"
  fi

  local sha_detail=""
  if [ -n "${HEAD_SHA:-}" ]; then
    sha_detail=" sha=${HEAD_SHA}"
  fi

  local marker="${REVIEWS_MARKER_PREFIX}${PR_NUMBER}${sha_detail} intent=${intent} status=rate-limited${reset_detail} -->"
  local retry_msg="The retry cron will re-attempt automatically."
  if [ -n "$reset_time" ]; then
    retry_msg="${retry_msg} Rate limit resets at: \`${reset_time}\`"
  fi

  local marker_body="${marker}
## Dev-Lead — rate-limited (intent: ${intent})
**PR:** #${PR_NUMBER}
${retry_msg}"

  if [ "$DEV_LEAD_DRY_RUN" = "true" ]; then
    echo "[dry-run] would post rate-limited marker for intent=${intent}"
    echo "$marker_body"
  else
    gh pr comment "$PR_NUMBER" --repo "$REPO" --body "$marker_body"
  fi

  # For user-triggered intents, post a separate visible acknowledgment so the
  # user knows their request was received but deferred — not silently dropped.
  case "$intent" in
    human|human-pr)
      local actor_mention=""
      [ -n "${ACTOR:-}" ] && actor_mention="@${ACTOR} "
      local reset_display="${reset_time:-unknown}"
      local ack_body="> [!NOTE]
> ${actor_mention}I received your request but all AI engines are currently rate-limited. I'll retry automatically once the rate limit clears.
> Rate limit resets at: \`${reset_display}\`"
      if [ "$DEV_LEAD_DRY_RUN" = "true" ]; then
        echo "[dry-run] would post user-visible rate-limit acknowledgment"
        echo "$ack_body"
      else
        gh pr comment "$PR_NUMBER" --repo "$REPO" --body "$ack_body"
      fi
      ;;
  esac
}

handle_rate_limit() {
  local intent="$1"
  echo "::warning::All engines rate-limited for intent=${intent} — posting rate-limited marker"
  post_reviews_rate_limited "$intent"
  exit 2
}

case "$INTENT_TYPE" in
  fix-reviews)
    # Get open review threads
    export PR_NUMBER PR_URL="https://github.com/${REPO}/pull/${PR_NUMBER}"
    export REPO HEAD_SHA
    export BASE_REF="${BASE_REF:-main}"
    OPEN_THREADS_JSON=$(gh api graphql -f query='
      query($owner:String!,$repo:String!,$pr:Int!) {
        repository(owner:$owner, name:$repo) {
          pullRequest(number:$pr) {
            reviewThreads(first:50) {
              nodes { isResolved line path comments(first:5) { nodes { body author { login } } } }
            }
          }
        }
      }' \
      -F owner="${REPO%%/*}" -F repo="${REPO##*/}" -F pr="$PR_NUMBER" \
      --jq '.data.repository.pullRequest.reviewThreads.nodes | map(select(.isResolved == false))' 2>/dev/null || echo "[]")
    export OPEN_THREADS_JSON
    rc=0
    build_and_run "fix-reviews" || rc=$?
    [ "$rc" -eq 2 ] && handle_rate_limit "fix-reviews"
    exit "$rc"
    ;;
  fix-bot-comment)
    export PR_NUMBER PR_URL="https://github.com/${REPO}/pull/${PR_NUMBER}"
    export REPO ACTOR="${ACTOR:-}" COMMENT_BODY="${COMMENT_BODY:-}" HEAD_SHA
    rc=0
    build_and_run "fix-bot-comment" || rc=$?
    [ "$rc" -eq 2 ] && handle_rate_limit "fix-bot-comment"
    exit "$rc"
    ;;
  human)
    export PR_NUMBER PR_URL="https://github.com/${REPO}/pull/${PR_NUMBER}"
    export REPO ACTOR="${ACTOR:-}" USER_INSTRUCTION="${USER_INSTRUCTION:-}" PR_DESCRIPTION="${PR_DESCRIPTION:-}"
    rc=0
    build_and_run "human" || rc=$?
    [ "$rc" -eq 2 ] && handle_rate_limit "human"
    exit "$rc"
    ;;
  human-pr)
    export PR_NUMBER PR_URL="https://github.com/${REPO}/pull/${PR_NUMBER}"
    export REPO PR_TITLE="${PR_TITLE:-}" PR_DESCRIPTION="${PR_DESCRIPTION:-}"
    OPEN_THREADS_JSON=$(gh api graphql -f query='
      query($owner:String!,$repo:String!,$pr:Int!) {
        repository(owner:$owner, name:$repo) {
          pullRequest(number:$pr) {
            reviewThreads(first:50) {
              nodes { isResolved line path comments(first:5) { nodes { body author { login } } } }
            }
          }
        }
      }' \
      -F owner="${REPO%%/*}" -F repo="${REPO##*/}" -F pr="$PR_NUMBER" \
      --jq '.data.repository.pullRequest.reviewThreads.nodes | map(select(.isResolved == false))' 2>/dev/null || echo "[]")
    export OPEN_THREADS_JSON BASE_REF="${BASE_REF:-main}"
    rc=0
    build_and_run "human-pr" || rc=$?
    [ "$rc" -eq 2 ] && handle_rate_limit "human-pr"
    exit "$rc"
    ;;
  rebase)
    export PR_NUMBER="${PR_NUMBER:-}" PR_URL="https://github.com/${REPO}/pull/${PR_NUMBER:-}"
    export REPO BASE_REF="${BASE_REF:-main}" HEAD_REF="${HEAD_REF:-}" CONFLICTING_FILES="${CONFLICTING_FILES:-}"
    if [ "$DEV_LEAD_DRY_RUN" = "true" ]; then
      echo "[dry-run] would run rebase for PR $PR_NUMBER"
      exit 0
    fi
    if [ -z "$PR_NUMBER" ]; then
      echo "::error::PR_NUMBER is required for rebase"
      exit 1
    fi
    gh pr checkout "$PR_NUMBER" --repo "$REPO"
    git fetch origin "$BASE_REF"
    CONFLICTING_FILES=$(git merge-tree "$(git merge-base HEAD "origin/${BASE_REF}")" HEAD "origin/${BASE_REF}" 2>/dev/null | grep "^changed in both" | awk '{print $NF}' || true)
    export CONFLICTING_FILES
    rc=0
    build_and_run "rebase" || rc=$?
    [ "$rc" -eq 2 ] && handle_rate_limit "rebase"
    exit "$rc"
    ;;
  *)
    echo "::error::Unknown intent type: $INTENT_TYPE"
    exit 1
    ;;
esac
