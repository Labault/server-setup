# Profile: `docker`

The container runtime on top of the hardened base. Inherits everything from
[`minimal`](minimal.md) and adds Docker. A stepping stone to [`web`](web.md);
useful on its own for a box that runs containers but isn't a public web host.

## Required binaries

**None** (intentionally not `[docker]`). This profile *installs* Docker, so it
can't require Docker to already be present, that would make the binary guard
refuse to run on the fresh box this profile targets. `requires_bin` lists tools
`server-setup` needs but does **not** install; Docker isn't one.

## Units (on top of `minimal`)

| Unit | What it does | Trace |
| --- | --- | --- |
| `docker-engine` | Docker Engine + the `compose` plugin from the **official Docker apt repo**; idempotent (skips when the binary is present and the daemon is active) | assertion |
| `docker-daemon-json` | `/etc/docker/daemon.json` with **log rotation** (`json-file`, `max-size 10m`, `max-file 3`); restarts Docker only when the file actually changed | `daemon.json` + assertion |
| `deploy-docker-group` | adds the `deploy` user to the `docker` group | assertion |

## The 16 GB lesson

`daemon.json` isn't optional cosmetics. Container logs default to unbounded
`json-file`, and a build cache once grew to 16 GB and filled the disk, taking
`proxy_caddy` down with it. The log rotation here is that scar tissue: nothing
grows in silence anymore.

## Parameters (locked)

- Docker from the **official apt repository** (`download.docker.com`), not the
  distro package.
- `daemon.json`: `log-driver json-file`, `max-size 10m`, `max-file 3`.
- The `deploy` user joins the `docker` group (takes effect on its next login).
