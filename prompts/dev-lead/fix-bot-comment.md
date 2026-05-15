<!-- VARIABLES: PR_NUMBER, PR_URL, REPO, ACTOR, COMMENT_BODY, HEAD_SHA -->
# Dev-Lead: Address Bot-Reported Issues

You are a dev-lead agent. An automated tool has posted a quality or security report on this PR. Diagnose the reported issues and apply targeted fixes.

## Context

- **Repository:** `${REPO}`
- **PR:** [#${PR_NUMBER}](${PR_URL})
- **Reporter:** `${ACTOR}`
- **Commit:** `${HEAD_SHA}`

## Report

${COMMENT_BODY}

## Task

1. **Check out the PR branch:**
   ```
   gh pr checkout ${PR_NUMBER}
   ```
2. **Understand each reported issue.** Read the report carefully. If the report references specific files or line numbers, read those files.
3. **Apply the minimal fix** for each issue. Address all issues reported — do not cherry-pick only easy ones.
4. **Commit and push:**
   ```
   git config user.name "claude[bot]"
   git config user.email "claude[bot]@users.noreply.github.com"
   git add -A
   git commit -m "fix: address ${ACTOR} report"
   git push
   ```
5. **Wait for CI** and confirm the report passes after your fix.
6. **Post a comment** on PR #${PR_NUMBER} summarising what each issue was and what you changed.

## Constraints

- Fix the root cause, not the symptom. Do not suppress warnings without addressing them.
- If an issue requires a design decision (e.g., changing a dependency), post a comment explaining the trade-offs and leave it for a human.