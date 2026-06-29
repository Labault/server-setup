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

@test "minimal resolves to the 12 declared units, ssh-hardening last" {
  run resolve_units minimal
  [ "$status" -eq 0 ]
  [ "${lines[0]}" = "deploy-user" ]
  [ "${#lines[@]}" -eq 12 ]
  [ "${lines[11]}" = "ssh-hardening" ]
}

@test "web resolves the full chain minimal -> docker -> web (18 units)" {
  run resolve_chain web
  [ "$status" -eq 0 ]
  [ "${lines[0]}" = "minimal" ]
  [ "${lines[1]}" = "docker" ]
  [ "${lines[2]}" = "web" ]

  run resolve_units web
  [ "$status" -eq 0 ]
  [ "${#lines[@]}" -eq 18 ]
  # minimal units first (parent before child), web units last.
  [ "${lines[0]}" = "deploy-user" ]
  [ "${lines[12]}" = "docker-engine" ]
  [ "${lines[17]}" = "ufw-docker-guard" ]
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

@test "every unit across the full chain has an assertion, an action and a description" {
  local assert_body do_body desc_body u
  assert_body="$(declare -f assert_unit)"
  do_body="$(declare -f do_unit)"
  desc_body="$(declare -f unit_describe)"
  for u in $(resolve_units web); do
    echo "missing assertion for $u" >&2
    grep -q "${u})" <<<"$assert_body"
    echo "missing action for $u" >&2
    grep -q "${u})" <<<"$do_body"
    echo "missing description for $u" >&2
    grep -q "${u})" <<<"$desc_body"
  done
}

@test "predicates stay quiet (no stdout) on a non-server" {
  # Predicates must never print to stdout (stderr noise is suppressed inside
  # them), so a dry-run preview stays clean wherever it runs.
  local u out
  for u in $(resolve_units web); do
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

@test "deploy_has_authorized_key: true only when the key file is non-empty" {
  # Shadow getent so the pure helper resolves a home we control (read-only, no
  # real user touched). The passwd 6th field is the home directory. Note the
  # var is NOT named `home`: the helper has a `local home`, which would shadow it
  # inside the stub's command substitution.
  local khome="$BATS_TEST_TMPDIR/deployhome"
  mkdir -p "$khome/.ssh"
  # shellcheck disable=SC2329  # invoked indirectly, from inside the helper.
  getent() { printf 'deploy:x:1000:1000::%s:/bin/bash\n' "$khome"; }

  # No file -> ko.
  run deploy_has_authorized_key
  [ "$status" -ne 0 ]

  # Empty file -> ko (an empty authorized_keys is as good as none).
  : >"$khome/.ssh/authorized_keys"
  run deploy_has_authorized_key
  [ "$status" -ne 0 ]

  # Non-empty file -> ok.
  echo 'ssh-ed25519 AAAA... test@box' >"$khome/.ssh/authorized_keys"
  run deploy_has_authorized_key
  [ "$status" -eq 0 ]
}

@test "deploy_has_authorized_key: false when the user has no home" {
  # shellcheck disable=SC2329  # invoked indirectly, from inside the helper.
  getent() { printf ''; }
  run deploy_has_authorized_key
  [ "$status" -ne 0 ]
}

@test "friday_wink quacks when forced and never blocks (D14)" {
  SERVER_FORCE_FRIDAY=1
  run friday_wink
  [ "$status" -eq 0 ]
  [[ "$output" == *"🦆"* ]]
}

@test "managed-file units point at existing templates" {
  local u line tpl
  for u in fail2ban unattended-upgrades journald-cap sysctl-baseline ssh-hardening docker-daemon-json; do
    line="$(unit_managed_file "$u")"
    tpl="$(printf '%s' "$line" | cut -f2)"
    [ -n "$tpl" ]
    [ -f "$tpl" ]
  done
}
