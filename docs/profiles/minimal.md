# Profile: `minimal`

The base of the chain: a **hardened box, no Docker**. OS hardening plus the
boring-but-essential system defaults a fresh VPS lacks. Everything else
([`docker`](docker.md), [`web`](web.md)) extends this.

## Required binaries

None. Every unit uses tools already on a base Ubuntu image (`useradd`, `ufw`,
`timedatectl`, `awk`…) or installs its own dependency via `apt` during the run.

## Units (converged in order)

| Unit | What it does | Trace |
| --- | --- | --- |
| `deploy-user` | non-root `deploy` (rename it with `--user <name>`), in `sudo`, `NOPASSWD` sudoers **validated by `visudo -cf` before install**, `authorized_keys` seeded from the incoming root key | sudoers file + assertion |
| `ufw-base` | `default deny incoming` / `allow out`, `allow 22`, **then** enable, never before the rule (anti-lockout) | assertion |
| `fail2ban` | `sshd` jail (systemd backend, `bantime 1h` / `findtime 10m` / `maxretry 5`) | `jail.local` + assertion |
| `unattended-upgrades` | auto security updates + **auto-reboot at 04:00** | apt drop-in + assertion |
| `timezone` | **UTC** by default, `--timezone <tz>` to override | assertion |
| `locale` | `en_US.UTF-8` generated and set | assertion |
| `timesync` | `systemd-timesyncd` enabled | assertion |
| `swap` | `/swapfile` **2 GiB** + `vm.swappiness=10`, idempotent (won't recreate a healthy swap) | assertion |
| `journald-cap` | `SystemMaxUse` capped so logs never eat the disk | journald drop-in + assertion |
| `github-known-hosts` | GitHub's Ed25519 host key **pinned** into `ssh_known_hosts` (not trust-on-first-use) | assertion |
| `sysctl-baseline` | **empty by default**; network hardening only under `--paranoid` | sysctl drop-in + assertion |
| `ssh-hardening` | root off, password off, pubkey only, applied through the **anti-lockout cutover** (§9.4) | `99-server-setup.conf` + assertion |

## The firewall

`minimal` opens **only port 22**. `80`/`443` arrive with [`web`](web.md). The
firewall grows with the profile; we never leave a port open "just in case".

## The SSH cutover

`ssh-hardening` is the one gesture that can lock you out, so it runs the locked
§9.4 sequence: write the candidate drop-in → `sshd -t` on the merged config →
loopback key self-test → arm a 10-minute `systemd-run` dead-man's switch →
`reload` (never `restart`). Reconnect as `deploy` and `server confirm` within the
window, or it rolls back automatically. **Confirm before any reboot** (the timer
lives in memory).

## The deploy user's name

`deploy` by default; `--user <name>` converges another non-root sudoer instead
(handy on images that already ship an `ubuntu` account). The name is persisted in
`state.yaml`, so `doctor` checks the account the box actually has. It's a
**bootstrap-time choice**: changing it on a converged box creates the new account
and rewrites the sudoers to its name, but leaves the old account in place, we
never delete a user. `root` (and anything at uid 0) is refused: the unit's whole
point is a non-root sudoer, and the cutover turns root login off right after.

## Parameters (locked)

- `deploy` user (or `--user <name>`) with **`NOPASSWD` sudo**, validated by **`visudo -cf`**.
- Timezone **UTC** (override `--timezone`); locale **`en_US.UTF-8`**.
- Swap **2 GiB**, **`swappiness 10`**. Unattended reboot **04:00**.
- Sysctl baseline **empty**; all network hardening behind **`--paranoid`**.
- Rollback window **10 minutes** via `systemd-run`.
