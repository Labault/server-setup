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
