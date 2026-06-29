#!/usr/bin/env bash
# shellcheck disable=SC1091
source "$(cd "$(dirname "${BASH_SOURCE[0]}")" && pwd)/../../_lib.sh"

# Prove the lockout-prevention guard (§10.4): the deploy sudoers is validated by
# `visudo -cf` BEFORE install, and a rejection aborts WITHOUT leaving a broken
# sudoers behind. We force the rejection by shadowing visudo with a stub that
# always fails, and remove the existing sudoers so the deploy-user unit re-runs.
box "shadow visudo + drop the sudoers" \
  "mkdir -p /tmp/fb && printf '#!/bin/sh\nexit 1\n' >/tmp/fb/visudo && chmod +x /tmp/fb/visudo && rm -f /etc/sudoers.d/90-server-setup-deploy"
box "converge with a visudo that rejects the sudoers" \
  "PATH=/tmp/fb:\$PATH /repo/bin/server setup --profile minimal"
check "convergence aborted" "$(exit_nonzero)"
check "blames visudo validation" "$(out_has 'visudo')"
check "no broken sudoers was installed" "$(box_ok '[ ! -f /etc/sudoers.d/90-server-setup-deploy ]')"

box "remove the visudo stub" "rm -rf /tmp/fb"
verdict
