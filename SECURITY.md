# Security Policy

## Reporting a vulnerability

Please report security issues privately rather than opening a public issue.

- Use GitHub's **Report a vulnerability** (Security tab → Advisories), or
- contact the maintainers directly.

Include reproduction steps and the affected version. We aim to acknowledge
reports within a few business days.

## Supported versions

Security fixes target the latest released version unless stated otherwise.

## Scope

`server-setup` hardens a server, so its threat surface is the box it converges,
not just this repo. Notes:

- It holds **zero credentials**: `push-to-deploy` is cloned over HTTPS, and the
  only key it touches is the incoming root key it seeds for the `deploy` user.
- The SSH cutover is built so a misconfiguration **can't lock you out**: `sshd -t`
  on the merged config, a loopback key self-test, and a 10-minute rollback.
  Reports of ways to defeat that guarantee are especially welcome.
- Secrets must never be committed; `gitleaks` runs both locally (pre-commit) and
  in CI to catch them.
