#!/usr/bin/env bats
# Non-destructive unit tests for the convergence plumbing. They source the libs
# and exercise pure logic (manifest resolution, dispatcher totality, predicate
# safety) — they never mutate the system, so they run anywhere, including CI and
# a dev mac. The destructive end-to-end run is dogfooded on a real box (D15).
load test_helper

setup() {
  SERVER_ROOT="$(cd "$BATS_TEST_DIRNAME/.." && pwd)"
  export SERVER_ROOT
  # converge.sh pulls in assert.sh, backup.sh, state.sh and manifest.sh.
  source "$SERVER_ROOT/lib/common.sh"
  source "$SERVER_ROOT/lib/converge.sh"
}

# The 12 units server-setup implements for the minimal profile, ssh-hardening
# (the SSH cutover) included.
IMPLEMENTED="deploy-user ufw-base fail2ban unattended-upgrades timezone locale timesync swap journald-cap github-known-hosts sysctl-baseline ssh-hardening"

@test "minimal resolves to the 12 declared units, ssh-hardening last" {
  run resolve_units minimal
  [ "$status" -eq 0 ]
  [ "${lines[0]}" = "deploy-user" ]
  [ "${#lines[@]}" -eq 12 ]
  [ "${lines[11]}" = "ssh-hardening" ]
}

@test "ssh-hardening is implemented, not deferred" {
  [[ "$DEFERRED_UNITS" != *" ssh-hardening "* ]]
  declare -f do_unit | grep -q 'ssh-hardening)'
  declare -f assert_unit | grep -q 'ssh-hardening)'
}

@test "deadman rollback restores the previous drop-in, or removes it when new" {
  run deadman_render_rollback /etc/ssh/sshd_config.d/99-server-setup.conf /var/lib/server-setup/ssh-rollback.prev
  [ "$status" -eq 0 ]
  [[ "$output" == *"cp -a"* ]]
  [[ "$output" == *"reload ssh"* ]]

  run deadman_render_rollback /etc/ssh/sshd_config.d/99-server-setup.conf ""
  [ "$status" -eq 0 ]
  [[ "$output" == *"rm -f"* ]]
  [[ "$output" == *"reload ssh"* ]]
}

@test "every implemented unit has an assertion, an action and a description" {
  local assert_body do_body desc_body u
  assert_body="$(declare -f assert_unit)"
  do_body="$(declare -f do_unit)"
  desc_body="$(declare -f unit_describe)"
  for u in $IMPLEMENTED; do
    echo "missing assertion for $u" >&2
    grep -q "${u})" <<<"$assert_body"
    echo "missing action for $u" >&2
    grep -q "${u})" <<<"$do_body"
    echo "missing description for $u" >&2
    grep -q "${u})" <<<"$desc_body"
  done
}

@test "predicates are pure: they never mutate and stay quiet on a non-server" {
  # On a dev box none of these hold; each must return non-zero WITHOUT spewing
  # errors to stdout (stderr noise is suppressed inside the predicates).
  local u out
  for u in $IMPLEMENTED; do
    out="$(assert_unit "$u" 2>/dev/null || true)"
    [ -z "$out" ]
  done
}

@test "sysctl_template switches on PARANOID" {
  PARANOID=0
  run sysctl_template
  [[ "$output" == *"/templates/sysctl/99-server-setup.conf" ]]
  PARANOID=1
  run sysctl_template
  [[ "$output" == *"/templates/sysctl/99-server-setup.paranoid.conf" ]]
}

@test "managed-file units point at existing templates" {
  local u line tpl
  for u in fail2ban unattended-upgrades journald-cap sysctl-baseline ssh-hardening; do
    line="$(unit_managed_file "$u")"
    tpl="$(printf '%s' "$line" | cut -f2)"
    [ -n "$tpl" ]
    [ -f "$tpl" ]
  done
}
