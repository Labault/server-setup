#!/usr/bin/env bash
# shellcheck disable=SC1091
source "$(cd "$(dirname "${BASH_SOURCE[0]}")" && pwd)/../../_lib.sh"

# A mutating command must refuse to run as a non-root user (§9.2). deploy exists
# from the earlier convergence, so run as deploy.
box_as "deploy" "setup as non-root" "/repo/bin/server setup --profile minimal"
check "refused" "$(exit_nonzero)"
check "says it must run as root" "$(out_has 'must run as root')"
verdict
