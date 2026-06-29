#!/usr/bin/env bash
# shellcheck disable=SC1091
source "$(cd "$(dirname "${BASH_SOURCE[0]}")" && pwd)/../../_lib.sh"

# After minimal (and before docker/web), the firewall opens ONLY 22 — the
# firewall grows with the profile (D4); 80/443 must not be open yet. (Patterns
# stay single-token / quote-free so they survive the docker exec shell layer.)
check "ufw is active" "$(box_ok 'ufw status verbose | grep -qw active')"
check "22/tcp allowed" "$(box_ok 'ufw status | grep 22/tcp | grep -qw ALLOW')"
check "80/tcp NOT open yet" "$(box_ok '! ufw status | grep 80/tcp | grep -qw ALLOW')"
check "443/tcp NOT open yet" "$(box_ok '! ufw status | grep 443/tcp | grep -qw ALLOW')"
verdict
