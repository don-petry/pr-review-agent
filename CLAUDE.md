# CLAUDE.md — petry-projects/.github-private

This file provides project-specific instructions for Claude Code when working in this repository.

For development standards, see [AGENTS.md](./AGENTS.md).

---

## Project Overview

This is the `.github-private` org-wide repository for `petry-projects`. It contains:

- **`agents/`** — Copilot custom agent profiles (org-wide, invocable from GitHub.com, VS Code, JetBrains, and Copilot CLI)
- **`prompts/`** — Prompt libraries used by workflows
- **`scripts/`** — Shell orchestration for GitHub Actions
- **`frameworks/`** — Installed agentic frameworks (git subtree: bmad-method, spec-kit, gsd)
- **`.github/workflows/`** — Scheduled automation (PR review, health checks)

## Key Files

| File | Purpose |
|------|---------|
| `AGENT.md` | Full architecture and capabilities of the PR review agent |
| `SETUP.md` | Setup guide |
| `MACHINE_USER_SETUP.md` | Machine user / bot account setup |
| `scripts/review-one-pr.sh` | Cascade orchestrator |
| `scripts/engine.sh` | LLM abstraction layer (claude/copilot dispatch) |
| `scripts/list-prs.sh` | PR enumeration across org |
| `prompts/shared.md` | Shared risk taxonomy and decision gates |

## Workflow Exemptions

The following files are **structurally immutable** — do not open PRs that modify them:

- `.github/workflows/claude.yml` — Anthropic OIDC invariant
- `.github/workflows/agent-shield.yml` — Security boundary

These must be adopted verbatim from `petry-projects/.github/standards/workflows/` and updated only via standards PRs.

## Tech Stack

- **Shell** (bash) — primary scripting language for orchestration
- **GitHub Actions** — CI/CD and automation
- **Claude Code** (via OAuth token) — primary LLM engine
- **GitHub Copilot** (via PAT) — secondary/rubber-duck LLM engine
