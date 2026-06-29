#!/usr/bin/env bats
# Non-destructive unit tests for `server prune-backups`. They source the command
# and drive it against a throwaway BACKUP_ROOT under $BATS_TEST_TMPDIR, so they
# mutate nothing real and run anywhere (CI, dev mac). The selection logic is
# fully asserted through --dry-run (which lists exactly what WOULD be deleted and
# touches nothing); the real `rm` as root is dogfooded in validation case
# 57-prune-backups, mirroring the D15 asymmetry.
load test_helper

setup() {
  SERVER_ROOT="$(cd "$BATS_TEST_DIRNAME/.." && pwd)"
  export SERVER_ROOT
  source "$SERVER_ROOT/lib/common.sh"
  # cmd_prune_backups.sh sources backup.sh, which sets BACKUP_ROOT; override it
  # to a temp tree AFTER sourcing so the command operates there, not on /var.
  source "$SERVER_ROOT/lib/cmd_prune_backups.sh"
  BACKUP_ROOT="$BATS_TEST_TMPDIR/backups"
  mkdir -p "$BACKUP_ROOT"
  DRY_RUN=0
}

# seed <stamp>... -> create run-dirs (with a nested file, like a real backup).
seed() {
  local s
  for s in "$@"; do mkdir -p "$BACKUP_ROOT/$s/etc"; done
}

@test "duration_to_seconds parses every supported unit" {
  run duration_to_seconds 90s
  [ "$status" -eq 0 ] && [ "$output" -eq 90 ]
  run duration_to_seconds 45m
  [ "$output" -eq 2700 ]
  run duration_to_seconds 12h
  [ "$output" -eq 43200 ]
  run duration_to_seconds 30d
  [ "$output" -eq 2592000 ]
  run duration_to_seconds 2w
  [ "$output" -eq 1209600 ]
}

@test "duration_to_seconds rejects a malformed spec" {
  for bad in 30 abc 5y "" 1d2h -3d; do
    run duration_to_seconds "$bad"
    [ "$status" -ne 0 ]
  done
}

@test "prune-backups refuses without a policy" {
  run cmd_prune_backups
  [ "$status" -ne 0 ]
  [[ "$output" == *"needs a policy"* ]]
}

@test "prune-backups rejects a bad --keep / --older-than value" {
  run cmd_prune_backups --keep five
  [ "$status" -ne 0 ]
  [[ "$output" == *"Invalid --keep"* ]]
  run cmd_prune_backups --older-than 5y
  [ "$status" -ne 0 ]
  [[ "$output" == *"Invalid --older-than"* ]]
}

@test "--keep retains the newest N and dry-run deletes nothing" {
  seed 20200101T000000Z 20210101T000000Z 20220101T000000Z 20230101T000000Z
  DRY_RUN=1
  run cmd_prune_backups --keep 2
  [ "$status" -eq 0 ]
  # The two oldest are doomed; the two newest never appear in the output.
  [[ "$output" == *"20200101T000000Z"* ]]
  [[ "$output" == *"20210101T000000Z"* ]]
  [[ "$output" != *"20220101T000000Z"* ]]
  [[ "$output" != *"20230101T000000Z"* ]]
  # Dry-run is a preview: every directory still exists on disk.
  [ -d "$BACKUP_ROOT/20200101T000000Z" ]
  [ -d "$BACKUP_ROOT/20230101T000000Z" ]
}

@test "--older-than drops only stamps before the cutoff" {
  local now
  now="$(epoch_to_stamp "$(date -u +%s)")"
  seed 20200101T000000Z "$now"
  DRY_RUN=1
  run cmd_prune_backups --older-than 30d
  [ "$status" -eq 0 ]
  [[ "$output" == *"20200101T000000Z"* ]]
  [[ "$output" != *"$now"* ]]
  [ -d "$BACKUP_ROOT/20200101T000000Z" ]
}

@test "with both flags, --keep is a floor --older-than cannot cross" {
  local now
  now="$(epoch_to_stamp "$(date -u +%s)")"
  # Three ancient + one fresh. --older-than alone would doom all three ancients,
  # but --keep 2 protects the two newest OVERALL, so 20200103 survives despite
  # being old. Only the two oldest are deleted.
  seed 20200101T000000Z 20200102T000000Z 20200103T000000Z "$now"
  DRY_RUN=1
  run cmd_prune_backups --older-than 30d --keep 2
  [ "$status" -eq 0 ]
  [[ "$output" != *"$now"* ]]
  [[ "$output" != *"20200103T000000Z"* ]]
  [[ "$output" == *"20200101T000000Z"* ]]
  [[ "$output" == *"20200102T000000Z"* ]]
}

@test "non-root real purge is refused before any deletion" {
  [[ "${EUID:-$(id -u)}" -eq 0 ]] && skip "running as root: require_root would pass"
  seed 20200101T000000Z
  DRY_RUN=0
  run cmd_prune_backups --keep 0
  [ "$status" -ne 0 ]
  [[ "$output" == *"must run as root"* ]]
  # The guard fires up front: the backup is untouched.
  [ -d "$BACKUP_ROOT/20200101T000000Z" ]
}

@test "an empty backup root is a clean no-op" {
  DRY_RUN=1
  run cmd_prune_backups --keep 2
  [ "$status" -eq 0 ]
  [[ "$output" == *"nothing to prune"* ]]
}
