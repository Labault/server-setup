# Changelog

All notable changes to this project are documented here.

The format is based on [Keep a Changelog](https://keepachangelog.com/en/1.1.0/),
and this project adheres to [Semantic Versioning](https://semver.org/spec/v2.0.0.html).

## [Unreleased]

## [0.2.0] - 2026-06-29

### Security

- A profile name is now validated for format (`^[a-z][a-z0-9-]*$`) at the head of
  `resolve_chain`, before it is ever used to build a file path. Previously a name
  like `--profile ../../etc/passwd` was only caught by the later file-existence
  check, so a traversal pointing at a real file could read outside `profiles/`.
  The format guard fires first, with a message distinct from "Unknown profile".
  Validation case `55-fail-profile-traversal` proves the refusal.

### Changed

- Docs: renamed the locked spec `docs/Cahier des charges.md` to
  `docs/cahier-des-charges-server-setup.md` (kebab-case, no spaces) to match the
  family's naming convention and stop breaking relative links and tooling.
  Updated all references (architecture doc, `CLAUDE.md`, `bin/server`).

### Fixed

- `timesync` no longer drifts on a real VPS. `do_timesync` only ran
  `systemctl enable systemd-timesyncd` without ever installing the package, so on
  a box where it was absent (a fresh Hetzner image) the `enable` silently no-op'd
  (`|| true`) and `server doctor` reported drift. The bug was masked in CI by the
  validation Dockerfile, which pre-installed `systemd-timesyncd` so the box lied
  about a fresh box's real state. Two fixes: `do_timesync` now removes a competing
  NTP daemon (`chrony`/`ntp`/`ntpsec`) if present, installs `systemd-timesyncd`
  (failing the provisioning if the install fails, instead of masking it) and
  unmasks the unit before enabling; the validation box drops `systemd-timesyncd`
  and ships `chrony` instead, so it reproduces a fresh Hetzner box and exercises
  the purge path.
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

- `server prune-backups` purges the timestamped backups `setup` leaves under
  `/var/backups/server-setup/`. server-setup still **never auto-purges** (§9.6,
  locked): reclaiming that disk is now an explicit operator command instead of a
  manual `rm`. Two composable policies: `--older-than <dur>` (e.g. `30d`, `12h`,
  `2w`) deletes backups older than the cutoff, `--keep <n>` retains only the `n`
  most recent. Given both, `--keep` is a floor `--older-than` can't cross (a
  backup is deleted only when old AND beyond the kept set). `--dry-run` lists what
  would go without deleting (and without needing root); the real purge requires
  EUID 0 like every other mutation. Proven by `prune_backups.bats` (selection +
  dry-run safety + non-root refusal) and validation case `57-prune-backups`.
- `server setup --profile web --ufw-docker` opts into real ufw×Docker enforcement
  (D8): a new `ufw-docker-enforce` unit installs a **pinned, checksum-verified**
  copy of `ufw-docker` (immutable upstream commit, never a `curl | bash` of a
  moving `HEAD`; a checksum mismatch aborts the run) and wires its `DOCKER-USER`
  block into `/etc/ufw/after.rules` so ufw governs the ports Docker publishes.
  **OFF by default and never auto-enabled**: without the flag the unit is skipped
  and only the consultative `ufw-docker-guard` runs, so behaviour is unchanged.
  The choice is recorded as `ufw_docker` in `state.yaml`, and `server doctor`
  reads it back to re-check the marker (skipping the unit on boxes converged
  without the flag). The compromise (ufw-docker rewrites ufw's tables and can
  surprise you) is why it's strict opt-in. Proven by validation case
  `56-ufw-docker-enforce` and `convergence.bats` gating tests.
- `server setup --authorized-keys <file>` seeds the `deploy` user from an explicit
  file of admin public keys (one per line), appended and deduped (`0600`, owner
  `deploy`). It decouples `deploy` from whatever key root happened to have, and is
  what lets the SSH cutover pass its key gate without root owning a key. Without
  the flag, behaviour is unchanged: `deploy` inherits root's incoming key. A bad
  path fails fast, before any mutation. Proven by `merge_authorized_keys` unit
  tests and validation case `54-authorized-keys-seed`.
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

[Unreleased]: https://github.com/Labault/server-setup/compare/v0.2.0...HEAD
[0.2.0]: https://github.com/Labault/server-setup/releases/tag/v0.2.0
