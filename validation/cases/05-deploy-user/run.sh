#!/usr/bin/env bash
# shellcheck disable=SC1091
source "$(cd "$(dirname "${BASH_SOURCE[0]}")" && pwd)/../../_lib.sh"

# State left by the minimal convergence (cases 03/04).
check "deploy user exists" "$(box_ok 'id -u deploy')"
check "deploy is in the sudo group" "$(box_ok 'id -nG deploy | grep -qw sudo')"
check "NOPASSWD sudoers installed" "$(box_ok 'grep -q NOPASSWD /etc/sudoers.d/90-server-setup-deploy')"
check "sudoers passes visudo -cf" "$(box_ok 'visudo -cf /etc/sudoers.d/90-server-setup-deploy')"
check "deploy has a login shell" "$(box_ok 'getent passwd deploy | grep -q /bin/bash')"
verdict
