#!/usr/bin/env bash
# shellcheck disable=SC1091
source "$(cd "$(dirname "${BASH_SOURCE[0]}")" && pwd)/../../_lib.sh"

# Prove the cutover safety gate (§9.4): key-only SSH is refused UP FRONT when the
# deploy user has no authorized_keys, instead of relying on the dead-man's switch
# to rescue a predictable lockout. We strip every key AND remove our SSH drop-in
# (so assert_ssh_hardening fails and the cutover must actually re-run, rather than
# being skipped as already-converged).
box "go keyless + un-harden so the cutover must re-run" \
  "rm -f /root/.ssh/authorized_keys /home/deploy/.ssh/authorized_keys /etc/ssh/sshd_config.d/99-server-setup.conf && systemctl reload ssh"

server "converge minimal with deploy keyless" "setup --profile minimal"
check "cutover refused" "$(exit_nonzero)"
check "explains it refuses the cutover" "$(out_has 'refusing the SSH cutover')"
check "names the missing authorized_keys" "$(out_has 'no authorized_keys')"
check "nothing armed: no drop-in was installed" "$(box_ok '[ ! -f /etc/ssh/sshd_config.d/99-server-setup.conf ]')"

# The crowbar: with the explicit override, the cutover proceeds as before (for
# when the key arrives out-of-band). swap may still fail on this host, so we don't
# assert the exit code — we assert the cutover actually ran and installed.
server "override with --allow-keyless-ssh-cutover" "setup --profile minimal --allow-keyless-ssh-cutover"
check "override lets the cutover proceed" "$(out_has 'ssh-hardening')"
check "drop-in is installed again" "$(box_ok '[ -f /etc/ssh/sshd_config.d/99-server-setup.conf ]')"

# Disarm the dead-man's switch the override re-armed, and restore root's key so a
# kept box (--keep) is left in a sane, reconnectable state.
server "confirm the cutover" "confirm"
check "anti-lockout confirmed" "$(out_has 'confirmed')"
box "restore root's authorized_keys" \
  "echo 'ssh-ed25519 AAAAC3NzaC1lZDI1NTE5AAAAIAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAA validation-box-dummy' > /root/.ssh/authorized_keys && chmod 0600 /root/.ssh/authorized_keys"
verdict
