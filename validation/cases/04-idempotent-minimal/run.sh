#!/usr/bin/env bash
# shellcheck disable=SC1091
source "$(cd "$(dirname "${BASH_SOURCE[0]}")" && pwd)/../../_lib.sh"

# Re-running on an already-converged box is a no-op (except swap, which can never
# satisfy in a container). The SSH unit must NOT re-arm the dead-man's switch.
server "re-converge minimal" "setup --profile minimal"
check "no unit converged again" "$(out_has '0 converged')"
check "ssh-hardening already satisfied (no re-arm)" "$(out_has 'ok: ssh-hardening')"
check "swap still the only failure" "$(out_has 'swap: still not satisfied')"
verdict
