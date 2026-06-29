#!/usr/bin/env bash
# shellcheck disable=SC1091
source "$(cd "$(dirname "${BASH_SOURCE[0]}")" && pwd)/../../_lib.sh"

# Mirror of case 53: there we proved the cutover REFUSES when deploy is keyless.
# Here we prove --authorized-keys is the cure — it seeds deploy from an explicit
# admin key file (not from root), and that seeded key is what lets the cutover
# pass its key gate WITHOUT --allow-keyless-ssh-cutover, even with root keyless.
ADMIN_KEY='ssh-ed25519 AAAAC3NzaC1lZDI1NTE5AAAAIBBBBBBBBBBBBBBBBBBBBBBBBBBBBBBBBBBBBBBBBBBBB admin@laptop'

# The admin file repeats the key and carries a blank line, so the run also
# proves the append+dedup path (the key must land exactly once).
box "write the admin public-key file" \
  "printf '%s\n\n%s\n' '$ADMIN_KEY' '$ADMIN_KEY' > /root/admins.pub"

# Go fully keyless (root AND deploy) and drop our SSH config so the cutover must
# actually re-run. With no admin file this is exactly the lockout case 53 refuses.
box "go keyless (root + deploy) + un-harden so the cutover must re-run" \
  "rm -f /root/.ssh/authorized_keys /home/deploy/.ssh/authorized_keys /etc/ssh/sshd_config.d/99-server-setup.conf && systemctl reload ssh"

# No --allow-keyless-ssh-cutover: the ONLY thing that can satisfy the key gate is
# the admin key we hand in. swap may fail on this host, so we don't assert the
# exit code — we assert the seed and that the cutover actually ran.
server "converge minimal --authorized-keys /root/admins.pub" \
  "setup --profile minimal --authorized-keys /root/admins.pub"

check "deploy has an authorized_keys" "$(box_ok '[ -s /home/deploy/.ssh/authorized_keys ]')"
check "it contains the admin key" "$(box_ok 'grep -qF "admin@laptop" /home/deploy/.ssh/authorized_keys')"
check "the admin key is seeded exactly once (deduped)" \
  "$(box_ok 'grep -cF admin@laptop /home/deploy/.ssh/authorized_keys | grep -qx 1')"
check "no blank line slipped in" \
  "$(box_ok '! grep -qx "" /home/deploy/.ssh/authorized_keys')"
check "authorized_keys is 0600" \
  "$(box_ok 'stat -c %a /home/deploy/.ssh/authorized_keys | grep -qx 600')"
check "authorized_keys is owned by deploy" \
  "$(box_ok 'stat -c %U /home/deploy/.ssh/authorized_keys | grep -qx deploy')"
# The whole point: the seed satisfied the cutover gate without the crowbar.
check "the cutover proceeded (not refused)" "$(out_hasnt 'refusing the SSH cutover')"
check "ssh-hardening ran" "$(out_has 'ssh-hardening')"
check "drop-in installed by the cutover" \
  "$(box_ok '[ -f /etc/ssh/sshd_config.d/99-server-setup.conf ]')"

# Idempotent: re-seeding from the same file must not duplicate the key.
server "re-run with the same --authorized-keys" \
  "setup --profile minimal --authorized-keys /root/admins.pub"
check "still exactly one admin key after re-run" \
  "$(box_ok 'grep -cF admin@laptop /home/deploy/.ssh/authorized_keys | grep -qx 1')"

# Disarm the dead-man's switch the cutover armed, and restore root's key so a
# kept box (--keep) is left sane and reconnectable.
server "confirm the cutover" "confirm"
check "anti-lockout confirmed" "$(out_has 'confirmed')"
box "restore root's authorized_keys" \
  "echo 'ssh-ed25519 AAAAC3NzaC1lZDI1NTE5AAAAIAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAA validation-box-dummy' > /root/.ssh/authorized_keys && chmod 0600 /root/.ssh/authorized_keys"
verdict
