# Changelog

All notable changes to this project are documented here.

The format is based on [Keep a Changelog](https://keepachangelog.com/en/1.1.0/),
and this project adheres to [Semantic Versioning](https://semver.org/spec/v2.0.0.html).

## [Unreleased]

### Changed

- Docs: renamed the locked spec `docs/Cahier des charges.md` to
  `docs/cahier-des-charges-server-setup.md` (kebab-case, no spaces) to match the
  family's naming convention and stop breaking relative links and tooling.
  Updated all references (architecture doc, `CLAUDE.md`, `bin/server`).

### Fixed

- The SSH cutover now refuses up front (fail-fast) when the `deploy` user has no
  `authorized_keys`, instead of switching to key-only SSH and relying on the
  dead-man's switch to rescue a predictable lockout. Override with the explicit
  `--allow-keyless-ssh-cutover` when the key arrives out-of-band.
- `server doctor` no longer reports false timezone drift on a box converged with
  a non-UTC `--timezone`: `setup` now persists `timezone` and `paranoid` in
  `state.yaml`, and `doctor` reads them back instead of hardcoding `UTC`. States
  written before this fix still read (fallback: `UTC`, `paranoid` derived from the
  sysctl drop-in).

### Added

- Validation case `03b-deadman-rollback`: an in-container acceptance test that
  arms a short dead-man's window, deliberately doesn't confirm, and proves the
  timer FIRES and restores the pre-cutover SSH state (DoD #5). Closes the gap
  where the rollback's firing was exercised nowhere — `convergence.bats` only
  rendered the rollback script, and case 03 confirmed immediately.
- The `server` CLI: a desired-state convergence engine that hardens a fresh
  Ubuntu box and lays the `push-to-deploy` doormat (`install.sh` symlinks it into
  `/usr/local/bin`).
- Profiles `minimal → docker → web` with inheritance, parsed from manifests by a
  hand-rolled `awk` parser (no `yq`).
- `server setup --profile <p>`: converges the box, idempotent, writes
  `/var/lib/server-setup/state.yaml` (managed files + assertions), backs up system
  files before overwriting them. `--dry-run` on every mutating command; EUID 0
  required for mutations.
- The SSH cutover (root off, password off) behind the **anti-lockout sequence**:
  `sshd -t` on the merged config, a loopback key self-test, a 10-minute
  `systemd-run` dead-man's switch, `server confirm` to lock it in, and `reload`
  (never `restart`).
- `server doctor`: re-evaluates the converged profile's assertions (reusing
  `lib/assert.sh` as the single source) and reports drift plus `push-to-deploy`
  health. Never mutates. Exit codes for CI, `--strict`.
- `server list` and `server update` (self-update via `git pull --ff-only`, never
  touches the converged box).
- `bats` unit tests of the pure logic, plus a black-box `validation/` harness that
  converges a disposable systemd container through the full chain and runs in CI.
- Docs: README, architecture, a page per profile, a hand-written system-overview
  diagram, the locked spec, and the four-repo family cross-links.
- The Friday easter egg (D14): a non-blocking duck wink on `server setup`.

[Unreleased]: https://github.com/Labault/server-setup/commits/main
