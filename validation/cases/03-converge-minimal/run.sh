#!/usr/bin/env bash
# shellcheck disable=SC1091
source "$(cd "$(dirname "${BASH_SOURCE[0]}")" && pwd)/../../_lib.sh"

# First real convergence. Everything a container can do must converge. swap is
# the one unit whose success depends on the container host: it works on some
# kernels (GitHub runners) and not others (overlay-backed Docker), so it's the
# ONLY unit allowed to fail here — and only swap. The real VPS proves it for
# real (D15).
server "converge minimal" "setup --profile minimal"
check "deploy-user processed" "$(out_has 'deploy-user')"
check "ufw-base processed" "$(out_has 'ufw-base')"
check "fail2ban processed" "$(out_has 'fail2ban')"
check "ssh cutover ran" "$(out_has 'ssh-hardening')"
check "state.yaml written" "$(box_ok '[ -f /var/lib/server-setup/state.yaml ]')"

# At most one unit may fail, and if one does it must be swap (the container's
# only environment-dependent unit) — never anything else.
fails="$(out_count 'still not satisfied')"
ok_fail=0
if [[ "$fails" -eq 0 ]]; then
  ok_fail=1
elif [[ "$fails" -eq 1 && "$(out_has 'swap: still not satisfied')" == 1 ]]; then
  ok_fail=1
fi
check "only swap may fail, nothing else" "$ok_fail"

# Disarm the SSH dead-man's switch so the box settles to confirm_state: confirmed.
server "confirm" "confirm"
check "anti-lockout confirmed" "$(out_has 'confirmed')"
verdict
