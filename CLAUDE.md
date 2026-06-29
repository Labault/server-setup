# CLAUDE.md

Project context for Claude Code. Enrich this per project.

## Stack

<!-- Describe the stack: language(s), framework(s), key libraries. -->
- Language:
- Framework:
- Datastore:

## Commands

Quality and tooling go through `make` (tools come from the machine, not the repo):

- `make qa` — run all quality checks
- `make lint` — run every pre-commit hook on all files
- `make fix` — re-run hooks applying auto-fixes
- `make hooks` — install git hooks (pre-commit + commit-msg)

## Conventions

- **Commits:** Conventional Commits + optional leading Gitmoji
  (e.g. `✨ feat(scope): subject`). Enforced by a `commit-msg` hook (`scripts/lint-commit-msg.sh`).
- **Quality gates:** CI runs lint, link check and security (gitleaks +
  dependency review). Keep it green.
- Secrets are never committed; `gitleaks` runs locally and in CI.

## Project rules

<!-- Add domain rules, architectural decisions and gotchas here. -->
