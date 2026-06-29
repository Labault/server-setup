# shellcheck shell=bash
# `server update` — update server-setup itself (git pull --ff-only in its own
# checkout, /opt/server-setup in production). It NEVER touches the converged box
# (§9.1): re-running `server setup` is how you re-converge after an update.

cmd_update() {
  while [[ $# -gt 0 ]]; do
    case "$1" in
    -h | --help)
      cat >&2 <<EOF
Usage: server update [--dry-run]

Update server-setup itself (git pull --ff-only in its own checkout). Never
touches the converged server. With --dry-run, fetch and report whether an update
is available without pulling.
EOF
      return 0
      ;;
    *) die "Unknown option for 'update': $1" ;;
    esac
    shift
  done

  if ! git -C "$SERVER_ROOT" rev-parse --is-inside-work-tree >/dev/null 2>&1; then
    die "server-setup is not a git checkout ($SERVER_ROOT) — cannot self-update."
  fi

  local before
  before="$(server_version)"

  if is_dry_run; then
    log_info "fetching to preview updates…"
    git -C "$SERVER_ROOT" fetch --quiet || die "git fetch failed"
    local behind=0
    behind="$(git -C "$SERVER_ROOT" rev-list --count 'HEAD..@{u}' 2>/dev/null || echo 0)"
    if [[ "$behind" -gt 0 ]]; then
      log_dry "would update server-setup: ${behind} commit(s) behind upstream (git pull --ff-only)"
    else
      log_ok "server-setup is up to date (version ${before})."
    fi
    return 0
  fi

  log_info "updating server-setup (git pull --ff-only)…"
  if git -C "$SERVER_ROOT" pull --ff-only --quiet; then
    local after
    after="$(server_version)"
    if [[ "$before" == "$after" ]]; then
      log_ok "server-setup is up to date (version ${after}). The server is untouched."
    else
      log_ok "server-setup updated: ${before} -> ${after}. The server is untouched."
    fi
  else
    die "git pull failed (local changes or diverged history?). Resolve manually in ${SERVER_ROOT}."
  fi
}
