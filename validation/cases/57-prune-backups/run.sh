#!/usr/bin/env bash
# shellcheck disable=SC1091
source "$(cd "$(dirname "${BASH_SOURCE[0]}")" && pwd)/../../_lib.sh"

# `server prune-backups` reclaims the timestamped backups setup leaves behind.
# The converged profiles manage no files, so no real backups exist on the box —
# we seed a known set of run-dirs under BACKUP_ROOT, then prove the policies
# actually delete (the bats suite proves selection via dry-run; here we prove the
# real rm, as root, that bats can't run). Stamps: three "old" + one "fresh".
ROOT="/var/backups/server-setup"
box "seed backups" "rm -rf $ROOT && mkdir -p \
  $ROOT/20200101T000000Z/etc \
  $ROOT/20200102T000000Z/etc \
  $ROOT/20200103T000000Z/etc \
  $ROOT/\$(date -u +%Y%m%dT%H%M%SZ)/etc"

# --- dry-run reclaims nothing -----------------------------------------------
server "dry-run keep 1" "--dry-run prune-backups --keep 1"
check "dry-run exits 0" "$(exit_is 0)"
check "dry-run announces it deletes nothing" "$(out_has 'nothing deleted')"
check "dry-run kept all 4 dirs" "$(box_ok "[ \$(ls -1d $ROOT/*/ | wc -l) -eq 4 ]")"

# --- real purge honours --keep ----------------------------------------------
server "keep 1" "prune-backups --keep 1"
check "keep exits 0" "$(exit_is 0)"
check "only the newest backup survives --keep 1" "$(box_ok "[ \$(ls -1d $ROOT/*/ | wc -l) -eq 1 ]")"
check "an old backup is gone" "$(box_ok "test ! -d $ROOT/20200101T000000Z")"

# --- real purge honours --older-than ----------------------------------------
box "reseed" "rm -rf $ROOT && mkdir -p \
  $ROOT/20200101T000000Z/etc \
  $ROOT/\$(date -u +%Y%m%dT%H%M%SZ)/etc"
server "older-than 30d" "prune-backups --older-than 30d"
check "older-than exits 0" "$(exit_is 0)"
check "the ancient backup is purged" "$(box_ok "test ! -d $ROOT/20200101T000000Z")"
check "a fresh backup is kept" "$(box_ok "[ \$(ls -1d $ROOT/*/ | wc -l) -eq 1 ]")"

# --- non-root refusal (the deploy user can't purge) -------------------------
box_as "deploy" "prune as non-root" "/repo/bin/server prune-backups --keep 0"
check "non-root purge refused" "$(exit_nonzero)"
check "says it must run as root" "$(out_has 'must run as root')"

verdict
