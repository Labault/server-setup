#!/usr/bin/env bash
# shellcheck disable=SC1091
source "$(cd "$(dirname "${BASH_SOURCE[0]}")" && pwd)/../../_lib.sh"

# `--deploy-user <name>` overrides the deploy user's name. Runs LAST on purpose: it
# rewrites the box's sudoers to another account, so it must not disturb the
# cases that assert the default `deploy` (05, 54…). The old account is left in
# place — server-setup never deletes a user — which is exactly what we assert.

# A typo must be caught BEFORE any mutation, even in dry-run.
server "reject an invalid --deploy-user" "setup --profile minimal --deploy-user 'Bad Name' --dry-run"
check "invalid username refused" "$(exit_nonzero)"
check "and it says why" "$(out_has 'invalid username')"
check "no such account was created" "$(box_ok '! id -u "Bad Name"')"

# root is refused on principle: the unit converges a NON-root sudoer, and the
# cutover kills root login right after.
server "reject --deploy-user root" "setup --profile minimal --deploy-user root --dry-run"
check "root refused" "$(exit_nonzero)"
check "and it says why" "$(out_has 'uid 0')"

# The real run. ssh-hardening already converged (case 03), so the cutover's
# assertion passes and it doesn't re-run — no dead-man's switch to disarm here.
server "converge minimal --deploy-user ci-deploy" "setup --profile minimal --deploy-user ci-deploy"
check "ci-deploy exists" "$(box_ok 'id -u ci-deploy')"
check "ci-deploy is in the sudo group" "$(box_ok 'id -nG ci-deploy | grep -qw sudo')"
check "sudoers names ci-deploy, not deploy" \
  "$(box_ok 'grep -q "^ci-deploy ALL=(ALL) NOPASSWD:ALL" /etc/sudoers.d/90-server-setup-deploy')"
check "sudoers still passes visudo -cf" "$(box_ok 'visudo -cf /etc/sudoers.d/90-server-setup-deploy')"
check "ci-deploy got a key seeded (from root)" "$(box_ok '[ -s /home/ci-deploy/.ssh/authorized_keys ]')"
check "its authorized_keys is 0600" \
  "$(box_ok 'stat -c %a /home/ci-deploy/.ssh/authorized_keys | grep -qx 600')"
check "the old deploy account is left alone" "$(box_ok 'id -u deploy')"

# The name is persisted, so doctor checks the account that actually exists
# instead of reporting phantom drift on a `deploy` it was never told about.
check "state records deploy_user: ci-deploy" \
  "$(box_ok 'grep -qx "deploy_user: ci-deploy" /var/lib/server-setup/state.yaml')"
server "doctor after the custom-user convergence" "doctor"
check "doctor reads the user back" "$(out_has 'user ci-deploy')"
check "deploy-user still passes for ci-deploy" "$(out_has '✓ deploy-user')"

# Idempotent: a second identical run converges nothing.
server "re-run with the same --deploy-user" "setup --profile minimal --deploy-user ci-deploy"
check "deploy-user is already satisfied" "$(out_hasnt 'converging: deploy-user')"
verdict
