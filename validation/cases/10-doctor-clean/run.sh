#!/usr/bin/env bash
# shellcheck disable=SC1091
source "$(cd "$(dirname "${BASH_SOURCE[0]}")" && pwd)/../../_lib.sh"

# On a real VPS this is all-green, exit 0. In a container swap can't converge, so
# doctor flags EXACTLY ONE drift (swap) and everything else is green — the honest
# container picture (the all-green/exit-0 case is dogfooded on the VPS).
server "doctor" "doctor"
check "ufw-base green" "$(out_has '✓ ufw-base')"
check "ssh-hardening green" "$(out_has '✓ ssh-hardening')"
check "docker-engine green" "$(out_has '✓ docker-engine')"
check "web-network green" "$(out_has '✓ web-network')"
check "push-to-deploy section present" "$(out_has 'push-to-deploy')"
check "exactly one drift" "$([[ "$(out_count '✗')" == 1 ]] && echo 1 || echo 0)"
check "and the drift is swap (container limit)" "$(out_has '✗ swap')"
verdict
