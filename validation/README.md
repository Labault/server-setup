# Validation harness

Black-box, end-to-end proof that `server` converges a fresh box into the
push-to-deploy doormat. It's the sibling of `tests/` (fast `bats` unit tests of
the pure logic); this harness exercises the *real* convergence — installing
packages, writing system files, opening the firewall, cutting over SSH.

```sh
cd validation && ./run-all.sh          # run every case
./run-all.sh 03 09                      # run only cases starting with 03 / 09
./run-all.sh --keep                     # leave the box up to poke at it
```

## Why a container (the D15 asymmetry)

`server-setup` hardens a *machine*, so it can't be validated by dropping files in
a temp dir the way `bootstrap` is. `run-all.sh` boots one **disposable,
systemd-enabled container** (the "box"), mounts the repo read-only, and converges
*that* — never the CI runner's host. We do not cut root SSH on an ephemeral
GitHub runner; we cut it on a throwaway container that gets thrown away.

The cases run **in numeric order against the shared box**, whose state
accumulates: `minimal` → `docker` → `web`. So order matters (assertions read the
state left by earlier converge cases).

## What the container can't prove (and where it's proven instead)

Two things physically don't work in a container, by design, not by bug:

| Not testable in a container | Why | Proven instead on… |
|---|---|---|
| `swap` unit | `swapon` is blocked in a container (swap is a host-global resource) | the real VPS (dogfooding) |
| the real, lock-you-out SSH `reload` | the cutover runs here, but the only way to truly prove "you can still get in after root SSH is off" is a real remote session | the real VPS (dogfooding) |

So in the container, a converged box shows **exactly one drift — `swap`** — and
everything else green. `doctor`'s all-green / exit-0 state is the VPS story.

> The SSH cutover sequence itself (sshd -t, loopback key self-test, dead-man's
> switch arm/rollback, `server confirm`) IS exercised here and was dogfooded on a
> disposable Ubuntu VM during development — see the commit history for
> `lib/deadman.sh` and the cutover. The container just can't speak to the one
> guarantee that needs a remote network path.

## Dogfooding on the real VPS (the destructive half)

The truly destructive, environment-specific bits — `swap`, the real SSH reload
that could lock you out, a from-zero `apt` install on a real Hetzner image — are
validated by running `server setup --profile web` on the actual production VPS,
then reconnecting as `deploy` and running `server confirm` and `server doctor`.
That's the half that doesn't fit cleanly in a container; the container covers
everything else, on every push.

## Cases

| # | Case | Proves |
|---|---|---|
| 01 | list | three profiles, inheritance, units |
| 02 | setup-minimal-dry-run | dry-run lists units, mutates nothing |
| 03 | converge-minimal | first convergence; only `swap` fails; `confirm` disarms |
| 04 | idempotent-minimal | re-run is a no-op, SSH unit does not re-arm |
| 05 | deploy-user | non-root sudoer, valid NOPASSWD sudoers |
| 06 | ufw-rules | only 22 open after minimal (firewall grows with the profile) |
| 07 | converge-docker | Docker engine + compose, daemon.json, deploy in docker group |
| 08 | web-network | the `web` network is created |
| 09 | converge-web | **Reference**: idempotent + the full doormat state |
| 10 | doctor-clean | doctor green except the documented `swap` drift |
| 11 | doctor-drift | breaking ufw turns doctor red, exit non-zero |
| 50 | fail-not-root | a mutating command refuses to run as non-root |
| 51 | fail-unknown-profile | an unknown profile is refused |
| 52 | fail-bad-sudoers | a sudoers that fails `visudo -cf` aborts without installing |

Each case writes `output.log` and `RESULT.txt` into its own folder (git-ignored).
