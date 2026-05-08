# AGENTS.md — petry-projects/.github-private

This file defines project-specific development standards for AI agents working in this repository.

It extends the org-level standards defined in [petry-projects/.github/AGENTS.md](https://github.com/petry-projects/.github/blob/main/AGENTS.md).

> Org-level rules apply unless explicitly overridden here.

---

## Project Context

This is the `.github-private` org-wide repository for `petry-projects`, containing scheduled PR review automation, Copilot custom agent profiles, and agentic workflow infrastructure.

Primary language: **Bash** (shell scripts). No compiled or interpreted application code.

---

## Development Standards

### Shell Scripts (`scripts/`)

- Use `set -euo pipefail` at the top of every script
- Quote all variable expansions: `"$VAR"` not `$VAR`
- Use `gh` CLI for GitHub API interactions — do not call the REST API directly with `curl` unless `gh` cannot satisfy the need
- Test scripts locally with `dry_run=true` before pushing

### Workflow Files (`.github/workflows/`)

- Follow [`standards/ci-standards.md`](https://github.com/petry-projects/.github/blob/main/standards/ci-standards.md) for all CI/CD conventions
- Use workflow templates from [`standards/workflows/`](https://github.com/petry-projects/.github/tree/main/standards/workflows) verbatim; adapt only for repo-specific content
- Pin third-party actions to a full commit SHA (never a mutable tag)
- Do **not** modify `claude.yml` or `agent-shield.yml` — these are structurally immutable

### Agent Profiles (`agents/`)

- Follow [`standards/agent-standards.md`](https://github.com/petry-projects/.github/blob/main/standards/agent-standards.md) for all agent configuration
- Skill files (`*.md` with frontmatter) must include `name` and `description` fields

### Prompts (`prompts/`)

- Keep prompts modular — shared taxonomy in `prompts/shared.md`, tier-specific logic in separate files
- Do not embed credentials, tokens, or PII in prompt files

### Frameworks (`frameworks/`)

- Managed via `git subtree` — do not edit framework files directly
- To update: use `git subtree pull` from the framework's upstream

---

## Testing

There is no automated test suite. Validate changes by:

1. Running shell scripts with `dry_run=true` (or equivalent no-op flags) before merging
2. Verifying GitHub Actions syntax with `actionlint` if available
3. Reviewing `gh workflow run` output for the relevant workflow after merging

---

## Labels & Issues

Follow [`standards/github-settings.md`](https://github.com/petry-projects/.github/blob/main/standards/github-settings.md) for label names and colors.
