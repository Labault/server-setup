#!/usr/bin/env bash
# shellcheck disable=SC1091
source "$(cd "$(dirname "${BASH_SOURCE[0]}")" && pwd)/../../_lib.sh"

# First real convergence. Everything a container can do must converge; swap can
# NOT (swapon is blocked even in a privileged container), so it is the single
# expected failure here and is verified on the real VPS instead (D15).
server "converge minimal" "setup --profile minimal"
check "deploy-user processed" "$(out_has 'deploy-user')"
check "ufw-base processed" "$(out_has 'ufw-base')"
check "fail2ban processed" "$(out_has 'fail2ban')"
check "ssh cutover ran" "$(out_has 'ssh-hardening')"
check "state.yaml written" "$(box_ok '[ -f /var/lib/server-setup/state.yaml ]')"
check "exactly one unit failed" "$([[ "$(out_count 'still not satisfied')" == 1 ]] && echo 1 || echo 0)"
check "and that unit is swap (container limit)" "$(out_has 'swap: still not satisfied')"

# Disarm the SSH dead-man's switch so the box settles to confirm_state: confirmed.
server "confirm" "confirm"
check "anti-lockout confirmed" "$(out_has 'confirmed')"
verdict
