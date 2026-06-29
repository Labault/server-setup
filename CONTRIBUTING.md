# Contributing

Thanks for contributing! This project uses a standardized quality layer set up
by [bootstrap](https://github.com/Labault/bootstrap-web-setup).

## The one rule to keep in mind

**`server-setup` stops where `push-to-deploy` begins.** It provisions and hardens
a box, nothing more, no app, no proxy, no webhook, no application compose stack.
A change that starts deploying things belongs in `push-to-deploy`, not here.

Adding a **profile** is data (`profiles/*.yaml`). Adding a **unit type** is code:
a re-checkable predicate in `lib/assert.sh` (the single source `doctor` reuses)
plus an action in `lib/converge.sh`.

## Getting started

1. Install the git hooks: `make hooks` (or `pre-commit install && pre-commit install --hook-type commit-msg`).
2. Run the checks before pushing: `make qa` and `make test`.
3. For anything touching the convergence, run the black-box harness:
   `cd validation && ./run-all.sh` (needs Docker). It converges a disposable
   systemd container, never your host.

The tools (pre-commit, gitleaks, shellcheck, …) come from your machine, not from
this repository.

## Commit messages

Commits follow **Conventional Commits** with an optional leading **Gitmoji**:

```text
<emoji> <type>(<scope>): <subject>
```

Examples:

- `✨ feat(api): add pagination to the orders endpoint`
- `🐛 fix: handle empty cart on checkout`
- `📝 docs: document the deploy procedure`

Allowed types: `feat`, `fix`, `docs`, `style`, `refactor`, `perf`, `test`,
`build`, `ci`, `chore`, `revert`. A `commit-msg` hook (`scripts/lint-commit-msg.sh`) enforces this on commit.

## Pull requests

- Keep PRs focused and small.
- Make sure CI is green (`lint`, `links`, `security`).
- Fill in the pull request template.
