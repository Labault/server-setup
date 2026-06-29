# Architecture

How the `server` CLI is built: a small, layered Bash codebase with **no runtime
dependency beyond the base Ubuntu image and `git`**. No `yq`, no Python, nothing
to `pip install` on a box you're trying to keep lean.

## The layers

`bin/server` (dispatcher) → `lib/common.sh` → `lib/cmd_<name>.sh` → the engine.

- **`bin/server`** — the entry point. Resolves its own location (symlink-safe, so
  `/usr/local/bin/server → /opt/server-setup/bin/server` works), guards against
  bash < 4, parses the global flags (`--dry-run`, `--help`, `--version`), and
  dispatches to the right command module. The command whitelist is deliberate:
  `setup`, `doctor`, `confirm`, `list`, `update`. No `detect` (provisioning is
  never inferred), no `reconcile` (`setup` *is* the reconciliation).
- **`lib/common.sh`** — the shared foundation: colored logging (to **stderr**, so
  stdout stays clean for data), the `--dry-run` switch, `die`, `tildify`, the
  `require_root` guard (EUID 0 for any mutation), the state-file constants, and
  the Friday duck.
- **`lib/cmd_<name>.sh`** — one module per command. Each parses its own options
  and orchestrates the engine. `cmd_setup` drives the convergence; `cmd_doctor`
  re-evaluates predicates and reports; `cmd_confirm` disarms the dead-man's switch.

## The engine

The pieces `cmd_setup` and `cmd_doctor` build on:

- **`lib/manifest.sh`** — a hand-rolled `awk` parser for the small YAML subset the
  profile manifests use (`extends`, `requires_bin`, `files`, `units`), plus
  inheritance resolution (`minimal → docker → web`). Adding a **profile** is data;
  `yq` is banned by design.
- **`lib/assert.sh`** — the re-checkable predicates, **one per unit**. This is the
  *single source of truth* for "is this unit satisfied?": both `setup` (to decide
  whether to act) and `doctor` (to detect drift) call the very same functions, so
  they can never disagree. Predicates are pure: read-only, no stdout, quiet on a
  non-server.
- **`lib/converge.sh`** — the loop and the per-unit **actions**. For each unit:
  evaluate the assertion → if satisfied, skip (idempotence) → otherwise act → re-
  evaluate to confirm. A new unit type is a new predicate (in `assert.sh`) plus a
  new action here, honestly assumed: a convergence engine isn't a file copier.
- **`lib/state.sh` / `lib/state_read.sh`** — write and read
  `/var/lib/server-setup/state.yaml`. The state has **two natures**: managed files
  (with on-disk and template hashes, like bootstrap) **and** assertions (id,
  status, timestamp), the part you can't hash. Emitted and parsed by hand, no `yq`.
- **`lib/deadman.sh`** — the anti-lockout dead-man's switch: arm/disarm a
  `systemd-run --on-active` timer that restores the previous SSH drop-in and
  reloads sshd unless `server confirm` cancels it.
- **`lib/backup.sh`** — a timestamped backup of a system file before it's
  overwritten. No auto-purge in v1; pruning is the operator's call.

The required-binary guard (`requires_bin` per profile) is inlined in `cmd_setup`,
checked before any mutation and skippable with `--skip-bin-check`.

## Layout

```text
bin/server              # dispatcher
lib/
  common.sh             # logging, --dry-run, die, require_root, friday_wink
  cmd_setup.sh          # the convergence loop driver
  cmd_doctor.sh         # re-evaluate assertions + push-to-deploy health
  cmd_confirm.sh        # disarm the anti-lockout switch
  cmd_list.sh           # list profiles, inheritance, bins, units
  cmd_update.sh         # git pull --ff-only in /opt
  manifest.sh           # awk manifest parser + inheritance (no yq)
  converge.sh           # the engine loop + per-unit actions
  assert.sh             # re-checkable predicates (single source)
  state.sh / state_read.sh   # write/read state.yaml (files + assertions)
  deadman.sh            # systemd-run anti-lockout switch
  backup.sh             # timestamped backups
templates/              # managed system files (drop-ins), dest = absolute paths
profiles/               # minimal.yaml, docker.yaml, web.yaml
tests/                  # bats unit tests of the pure logic
validation/             # black-box container harness (see validation/README.md)
```

## Conventions

- **Logs to stderr, data to stdout** — commands can be piped and scripted.
- **`set -euo pipefail`** everywhere; the convergence loop re-asserts after every
  action, so a mid-action failure can't masquerade as success.
- **shellcheck-clean** and **shfmt-clean**. As a Bash tooling repo, it eats the
  family's own dog food: it runs the very `shell` profile bootstrap ships
  (shellcheck + shfmt + bats).
- **The SSH cutover never `restart`s sshd** — only `reload`, so established
  sessions survive. The full anti-lockout sequence is the locked spec's §9.4
  (see [`docs/cahier-des-charges-server-setup.md`](cahier-des-charges-server-setup.md)).
