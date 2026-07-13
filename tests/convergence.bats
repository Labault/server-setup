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

@test "web resolves the full chain minimal -> docker -> web (19 units)" {
  run resolve_chain web
  [ "$status" -eq 0 ]
  [ "${lines[0]}" = "minimal" ]
  [ "${lines[1]}" = "docker" ]
  [ "${lines[2]}" = "web" ]

  run resolve_units web
  [ "$status" -eq 0 ]
  [ "${#lines[@]}" -eq 19 ]
  # minimal units first (parent before child), web units last.
  [ "${lines[0]}" = "deploy-user" ]
  [ "${lines[12]}" = "docker-engine" ]
  [ "${lines[17]}" = "ufw-docker-guard" ]
  [ "${lines[18]}" = "ufw-docker-enforce" ]
}

@test "ufw-docker-enforce is opt-in: inactive unless UFW_DOCKER=1" {
  # Off (default) -> inactive: the engine and doctor skip it, never assert it.
  UFW_DOCKER=0
  run unit_inactive ufw-docker-enforce
  [ "$status" -eq 0 ]
  # On -> active: it converges like any other unit.
  UFW_DOCKER=1
  run unit_inactive ufw-docker-enforce
  [ "$status" -ne 0 ]
  # No other unit is ever gated off by this mechanism.
  run unit_inactive ufw-docker-guard
  [ "$status" -ne 0 ]
  run unit_inactive ufw-base
  [ "$status" -ne 0 ]
}

@test "valid_profile_name accepts slugs and rejects anything path-shaped" {
  # Real profile names (bare lowercase slugs) pass.
  for name in minimal docker web a a-b-c web2; do
    run valid_profile_name "$name"
    [ "$status" -eq 0 ] || {
      echo "should accept: $name"
      false
    }
  done
  # Anything that could escape profiles/ or isn't a slug is rejected on format,
  # before manifest_path ever builds a path with it.
  for name in "../../etc/passwd" "a/b" "./x" ".." "" "Web" "_x" "-x" "a.b" "a b"; do
    run valid_profile_name "$name"
    [ "$status" -ne 0 ] || {
      echo "should reject: $name"
      false
    }
  done
}

@test "valid_deploy_user accepts real usernames and rejects what useradd would refuse" {
  for name in deploy ubuntu ci-deploy _svc d admin_2; do
    run valid_deploy_user "$name"
    [ "$status" -eq 0 ] || {
      echo "should accept: $name"
      false
    }
  done
  # Uppercase, dots, spaces, a leading digit or dash, a path, a 33-char name:
  # all rejected on format, before --user can half-create an account.
  for name in "" "Deploy" "a.b" "a b" "1deploy" "-deploy" "de/ploy" "root:x" "$(printf 'd%.0s' {1..33})"; do
    run valid_deploy_user "$name"
    [ "$status" -ne 0 ] || {
      echo "should reject: $name"
      false
    }
  done
}

@test "the deploy user's name is a default, not a constant (--user overrides it)" {
  # Every deploy-user predicate/action keys off DEPLOY_USER, so overriding the
  # variable is all `--user` has to do — nothing may hardcode 'deploy'.
  DEPLOY_USER=ci-deploy
  run unit_describe deploy-user
  [[ "$output" == *"ci-deploy"* ]]
  run unit_describe deploy-docker-group
  [[ "$output" == *"ci-deploy"* ]]
  # The sudoers file is the unit's managed file, so its PATH stays fixed.
  run unit_managed_file deploy-user
  [[ "$output" == *"/etc/sudoers.d/90-server-setup-deploy"* ]]
}

@test "resolve_chain rejects a path-traversal profile before touching the filesystem" {
  run resolve_chain "../../etc/passwd"
  [ "$status" -ne 0 ]
  [[ "$output" == *"Invalid profile name"* ]]
  [[ "$output" != *"Unknown profile"* ]]
}

@test "ssh-hardening is implemented, not deferred" {
  [[ "$DEFERRED_UNITS" != *" ssh-hardening "* ]]
  declare -f do_unit | grep -q 'ssh-hardening)'
  declare -f assert_unit | grep -q 'ssh-hardening)'
}

@test "do_timesync purges rivals, installs the package and unmasks before enabling" {
  local body
  body="$(declare -f do_timesync)"
  grep -q 'ensure_pkg systemd-timesyncd' <<<"$body"
  grep -q 'unmask systemd-timesyncd' <<<"$body"
  grep -qE 'for rival in .*chrony' <<<"$body"
  grep -q 'apt-get purge' <<<"$body"
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

@test "merge_authorized_keys appends, dedups whole lines and strips blanks" {
  local existing="$BATS_TEST_TMPDIR/existing" src="$BATS_TEST_TMPDIR/admins.pub"
  printf 'ssh-ed25519 AAAAroot root@box\n' >"$existing"
  # The admin file repeats root's key (must dedup), adds a new one, and has a
  # blank line (must be stripped).
  printf 'ssh-ed25519 AAAAroot root@box\n\nssh-ed25519 AAAAadmin admin@laptop\n' >"$src"

  run merge_authorized_keys "$existing" "$src"
  [ "$status" -eq 0 ]
  # Existing key first, the new one appended, each exactly once, no blank line.
  [ "${#lines[@]}" -eq 2 ]
  [ "${lines[0]}" = "ssh-ed25519 AAAAroot root@box" ]
  [ "${lines[1]}" = "ssh-ed25519 AAAAadmin admin@laptop" ]
}

@test "merge_authorized_keys works when deploy has no keys yet (src only)" {
  local src="$BATS_TEST_TMPDIR/admins.pub"
  printf 'ssh-ed25519 AAAAadmin admin@laptop\nssh-ed25519 AAAAadmin admin@laptop\n' >"$src"
  # A missing/empty existing file must not error and must still dedup the source.
  run merge_authorized_keys "$BATS_TEST_TMPDIR/nope" "$src"
  [ "$status" -eq 0 ]
  [ "${#lines[@]}" -eq 1 ]
  [ "${lines[0]}" = "ssh-ed25519 AAAAadmin admin@laptop" ]
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
