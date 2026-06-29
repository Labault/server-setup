#!/usr/bin/env bash
# shellcheck disable=SC1091
source "$(cd "$(dirname "${BASH_SOURCE[0]}")" && pwd)/../../_lib.sh"

# Re-running on an already-converged box must not churn: the costly/dangerous
# units stay 'already-ok' and the SSH unit does NOT re-arm the dead-man's switch.
# (swap is excluded — it may legitimately converge now if the host let it fail
# the first time, a container quirk, so we don't assert on it here.)
server "re-converge minimal" "setup --profile minimal"
check "deploy-user already satisfied" "$(out_has 'ok: deploy-user')"
check "ufw-base already satisfied" "$(out_has 'ok: ufw-base')"
check "fail2ban already satisfied" "$(out_has 'ok: fail2ban')"
check "ssh-hardening already satisfied (no re-arm)" "$(out_has 'ok: ssh-hardening')"
check "no unit failed except possibly swap" \
  "$([[ "$(out_count 'still not satisfied')" -le 1 ]] && echo 1 || echo 0)"
verdict
