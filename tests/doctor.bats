#!/usr/bin/env bats
# Non-destructive tests for `server doctor`. The full green/red behaviour is
# dogfooded on a real converged box (D15); here we check the wiring: doctor
# reuses the shared predicates (single source), renders status lines, and fails
# clearly without a state file.
load test_helper

setup() {
  SERVER_ROOT="$(cd "$BATS_TEST_DIRNAME/.." && pwd)"
  export SERVER_ROOT
  source "$SERVER_ROOT/lib/common.sh"
  source "$SERVER_ROOT/lib/cmd_doctor.sh"
  source "$SERVER_ROOT/lib/state.sh"
}

@test "doctor reuses assert.sh as the single source of predicates" {
  # It must pull in the shared predicate library, never redefine the logic.
  declare -f assert_unit >/dev/null
  declare -f assert_ssh_hardening >/dev/null
  declare -f assert_web_network >/dev/null
}

@test "_doctor_line renders pass and fail marks" {
  NO_COLOR=1
  run _doctor_line pass ufw-base "firewall up"
  [ "$status" -eq 0 ]
  [[ "$output" == *"✓"* ]]
  [[ "$output" == *"ufw-base"* ]]
  [[ "$output" == *"firewall up"* ]]

  run _doctor_line fail ufw-base "firewall down"
  [[ "$output" == *"✗"* ]]
}

@test "doctor fails clearly without a state file" {
  STATE_FILE="$BATS_TEST_TMPDIR/absent.yaml"
  run cmd_doctor
  [ "$status" -ne 0 ]
}

@test "setup persists timezone + paranoid, doctor reads them back (no false drift)" {
  STATE_DIR="$BATS_TEST_TMPDIR"
  STATE_FILE="$STATE_DIR/state.yaml"
  STATE_FILES=()
  STATE_ASSERTIONS=()
  # The globals setup poses, mirroring a `--timezone Europe/Paris --paranoid
  # --ufw-docker --user ci-deploy` run.
  DESIRED_TIMEZONE="Europe/Paris"
  PARANOID=1
  UFW_DOCKER=1
  DEPLOY_USER="ci-deploy"
  write_server_state web confirmed

  [ "$(state_timezone "$STATE_FILE")" = "Europe/Paris" ]
  [ "$(state_paranoid "$STATE_FILE")" = "1" ]
  [ "$(state_ufw_docker "$STATE_FILE")" = "1" ]
  [ "$(state_deploy_user "$STATE_FILE")" = "ci-deploy" ]

  # doctor's read+fallback: the converged name wins, so its predicates check the
  # account that actually exists instead of a phantom `deploy`.
  DEPLOY_USER="$(state_deploy_user "$STATE_FILE")"
  [[ -n "$DEPLOY_USER" ]] || DEPLOY_USER=deploy
  [ "$DEPLOY_USER" = "ci-deploy" ]

  # Reproduce doctor's read+fallback block: state wins, no UTC fallback kicks in.
  DESIRED_TIMEZONE="$(state_timezone "$STATE_FILE")"
  [[ -n "$DESIRED_TIMEZONE" ]] || DESIRED_TIMEZONE="UTC"
  [ "$DESIRED_TIMEZONE" = "Europe/Paris" ]
}

@test "doctor falls back to UTC on a pre-fix state without timezone/paranoid" {
  STATE_FILE="$BATS_TEST_TMPDIR/old-state.yaml"
  cat >"$STATE_FILE" <<'EOF'
profile: minimal
server_setup_version: 0.1.0
confirm_state: confirmed
files:
assertions:
EOF
  [ -z "$(state_timezone "$STATE_FILE")" ]
  [ -z "$(state_paranoid "$STATE_FILE")" ]
  [ -z "$(state_ufw_docker "$STATE_FILE")" ]
  [ -z "$(state_deploy_user "$STATE_FILE")" ]

  # The doctor fallback: empty timezone -> UTC, empty paranoid -> derived (0 here).
  DESIRED_TIMEZONE="$(state_timezone "$STATE_FILE")"
  [[ -n "$DESIRED_TIMEZONE" ]] || DESIRED_TIMEZONE="UTC"
  [ "$DESIRED_TIMEZONE" = "UTC" ]
  # Empty ufw_docker -> off, so the opt-in enforce unit stays skipped.
  UFW_DOCKER="$(state_ufw_docker "$STATE_FILE")"
  [[ -n "$UFW_DOCKER" ]] || UFW_DOCKER=0
  [ "$UFW_DOCKER" = "0" ]
  # Empty deploy_user -> the historical name, so a box converged before --user
  # existed still checks the account it actually has.
  DEPLOY_USER="$(state_deploy_user "$STATE_FILE")"
  [[ -n "$DEPLOY_USER" ]] || DEPLOY_USER=deploy
  [ "$DEPLOY_USER" = "deploy" ]
}
