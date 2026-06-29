#!/usr/bin/env bash
# shellcheck disable=SC1091
source "$(cd "$(dirname "${BASH_SOURCE[0]}")" && pwd)/../../_lib.sh"

# Break a real assertion and prove doctor catches it in red with a non-zero exit.
box "break the firewall" "ufw --force disable"
server "doctor after drift" "doctor"
check "ufw-base now red" "$(out_has '✗ ufw-base')"
check "exit non-zero" "$(exit_nonzero)"
check "drift reported" "$(out_has 'Drift')"

# Restore the firewall so the box is conformant again.
box "restore the firewall" "ufw --force enable"
verdict
