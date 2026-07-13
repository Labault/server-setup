# server-setup

[![CI](https://github.com/Labault/server-setup/actions/workflows/ci.yml/badge.svg)](https://github.com/Labault/server-setup/actions/workflows/ci.yml)
[![Tests](https://github.com/Labault/server-setup/actions/workflows/tests.yml/badge.svg)](https://github.com/Labault/server-setup/actions/workflows/tests.yml)
[![Validation](https://github.com/Labault/server-setup/actions/workflows/validation.yml/badge.svg)](https://github.com/Labault/server-setup/actions/workflows/validation.yml)
[![Security](https://github.com/Labault/server-setup/actions/workflows/security.yml/badge.svg)](https://github.com/Labault/server-setup/actions/workflows/security.yml)
[![Version](https://img.shields.io/github/v/tag/Labault/server-setup)](https://github.com/Labault/server-setup/tags)
[![License: MIT](https://img.shields.io/badge/License-MIT-blue.svg)](LICENSE)

Take a bare Ubuntu VPS and converge it into a **hardened, deployable server**, up
to the exact line where deployment begins, and it will not lock you out doing it.

> A fresh Hetzner box gives you one thing: root over SSH. Turning that into a
> server you'd actually run in production is a manual checklist (non-root user,
> kill root SSH, ufw, fail2ban, swap, unattended upgrades, Docker, the proxy
> network…) and every box drifts a little from the last. Here a forgotten step
> doesn't diverge a config: it leaves a port open. `server-setup` automates the
> checklist and makes it idempotent.

## Why this exists

It's the **server-level link** in a four-repo chain, each tool handing off to the
next one rung down:

```text
mac-dev-setup  →  bootstrap-web-setup  →  server-setup  →  push-to-deploy
   machine             project              server            runtime
 installs the        deposits the        hardens a bare    runs the box in
 binaries            project config      box, lays the     prod (Caddy proxy,
 in ~/               (installs nothing)  doormat           webhook CD, ops)
```

- [mac-dev-setup](https://github.com/Labault/mac-dev-setup) tools the **machine**.
- [bootstrap-web-setup](https://github.com/Labault/bootstrap-web-setup) tools the **project**.
- **server-setup** (this repo) tools the **server**.
- [push-to-deploy](https://github.com/Labault/push-to-deploy) runs the **runtime**.

The guiding rule, non-negotiable: **`server-setup` stops where `push-to-deploy`
begins.** Provisioning and hardening, nothing more. No app, no Caddyfile, no
webhook, no application compose stack. It walks you to the doormat; `push-to-deploy`
opens the door. It's the mirror of bootstrap's rule ("never install a binary"):
here, **`server-setup` never deploys an app**.

## How it works at a glance

`install.sh` symlinks a small `server` CLI into `/usr/local/bin`. The CLI is a
desired-state **convergence engine**, not a templater: it reads a profile, compares
the box to it, and acts only on what drifted. Re-running on a conformant box is a
no-op.

- `server setup --profile <p>` converges the box and writes `state.yaml`.
- `server doctor` re-evaluates the same predicates and reports drift (it never mutates).
- `server confirm` disarms the anti-lockout dead-man's switch after the SSH cutover.
- `server list` / `server update` enumerate profiles and self-update the tool.
- Every mutating command has `--dry-run`; system files are backed up before they're touched.
- `server prune-backups` reclaims those backups on demand (`--older-than 30d` / `--keep 5`); there is no auto-purge.

![server-setup system overview: install.sh symlinks the server CLI into /usr/local/bin; the CLI exposes setup, doctor, confirm, list and update; server setup converges the box (deploy user, ufw, fail2ban, swap, the SSH cutover, Docker, the web network), writes /var/lib/server-setup/state.yaml with managed files and assertions, and arms a 10-minute anti-lockout dead-man's switch on the SSH cutover; that is the finish line where push-to-deploy clones and runs docker compose up -d](docs/assets/images/system-overview.svg)

## Quick start

On a fresh Ubuntu 22.04 / 24.04 box, as root:

```sh
git clone https://github.com/Labault/server-setup.git /opt/server-setup
cd /opt/server-setup && ./install.sh

# Preview everything first — nothing is touched.
server setup --profile web --dry-run

# Converge for real. The SSH cutover arms a 10-minute rollback (see Gotchas).
server setup --profile web

# Or seed the deploy user from your own admin key(s) instead of root's:
server setup --profile web --authorized-keys /root/admins.pub
```

`--authorized-keys <file>` takes a file of public keys (one per line) and seeds
them into the `deploy` user, appended and deduped. It decouples `deploy` from
whatever key root happened to have, and it's what lets the SSH cutover pass its
key gate. Without it, `deploy` inherits root's incoming key (the old behaviour).

`--deploy-user <name>` converges another non-root sudoer than `deploy` (useful on
images that already ship an `ubuntu` account). The name lands in `state.yaml`, so
`doctor` checks the account the box actually has. It's a bootstrap-time choice:
set it on a converged box and you get a *second* account, the old one is left
alone. `root` is refused.

Then reconnect **as the `deploy` user by key** and lock it in:

```sh
ssh deploy@your-box
sudo server confirm     # disarms the rollback; the SSH cutover is now permanent
sudo server doctor      # green = the box is conformant
```

At that point the box is the `push-to-deploy` doormat: `deploy` user, Docker, the
`web` network, ports 80/443 open. `push-to-deploy` clones and `docker compose up -d`
with no manual step in between.

## Profiles

The profile decides **which units are converged** and **which binaries are
required**. They inherit, and the firewall grows with them.

| Profile | For | Adds on top of its parent |
| --- | --- | --- |
| [`minimal`](docs/profiles/minimal.md) | A hardened box, no Docker | deploy user, SSH hardening, ufw (22 only), fail2ban, unattended-upgrades, swap, timezone/locale/timesync, journald cap, GitHub `known_hosts`, sysctl baseline |
| [`docker`](docs/profiles/docker.md) | + container runtime | Docker Engine + compose, `daemon.json` log rotation, `deploy` in the docker group |
| [`web`](docs/profiles/web.md) | + the push-to-deploy doormat | ufw 80/443, the `web` Docker network, the ufw×Docker guard |

`--profile` is **mandatory and explicit**. Provisioning a server isn't a gesture
you let a heuristic guess, so there's no default and no `detect`.

## Gotchas

Four things will bite you if you don't know them. They're by design.

1. **Confirm before any reboot.** The SSH cutover (root off, password off) arms a
   `systemd-run` dead-man's switch that rolls SSH back if you don't `server confirm`
   in time. That timer lives in memory: a **reboot during the window loses it**, so
   confirm *before* you reboot, not after.
2. **The 10-minute window.** After the cutover you have **10 minutes** to reconnect
   as `deploy` and run `server confirm`. Miss it and SSH rolls back to its previous
   state automatically. That's the safety net, not a bug, it's why a bad cutover
   can't lock you out.
3. **ufw × Docker (the footgun).** Docker writes its own iptables rules and bypasses
   ufw, so publishing a container port reaches the world even behind a deny-all
   firewall. The rule of the house: **only the Caddy proxy publishes 80/443**; every
   app service stays on an internal network. `server doctor` asserts no other
   container publishes those ports. Want ufw to actually govern Docker's ports?
   `--ufw-docker` installs the pinned `ufw-docker` integration — opt-in, never
   enabled by default (it rewrites ufw's tables, so you turn it on deliberately).
4. **No key, no cutover.** The cutover refuses up front if the `deploy` user has no
   `authorized_keys`: key-only SSH with no key is a guaranteed lockout, and the
   dead-man's switch is a poor net for a problem you can see coming. `deploy`
   normally inherits root's incoming key during convergence, or you hand it in
   explicitly with `--authorized-keys <file>`; if you're seeding the key
   out-of-band, force it with `--allow-keyless-ssh-cutover` (the crowbar, and it
   looks like one on purpose).

## Testing & proof

- `bats tests/` — fast unit tests of the pure logic (manifest resolution, predicate safety).
- `validation/run-all.sh` — black-box end-to-end proof: it converges a **disposable
  systemd container** through `minimal → docker → web` and asserts the doormat. Never
  the CI runner's host (you don't cut root SSH on an ephemeral runner). See
  [validation/README.md](validation/README.md).
- The genuinely destructive bits a container can't speak to (real `swapon`, the real
  lock-you-out SSH reload) are dogfooded on the actual production VPS.

See [docs/architecture.md](docs/architecture.md) for the layered Bash codebase
(`bin/server` → `lib/common` → `lib/cmd_*` → the converge/assert/state/deadman engine).

## Target & support

- **Ubuntu LTS 22.04 / 24.04** on Hetzner Cloud, supported and tested. Debian
  probably works but isn't guaranteed.
- A **fresh** box: at first run you have only root access. The convergence is
  idempotent, run it again on a converged box and nothing re-runs.

## License

[MIT](LICENSE). Built by [Labault](https://github.com/Labault). 🦆
