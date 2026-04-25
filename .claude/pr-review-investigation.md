# PR Review Agent Workflow Failure Investigation

**Investigation Date:** 2026-04-19  
**Workflow:** PR Review Agent (`.github/workflows/pr-review.yml`)  
**Status:** All recent runs failing with same root cause

## Executive Summary

All 5 recent workflow runs (completed between 11:21-15:23 UTC on 2026-04-19) failed at the exact same point: the "Enumerate candidate PRs" step. The failure is caused by a **breaking change in GitHub CLI** where the `gh search prs --checks` flag no longer accepts the value `passing`.

## Root Cause Analysis

### Primary Failure: Invalid `--checks` Flag Value

**Location:** `scripts/list-prs.sh` lines 23 and 32

**Error Message:**
```
invalid argument "passing" for "--checks" flag: valid values are {pending|success|failure}
```

**Root Cause:**
GitHub CLI changed the valid values for the `--checks` filter in `gh search prs` from:
- **Old:** `passing` (and others)
- **New:** `{pending|success|failure}` only

**Impact:**
- **Severity:** Critical
- **Scope:** 100% of workflow runs (since PR enumeration fails, no reviews can proceed)
- **Affected Code:** Both `authored` and `review_requested` searches in list-prs.sh
- **User Impact:** No PRs are being enumerated, reviewed, or processed

**Current Script Code:**
```bash
# Line 23:
--checks passing \

# Line 32:
--checks passing \
```

**Required Fix:**
Replace `--checks passing` with `--checks success` (semantically equivalent: "success" means all checks passed)

---

## Secondary Issues

### Missing Token Scope: `read:org`

**Detected in:** Workflow logs during "Verify auth" step

**Current Token Scopes:**
- `read:audit_log`
- `read:packages`
- `read:user`
- `repo`
- `write:discussion`

**Missing Scope:** `read:org`

**Status:** Not currently blocking runs (primary failure happens first), but may affect operations that:
- Check org membership
- Enumerate org-owned repos
- Access org-level settings or rules

**Recommendation:** Add `read:org` scope to GH_PAT token to prevent future issues if the workflow is expanded to handle org-level operations.

---

## Failure Categories

### All 5 Recent Failures: Same Root Cause

| Run ID | Time | Duration | Error |
|--------|------|----------|-------|
| 24632451780 | 2026-04-19 15:23:07Z | 14s | `--checks passing` invalid |
| 24631285908 | 2026-04-19 14:23:27Z | 11s | `--checks passing` invalid |
| 24630360330 | 2026-04-19 13:35:32Z | 15s | `--checks passing` invalid |
| 24629036038 | 2026-04-19 12:25:25Z | 16s | `--checks passing` invalid |
| 24627885581 | 2026-04-19 11:21:45Z | 12s | `--checks passing` invalid |

**Failure Distribution:**
- Permission/Access denied errors: **0**
- API rate limits: **0**
- Missing token scopes: **0** (blocking)
- GitHub CLI breaking change: **5** (100%)

---

## Why This Matters

The workflow is **completely blocked**. Even though:
- Authentication is working (`gh auth status` succeeds)
- Token scopes are sufficient for listing (the error occurs in the CLI validation, not in API calls)
- No rate limits are being hit

The workflow **cannot enumerate any PRs**, which means:
1. Zero reviews are posted
2. Zero code changes are reviewed by the AI agent
3. All scheduled runs fail silently (except for logs)

---

## Recommended Actions

### Immediate Fix (Required)

**File:** `scripts/list-prs.sh`

**Changes:**
1. Line 23: Replace `--checks passing` with `--checks success`
2. Line 32: Replace `--checks passing` with `--checks success`

**Why:** `success` is the correct GitHub CLI value for "all checks have passed". The semantic meaning is identical to the intended `passing` filter.

**Testing:** After the fix, the workflow should:
1. Successfully enumerate candidate PRs
2. Process them through the review cascade
3. Post reviews (if `DRY_RUN=false` and `LIVE_MODE=true`)

### Secondary Fix (Recommended)

**Update token scopes:**

Add `read:org` scope to the GH_PAT token to future-proof the workflow against expansion to org-level operations.

**How:** 
```bash
gh auth refresh -h github.com -s read:org
```

Then update the repository secret:
```bash
gh secret set GH_PAT --body "$(gh auth token)" --repo don-petry/self
```

---

## Investigation Method

1. Listed recent failed runs: `gh run list --workflow pr-review.yml --status failure`
2. Examined full logs: `gh run view <run-id> --log`
3. Identified common error pattern in "Enumerate candidate PRs" step
4. Reviewed `scripts/list-prs.sh` source code
5. Cross-referenced error message against GitHub CLI documentation
6. Confirmed pattern across all 5 recent runs

---

## Verification Steps

After applying the fix:

1. Run workflow manually:
   ```bash
   gh workflow run pr-review.yml --repo don-petry/self
   ```

2. Monitor the run:
   ```bash
   gh run list --workflow pr-review.yml --status in_progress --limit 1
   gh run view <run-id> --log
   ```

3. Verify the "Enumerate candidate PRs" step completes successfully with candidate PR count reported

4. Confirm subsequent steps (Install CLIs, Verify auth, Review each PR) proceed

---

## Notes

- The workflow is well-structured with good error handling and fallback logic (Claude → Copilot on rate limit)
- Token scopes are mostly complete, just missing `read:org` for org-level operations
- The fix is a one-line semantic change in two places (backward compatible in intent, just using new CLI syntax)
