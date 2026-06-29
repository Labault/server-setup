# CLAUDE.md

Project context for Claude Code.

## What this is

`server-setup` converges a bare Ubuntu VPS into a hardened, deployable server, up
to the doormat of `push-to-deploy`. It's the **server-level** link in the family:
`mac-dev-setup` (machine) → `bootstrap-web-setup` (project) → **server-setup**
(server) → `push-to-deploy` (runtime).

**The golden rule, non-negotiable: `server-setup` stops where `push-to-deploy`
begins.** Provisioning and hardening only. No app, no Caddyfile, no webhook, no
application compose stack. The mirror of bootstrap's "never install a binary":
here, **never deploy an app**.

## Stack

- **Bash 4+** (the `server` CLI), driving **systemd**, `ufw`, `fail2ban`, Docker.
- No runtime dependency beyond a base Ubuntu image and `git`. **No `yq`, no Python.**
- Manifests in `profiles/*.yaml`, parsed by a hand-rolled `awk` parser.
- Tests: `bats` (unit) + a black-box `validation/` container harness.

## Commands

Quality and tooling go through `make` (tools come from the machine, not the repo):

- `make qa` — run all quality checks
- `make lint` — pre-commit on all files (shellcheck, shfmt, gitleaks, markdownlint, actionlint, lychee)
- `make test` — `bats tests/`
- `make fix` — re-run hooks applying auto-fixes
- `cd validation && ./run-all.sh` — the black-box container harness (Docker required)

## Conventions

- **Commits:** Conventional Commits + leading Gitmoji (`✨ feat:`, `🐛 fix:`,
  `📝 docs:`…). Enforced by a `commit-msg` hook. No AI co-author trailer.
- **Logs to stderr, data to stdout.** `set -euo pipefail`. shellcheck + shfmt clean.
- **`lib/assert.sh` is the single source of predicates** — `setup` and `doctor`
  share it; never duplicate assertion logic.
- Every mutating command has `--dry-run`; mutations require EUID 0.

## Gotchas (carried by the code, but worth knowing)

- The **SSH cutover** arms a 10-minute dead-man's switch; **confirm before any
  reboot** (the timer is in memory). Never `restart` sshd, only `reload`.
- **ufw × Docker:** Docker bypasses ufw. Only Caddy publishes 80/443; the rest
  stays internal. `ufw-docker` is opt-in.
- **Test asymmetry (D15):** `server-setup` can't harden its own ephemeral CI
  runner. The container harness covers the non-destructive parts; `swapon` and the
  real lock-you-out SSH reload are dogfooded on the real VPS.

## Project rules

- The locked spec is `docs/Cahier des charges.md` (French). Decisions in its §11
  are settled, don't relitigate them.
- Adding a **profile** is data (`profiles/*.yaml`). Adding a **unit type** is code
  (a predicate in `assert.sh` + an action in `converge.sh`).
