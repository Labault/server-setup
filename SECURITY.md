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

This project ships configuration and tooling. Secrets must never be committed —
`gitleaks` runs both locally (pre-commit) and in CI to catch them.
