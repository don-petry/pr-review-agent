---
name: feature-ideation
description: Adversarial AI feature ideation. Claude proposes a spec, Codex challenges it, Claude refines. Iterative loop until approved. Auto-detects input mode from context.
user_invocable: true
---

# Adversarial Feature Ideation

> **Platform:** Claude Code only. This skill orchestrates Claude ↔ Codex interaction, where Claude is the proposer/refiner and Codex is the external adversarial challenger. Running this skill from Codex CLI itself creates a recursive loop — if you are Codex, do NOT invoke this skill; perform the challenge directly.

Takes a feature idea — from a GitHub issue, a description in context, or a raw statement — and stress-tests it through an adversarial loop. Claude writes the spec. Codex tries to break it. Claude fixes the spec and resubmits. Maximum 5 rounds.

**Inspiration:** [github.com/topics/adversarial-review](https://github.com/topics/adversarial-review)

---

## When to invoke

- `/ideate-feature` — auto-detect the feature idea from context
- `/ideate-feature <description>` — ideate from a short inline description
- `/ideate-feature <issue-url>` — ideate from a GitHub issue URL (argument contains `github.com`)
- `/ideate-feature <file-path>` — ideate from an existing spec or notes file (argument contains `/` or `.`)
- Override reasoning effort: `/ideate-feature xhigh` or `/ideate-feature medium` (one of: `medium`, `high`, `xhigh`)
- Override model: `/ideate-feature model:gpt-5.3-codex` (argument with `model:` prefix)

## Instructions

> **Placeholders:** `${IDEATION_ID}` and `${CODEX_SESSION_ID}` in the steps below are template placeholders, NOT shell variables. Substitute literal values directly into each tool call.

### Step 1: Determine the feature idea

Determine what to ideate. Check in priority order:

**1. Explicit argument:**
   - GitHub issue URL (`github.com`) → fetch the issue: `gh issue view <url> --json number,title,body,labels`
   - File path (contains `/` or `.`) → read the file directly. Do NOT copy.
   - Short description → use verbatim as the raw idea.

**2. Auto-detect from context** (no explicit argument):
   - Look for a feature request, user story, or idea in the recent conversation.
   - Look for an open GitHub issue linked in context.
   - If none found → ask the user: "What feature would you like to ideate on?"

**Print the raw idea for the user** before proceeding:
```
Feature idea: <one-sentence summary>
```

### Step 2: Generate Session ID

Generate a unique `IDEATION_ID` yourself, format: `{unix_timestamp}-{random_4digit_number}`.
Example: `1711872000-4821`. **Do NOT use bash** — substitute the value directly into commands in the following steps.

### Step 3: Write the initial feature proposal

Write a structured feature proposal to `/tmp/ideation-spec-${IDEATION_ID}.md` using the **Write tool**. The proposal MUST cover:

- **Title** — crisp, specific name for the feature
- **Problem** — what pain does this solve and for whom? One paragraph.
- **Proposed solution** — how it works at a user-visible level. 2-4 paragraphs.
- **Implementation sketch** — key technical changes (files, components, APIs, config). Be concrete and grounded in the actual repo structure (inspect files as needed).
- **Acceptance criteria** — testable checklist (`- [ ] ...`) confirming the feature is complete.
- **Effort estimate** — `XS | S | M | L | XL` + 1 sentence rationale.
- **Open questions** — up to 5 questions that must be resolved before implementation.

**Always print the spec file path for the user:**
```
Spec for review: /tmp/ideation-spec-${IDEATION_ID}.md
```

### Step 4: Build the adversarial prompt and launch Codex

Build the challenger prompt and write it to `/tmp/ideation-prompt-${IDEATION_ID}.md` via **Write tool**:

```
<role>
You are a senior adversarial reviewer of feature specifications.
Your job is to break confidence in the spec, not to validate it.
</role>

<operating_stance>
Default to skepticism. Assume the spec has gaps until the evidence says otherwise.
Do not give credit for good intent, anticipated follow-up work, or "we'll figure it out later."
If something only works on the happy path, treat that as a real weakness.
</operating_stance>

<task>
Review the feature specification in <spec-path>.
</task>

<attack_surface>
Check each area. Skip if not applicable:
- Value — does this solve a real, meaningful pain? Is the problem overstated or niche?
- Feasibility — will this approach actually work given the codebase and constraints?
- Scope — is the scope too large? Are there hidden dependencies or unrelated work sneaking in?
- Completeness — are acceptance criteria measurable? What edge cases and error paths are missing?
- Risk — what can go wrong? Security, data loss, cost overrun, runaway automation, token billing surprises?
- Alternatives — what simpler or cheaper alternative would give 80% of the value?
- Open questions — are the right questions being asked? What critical question is missing?
</attack_surface>

<finding_bar>
Each finding MUST answer:
1. What can go wrong? (concrete scenario, not hypothetical)
2. Why is this spec vulnerable? (cite specific section)
3. Impact — what breaks or fails and how badly?
4. Recommendation — specific, actionable change to the spec
</finding_bar>

<scope_exclusions>
DO NOT comment on: wording style, formatting, speculative issues without concrete trigger scenario,
"nice to have" additions unrelated to the stated goal.
</scope_exclusions>

<calibration>
Prefer one strong finding over several weak ones.
If the spec is solid, say so clearly — false positives erode trust.
Severity: blocking (prevents approval) > high (major gap) > medium (notable weakness).
</calibration>

<output_format>
Use markdown headers for sections: Summary, Findings, Verdict.

Summary: one paragraph — what this feature proposes and your overall assessment.

Findings: for each finding, use a sub-header with [severity: blocking|high|medium] and title.
Include these fields per finding:
- **Section:** which part of the spec
- **What can go wrong:** ...
- **Why vulnerable:** ...
- **Impact:** ...
- **Recommendation:** ...

If no findings: "No actionable findings."

Verdict rules: approve if no findings or all low severity; revise if any high/blocking.
Choose exactly one. The LAST line of your response must be one of:
VERDICT: APPROVED
VERDICT: REVISE
</output_format>
```

Launch Codex:

```bash
timeout 600 codex exec \
  -m gpt-5.4 \
  -c model_reasoning_effort=high \
  -s read-only \
  -o /tmp/ideation-review-${IDEATION_ID}.md \
  - < /tmp/ideation-prompt-${IDEATION_ID}.md \
  2>/tmp/ideation-stderr-${IDEATION_ID}.txt
```

Use `timeout: 620000` in the Bash tool parameters.

After launch: extract the session ID from `/tmp/ideation-stderr-${IDEATION_ID}.txt` — find the line `session id: <uuid>` and save it as `CODEX_SESSION_ID` for later `resume` calls.

**Notes:**
- Always wrap in `timeout 600`. If Codex hangs, exit code 124.
- The command is **synchronous** — do NOT use a poll loop.
- Default: `gpt-5.4` with `model_reasoning_effort=high`. Override via `model:...` argument.
- Always `-s read-only` — Codex must not write files.

### Step 5: Read the review and check the verdict

1. Read `/tmp/ideation-review-${IDEATION_ID}.md`
2. Show the user **verbatim** — do not rephrase findings:

```
## Adversarial Ideation Review — Round N (model: gpt-5.4)

[Reviewer's response — verbatim]
```

3. Check the verdict:
   - **VERDICT: APPROVED** → proceed to Step 8 (Done)
   - **VERDICT: REVISE** → proceed to Step 6 (Refine)
   - No clear verdict → treat as parse failure, request a clear verdict via resume/fallback
   - Maximum reached (5 rounds) → proceed to Step 8 with a note

### Step 6: Refine the spec

Based on the reviewer's findings, update the spec at `/tmp/ideation-spec-${IDEATION_ID}.md`:

- Address each `blocking` or `high` finding — revise the relevant section.
- Address `medium` findings where the fix is clear and bounded.
- **Skip** a fix if it contradicts the user's explicit requirements — note this for the user.

Show the user:

```
### Spec revisions (Round N)
- [What was changed and why, one item per finding]
```

### Step 7: Resubmit to Codex (Rounds 2-5)

**Resume is the primary path.** Saves tokens and preserves session context. Fresh exec is the emergency fallback — significantly more expensive.

1. Write the resume prompt to `/tmp/ideation-prompt-${IDEATION_ID}.md` via **Write tool** (overwrite):

```
I've revised the spec based on your feedback.

Here's what I changed:
[List of spec revisions]

Re-review with the same adversarial stance. Focus on:
1. Whether my revisions actually resolve the reported issues
2. Any NEW weaknesses introduced by the revisions

End with VERDICT: APPROVED or VERDICT: REVISE
```

2. Resume:

```bash
timeout 600 codex exec resume ${CODEX_SESSION_ID} \
  - < /tmp/ideation-prompt-${IDEATION_ID}.md \
  2>/tmp/ideation-stderr-${IDEATION_ID}.txt
```

Use `timeout: 620000` in Bash tool parameters. Do NOT pass `-s` to resume — sandbox is inherited.

3. Check exit code:
   - **exit 0** — success. Show stdout verbatim to user. Check VERDICT. APPROVED → Step 8. REVISE → Step 6.
   - **exit 124** — timeout. Tell the user and offer to retry.
   - **other** — resume failed. Check stderr. Proceed to Fallback.

**Fallback** — if resume fails (session expired, session ID not captured, error):

1. Write a fresh prompt describing previous rounds to `/tmp/ideation-prompt-${IDEATION_ID}.md`.
2. Launch a fresh `codex exec` using the same template as Step 4 (stdin via `- < file`, stderr to temp file, `-o` for output).
3. **Extract new session ID** from stderr and **refresh `CODEX_SESSION_ID`**.

Return to Step 5.

### Step 8: Final result

**Approved:**

```
## Adversarial Ideation — Summary (model: gpt-5.4)

**Status:** Approved after N round(s)

[Final review verbatim]

---
**Spec approved by the adversarial reviewer. File:** `/tmp/ideation-spec-${IDEATION_ID}.md`

Next steps:
- Open or update a GitHub issue with the refined spec
- Add the `feature-spec-ready` label to signal it is implementation-ready
```

**Maximum rounds reached:**

```
## Adversarial Ideation — Summary (model: gpt-5.4)

**Status:** Maximum reached (5 rounds) — not fully approved

**Remaining findings:**
[Unresolved issues verbatim]

**Spec file:** `/tmp/ideation-spec-${IDEATION_ID}.md`

---
**The reviewer still has findings. Please review them and decide how to proceed.**
```

### Step 9: Cleanup

```bash
rm -f /tmp/ideation-prompt-${IDEATION_ID}.md /tmp/ideation-review-${IDEATION_ID}.md \
      /tmp/ideation-stderr-${IDEATION_ID}.txt
```

Do NOT delete the spec file (`/tmp/ideation-spec-${IDEATION_ID}.md`) — the user may want to copy it to an issue or file.

If rm is declined — continue without error.

**In Claude Code Plan Mode:** skip all cleanup. Files will be cleaned up on the next invocation outside Plan Mode.

## Rules

- Claude **actively refines** the spec based on reviewer feedback — this is NOT just message forwarding
- Reviewer findings are shown **verbatim** — do not rephrase or shorten
- Auto-detect the feature idea from context; explicit arguments take priority
- Resume is the primary path for subsequent rounds. Fresh exec is an emergency fallback (expensive)
- Cleanup is best-effort: skip in Plan Mode, continue without error if declined
- Always read-only sandbox — Codex never writes files
- Maximum 5 rounds to protect against infinite loops
- Show the user the review and spec revisions for each round
- If Codex CLI is not installed or crashed — tell the user: `npm install -g @openai/codex`
- If a revision contradicts the user's explicit requirements — skip and explain why
