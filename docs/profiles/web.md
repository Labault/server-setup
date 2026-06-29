# Profile: `web`

The **push-to-deploy doormat**. Inherits from [`docker`](docker.md) (and so from
[`minimal`](minimal.md)) and adds the last few things `push-to-deploy` needs
before it can clone and start. This is the **finish line**.

## Required binaries

None (inherited from `docker`, which installs Docker itself).

## Units (on top of `docker`)

| Unit | What it does | Trace |
| --- | --- | --- |
| `ufw-web` | `allow 80/tcp` + `443/tcp` — the firewall grows with the profile, opened **here and only here** | assertion |
| `web-network` | `docker network create web`, idempotent. `server-setup` **owns** this network: it creates it and never deletes it | assertion |
| `ufw-docker-guard` | asserts that **no container except Caddy publishes 80/443** to the host (the ufw×Docker footgun) | assertion |
| `ufw-docker-enforce` | **opt-in** (`--ufw-docker`), OFF by default. Installs the pinned `ufw-docker` integration so ufw governs Docker-published ports | conditional |

## The finish line

Once `web` is converged, the box is exactly the doormat `push-to-deploy`'s quick
start expects: the `web` network is present, the `deploy` user exists and is in
the `docker` group, and 80/443 are open. `push-to-deploy`'s compose joins the
`web` network as `external: true` and runs `docker compose up -d` with **no manual
step in between**. `server-setup` stops here, on the doormat; the proxy, the
Caddyfile, the webhook listener, the certs and any app stack are `push-to-deploy`'s
job.

## The ufw × Docker footgun

Docker inserts its own iptables rules and bypasses ufw, so a published container
port is reachable even behind a deny-all firewall. `server-setup` doesn't fight
Docker; it sets the rule of the house instead:

- **Only the Caddy proxy publishes 80/443.** Every app service stays on an
  internal network, reachable only through the proxy.
- `ufw-docker-guard` asserts the invariant: no non-Caddy container publishes those
  ports. At the doormat stage there are no containers, so it holds; later it stays
  a useful guard (a stray `-p 80:80` would punch straight through ufw).
- `ufw-docker` (the project that teaches ufw about Docker) is **opt-in**, documented,
  never enabled by default.

### Opting in: `--ufw-docker`

If the house rule isn't enough and you want ufw to *actually govern* the ports
Docker publishes, pass `--ufw-docker` on the `web` profile:

```bash
server setup --profile web --ufw-docker
```

This activates the `ufw-docker-enforce` unit, which:

- downloads a **pinned, checksum-verified** copy of `ufw-docker` (an immutable
  upstream commit, not a moving `HEAD`, and never a `curl | bash`). A checksum
  mismatch aborts the run rather than executing unverified code;
- runs `ufw-docker install`, which writes a managed `DOCKER-USER` block into
  `/etc/ufw/after.rules` (marker `# BEGIN UFW AND DOCKER`), then reloads ufw;
- is idempotent, and is reflected by `server doctor` (the state file records
  `ufw_docker: 1`, so doctor re-checks the marker on later runs).

**The compromise.** `ufw-docker` **rewrites ufw's tables**. After enabling it,
the firewall behaves differently from plain ufw (a published port is no longer
reachable until you explicitly `ufw-docker allow <container> <port>`), and you now
carry rules you didn't hand-write. That surprise is the whole reason it's **strict
opt-in**: the default stays the consultative guard, and you turn this on only when
you understand what changes. `ufw-docker` is GPLv3, which is why `server-setup`
(MIT) fetches and runs it at converge time rather than vendoring it.

## Parameters (locked)

- `80`/`443` opened **only** at this profile.
- `server-setup` is the **owner of the `web` network** (create-only, never delete).
- Only Caddy publishes 80/443; the rest stays internal. `ufw-docker` is opt-in
  (`--ufw-docker`), never enabled by default (D8).
