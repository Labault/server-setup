#!/usr/bin/env bash
# shellcheck disable=SC1091
source "$(cd "$(dirname "${BASH_SOURCE[0]}")" && pwd)/../../_lib.sh"

# On a real VPS this is all-green, exit 0. In a container the only unit that may
# drift is swap (host-dependent), so doctor is green everywhere else; depending
# on the container host there are zero drifts (swap converged) or exactly one
# (swap). Never a non-swap drift.
server "doctor" "doctor"
check "ufw-base green" "$(out_has '✓ ufw-base')"
check "ssh-hardening green" "$(out_has '✓ ssh-hardening')"
check "docker-engine green" "$(out_has '✓ docker-engine')"
check "web-network green" "$(out_has '✓ web-network')"
check "push-to-deploy section present" "$(out_has 'push-to-deploy')"

# Zero drifts, or exactly one that is swap — never anything else.
drifts="$(out_count '✗')"
ok_drift=0
if [[ "$drifts" -eq 0 ]]; then
  ok_drift=1
elif [[ "$drifts" -eq 1 && "$(out_has '✗ swap')" == 1 ]]; then
  ok_drift=1
fi
check "no drift, or swap only (container limit)" "$ok_drift"
verdict
