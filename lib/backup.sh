# shellcheck shell=bash
# Timestamped backup of a system file before server-setup overwrites it (§9.6).
# Backups mirror the original tree under /var/backups/server-setup/<timestamp>/
# so you can always see what a file looked like before a converge. There is NO
# auto-purge in v1 (locked decision): backups accumulate; pruning is the
# operator's call, not ours.

BACKUP_ROOT="/var/backups/server-setup"

# backup_file <abs-path> -> if the file (or symlink) exists, copy it under
# BACKUP_ROOT preserving its absolute path, and print the backup path. No-op
# (prints nothing) when the source does not exist.
backup_file() {
  local src="$1"
  [[ -e "$src" || -L "$src" ]] || return 0
  local stamp dest dir
  stamp="$(date -u +%Y%m%dT%H%M%SZ)"
  # src is absolute, so "$BACKUP_ROOT/$stamp$src" nests it cleanly under stamp.
  dest="$BACKUP_ROOT/$stamp$src"
  dir="$(dirname "$dest")"
  mkdir -p "$dir"
  cp -a "$src" "$dest"
  printf '%s\n' "$dest"
}
