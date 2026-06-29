# shellcheck shell=bash
# `server confirm` — disarm the anti-lockout dead-man's switch after an SSH
# cutover and freeze confirm_state to `confirmed` in state.yaml (§9.4). You run
# this once you've proven you can still get in (reconnected as the deploy user
# by key). Mutating, so EUID 0 is required (§9.2).

# shellcheck source=lib/deadman.sh
source "$SERVER_ROOT/lib/deadman.sh"
# shellcheck source=lib/state.sh
source "$SERVER_ROOT/lib/state.sh"

cmd_confirm() {
  while [[ $# -gt 0 ]]; do
    case "$1" in
    -h | --help)
      cat >&2 <<EOF
Usage: server confirm

Disarm the anti-lockout dead-man's switch and mark the SSH cutover permanent
(confirm_state: confirmed). Run it after reconnecting as the deploy user.
EOF
      return 0
      ;;
    *) die "Unknown option for 'confirm': $1" ;;
    esac
    shift
  done

  require_root
  [[ -f "$STATE_FILE" ]] || die "no state file at ${STATE_FILE} — run 'server setup' first."

  if is_dry_run; then
    if deadman_is_armed; then
      log_dry "would disarm the dead-man's switch and set confirm_state: confirmed"
    else
      log_dry "would set confirm_state: confirmed (no timer is currently armed)"
    fi
    return 0
  fi

  deadman_disarm
  state_set_confirm_state confirmed
  log_ok "confirmed — anti-lockout disarmed; the SSH cutover is now permanent."
}
