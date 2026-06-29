#!/usr/bin/env bash
# shellcheck disable=SC1091
source "$(cd "$(dirname "${BASH_SOURCE[0]}")" && pwd)/../../_lib.sh"

server "list" "list"
check "minimal listed" "$(out_has 'minimal')"
check "docker extends minimal" "$(out_has 'extends minimal')"
check "web extends docker" "$(out_has 'extends docker')"
check "ssh-hardening unit listed" "$(out_has 'ssh-hardening')"
check "exit 0" "$(exit_is 0)"
verdict
