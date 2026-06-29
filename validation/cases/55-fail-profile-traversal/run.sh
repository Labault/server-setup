#!/usr/bin/env bash
# shellcheck disable=SC1091
source "$(cd "$(dirname "${BASH_SOURCE[0]}")" && pwd)/../../_lib.sh"

# A profile name that tries to escape profiles/ is rejected on FORMAT, before any
# file is touched. --dry-run keeps it read-only and root-free, and resolve_chain
# runs before the root guard, so the format check is the very first gate.
server "path traversal profile" "setup --profile ../../etc/passwd --dry-run"
check "refused" "$(exit_nonzero)"
check "says Invalid profile name" "$(out_has 'Invalid profile name')"
# Distinct from the unknown-profile path: the name never indexes a real file, so
# we must not even reach the existence check.
check "not the Unknown-profile message" "$(out_hasnt 'Unknown profile')"
# It bailed on format, so it never read /etc/passwd through the constructed path.
check "no passwd contents leaked" "$(out_hasnt 'root:x:0:0')"
verdict
