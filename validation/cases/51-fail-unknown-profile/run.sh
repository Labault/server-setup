#!/usr/bin/env bash
# shellcheck disable=SC1091
source "$(cd "$(dirname "${BASH_SOURCE[0]}")" && pwd)/../../_lib.sh"

# An unknown profile is refused before anything happens (--dry-run keeps it
# read-only and root-free).
server "unknown profile" "setup --profile nope --dry-run"
check "refused" "$(exit_nonzero)"
check "says Unknown profile" "$(out_has 'Unknown profile')"
verdict
