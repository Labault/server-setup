# shellcheck shell=bash
# `server prune-backups` — purge old timestamped backups under BACKUP_ROOT.
#
# server-setup makes NO auto-purge (§9.6, locked decision): backups accumulate so
# you can always see a file's pre-converge state. Reclaiming that disk is the
# operator's EXPLICIT call — this command — never a silent side effect of `setup`.
# We only ever touch the timestamped run-dirs backup.sh creates; the originals
# under them are not ours to delete.

# shellcheck source=lib/backup.sh
source "$SERVER_ROOT/lib/backup.sh"

# backup.sh names each run-dir as a UTC stamp: YYYYMMDDTHHMMSSZ. That fixed-width
# format sorts lexically == chronologically, which is the whole trick behind
# --older-than: we string-compare names against a cutoff stamp, no per-platform
# `date -d` calendar parsing needed.
PRUNE_STAMP_RE='^[0-9]{8}T[0-9]{6}Z$'

# duration_to_seconds <spec> -> seconds for a spec like 30d / 12h / 45m / 90s / 2w.
# Prints nothing and returns 1 on a malformed spec.
duration_to_seconds() {
  [[ "$1" =~ ^([0-9]+)([smhdw])$ ]] || return 1
  local n="${BASH_REMATCH[1]}" unit="${BASH_REMATCH[2]}"
  case "$unit" in
  s) printf '%s\n' "$n" ;;
  m) printf '%s\n' "$((n * 60))" ;;
  h) printf '%s\n' "$((n * 3600))" ;;
  d) printf '%s\n' "$((n * 86400))" ;;
  w) printf '%s\n' "$((n * 604800))" ;;
  esac
}

# epoch_to_stamp <epoch> -> that instant as a backup stamp (UTC). GNU date wants
# `-d @epoch`, BSD/macOS date wants `-r epoch`; we try GNU first and fall back so
# the bats suite runs on a dev mac too.
epoch_to_stamp() {
  date -u -d "@$1" +%Y%m%dT%H%M%SZ 2>/dev/null || date -u -r "$1" +%Y%m%dT%H%M%SZ
}

cmd_prune_backups() {
  local older_than="" keep=""
  while [[ $# -gt 0 ]]; do
    case "$1" in
    -h | --help)
      cat >&2 <<EOF
Usage: server prune-backups [--older-than <dur>] [--keep <n>] [--dry-run]

Purge old timestamped backups under ${BACKUP_ROOT}. server-setup never auto-purges
(§9.6); this is the operator's explicit reclaim. At least one policy is required:

  --older-than <dur>   Delete backups older than <dur> (e.g. 30d, 12h, 90m, 2w).
  --keep <n>           Keep the <n> most recent backups, delete the rest.
  --dry-run            List what would be deleted, delete nothing (no root needed).

Given both, a backup is deleted only when it is BOTH older than <dur> AND outside
the <n> most recent — --keep is a floor that --older-than cannot cross.
EOF
      return 0
      ;;
    --older-than)
      [[ $# -ge 2 ]] || die "--older-than needs a duration (e.g. 30d)."
      older_than="$2"
      shift
      ;;
    --older-than=*) older_than="${1#*=}" ;;
    --keep)
      [[ $# -ge 2 ]] || die "--keep needs a count (e.g. 5)."
      keep="$2"
      shift
      ;;
    --keep=*) keep="${1#*=}" ;;
    *) die "Unknown option for 'prune-backups': $1" ;;
    esac
    shift
  done

  [[ -n "$older_than" || -n "$keep" ]] ||
    die "prune-backups needs a policy: --older-than <dur> and/or --keep <n>."

  # Validate inputs before any mutation (fail fast, like the rest of the CLI).
  local cutoff=""
  if [[ -n "$older_than" ]]; then
    local secs
    secs="$(duration_to_seconds "$older_than")" ||
      die "Invalid --older-than '$older_than' (want <int><s|m|h|d|w>, e.g. 30d)."
    cutoff="$(epoch_to_stamp "$(($(date -u +%s) - secs))")"
  fi
  if [[ -n "$keep" ]]; then
    [[ "$keep" =~ ^[0-9]+$ ]] || die "Invalid --keep '$keep' (want a non-negative integer)."
  fi

  # The real purge mutates the box; the preview doesn't. Mirror common.sh's
  # contract: require root only when we are actually going to delete.
  is_dry_run || require_root

  # Collect our run-dirs, oldest-first (the glob sorts lexically == chronologically).
  local -a backups=()
  local d name
  if [[ -d "$BACKUP_ROOT" ]]; then
    for d in "$BACKUP_ROOT"/*/; do
      [[ -d "$d" ]] || continue
      name="$(basename "$d")"
      [[ "$name" =~ $PRUNE_STAMP_RE ]] || continue
      backups+=("$name")
    done
  fi

  if [[ "${#backups[@]}" -eq 0 ]]; then
    log_ok "No backups under ${BACKUP_ROOT} — nothing to prune."
    return 0
  fi

  # keep_floor = the index below which entries are NOT among the newest <n> we
  # must always retain. older-than then drops anything before the cutoff stamp.
  local total="${#backups[@]}" keep_floor=0
  if [[ -n "$keep" ]]; then
    keep_floor=$((total - keep))
    ((keep_floor < 0)) && keep_floor=0
  fi

  local -a doomed=()
  local i
  for i in "${!backups[@]}"; do
    name="${backups[$i]}"
    # --keep floor: the newest <n> are never candidates.
    [[ -n "$keep" && "$i" -ge "$keep_floor" ]] && continue
    # --older-than: only stamps strictly before the cutoff qualify.
    [[ -n "$cutoff" ]] && ! [[ "$name" < "$cutoff" ]] && continue
    doomed+=("$name")
  done

  if [[ "${#doomed[@]}" -eq 0 ]]; then
    log_ok "Nothing to prune: all ${total} backup(s) are within the retention policy."
    return 0
  fi

  local target
  for name in "${doomed[@]}"; do
    # name passed PRUNE_STAMP_RE (digits + T/Z only) and BACKUP_ROOT is a
    # constant, so this rm can't be steered outside the backup tree.
    target="$BACKUP_ROOT/$name"
    if is_dry_run; then
      log_dry "would delete backup ${target}"
    else
      rm -rf -- "$target"
      log_info "deleted backup ${target}"
    fi
  done

  if is_dry_run; then
    log_ok "${#doomed[@]} of ${total} backup(s) would be pruned (dry-run; nothing deleted)."
  else
    log_ok "Pruned ${#doomed[@]} of ${total} backup(s) under ${BACKUP_ROOT}."
  fi
}
