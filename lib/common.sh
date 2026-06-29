# shellcheck shell=bash
# Common library for server-setup: logging, colors, dry-run, error helpers, and
# the root guard. Sourced by bin/server, install.sh and command modules. Not
# meant to be executed directly. Mirrors bootstrap's lib/common.sh so the two
# repos read alike; the server-specific addition is require_root (§9.2).

# --- Colors (disabled if not a TTY or NO_COLOR is set) -----------------------
# Part of the library's public API, consumed by scripts that source us.
# shellcheck disable=SC2034
if [[ -t 2 && -z "${NO_COLOR:-}" ]]; then
  C_RESET=$'\033[0m'
  C_RED=$'\033[31m'
  C_GREEN=$'\033[32m'
  C_YELLOW=$'\033[33m'
  C_BLUE=$'\033[34m'
  C_DIM=$'\033[2m'
  C_BOLD=$'\033[1m'
else
  C_RESET='' C_RED='' C_GREEN='' C_YELLOW='' C_BLUE='' C_DIM='' C_BOLD=''
fi

# --- Logging (everything to stderr; stdout stays clean for data) -------------
log_info() { printf '%s\n' "${C_BLUE}•${C_RESET} $*" >&2; }
log_ok() { printf '%s\n' "${C_GREEN}✓${C_RESET} $*" >&2; }
log_warn() { printf '%s\n' "${C_YELLOW}!${C_RESET} $*" >&2; }
log_error() { printf '%s\n' "${C_RED}✗${C_RESET} $*" >&2; }
log_dry() { printf '%s\n' "${C_DIM}[dry-run]${C_RESET} $*" >&2; }

die() {
  log_error "$*"
  exit 1
}

# --- Shared constants --------------------------------------------------------
# The machine state file written by `setup` and read by `doctor` (§10.1). Unlike
# bootstrap's per-project dotfile, server-setup's state lives under /var/lib.
STATE_DIR="/var/lib/server-setup"
STATE_FILE="$STATE_DIR/state.yaml"

# --- Global flags (populated by the dispatcher) ------------------------------
DRY_RUN="${DRY_RUN:-0}"

# True when running in dry-run mode.
is_dry_run() { [[ "$DRY_RUN" == "1" ]]; }

# --- Guards ------------------------------------------------------------------
# require_root — refuse to run a mutating command unless we are root (EUID 0).
# A server convergence tool does not pretend in user mode (§9.2, decision B).
# Read-only previews (--dry-run, list, doctor) must NOT call this.
require_root() {
  if [[ "${EUID:-$(id -u)}" -ne 0 ]]; then
    die "This command must run as root (EUID 0). Re-run with sudo."
  fi
}

require_cmd() {
  command -v "$1" >/dev/null 2>&1 || die "Required command not found: $1"
}

# --- Path helpers ------------------------------------------------------------
# tildify <path> -> path with a leading $HOME collapsed to ~ (display only).
# Done with string ops, not ${p/#$HOME/~}, because the replacement '~' would
# itself be tilde-expanded back to $HOME and the collapse would be a no-op.
tildify() {
  local p="$1"
  if [[ "$p" == "$HOME"/* ]]; then
    # Intentional literal '~' for display; we do NOT want it expanded.
    # shellcheck disable=SC2088
    printf '~/%s\n' "${p#"$HOME"/}"
  else
    printf '%s\n' "$p"
  fi
}

# --- Misc helpers ------------------------------------------------------------
# server_version -> the CLI version from the repo's VERSION file.
server_version() {
  if [[ -f "$SERVER_ROOT/VERSION" ]]; then
    tr -d '[:space:]' <"$SERVER_ROOT/VERSION"
  else
    printf 'unknown'
  fi
}

# friday_wink — the D14 easter egg. On a Friday the duck gives you a look, then
# waves you through. It is NEVER a gate: provisioning a server must not hinge on
# the day of the week, so this only prints a line and the action proceeds either
# way. SERVER_FORCE_FRIDAY=1 forces it (for the demo/tests).
friday_wink() {
  if [[ "$(date +%u)" == 5 || "${SERVER_FORCE_FRIDAY:-}" == 1 ]]; then
    printf '%s🦆 vendredi : le canard te regarde de travers, mais il te laisse passer.%s\n' \
      "$C_DIM" "$C_RESET" >&2
  fi
}

# file_sha256 <file> -> hex sha256 of the file (portable: shasum or sha256sum).
file_sha256() {
  if command -v sha256sum >/dev/null 2>&1; then
    sha256sum "$1" | awk '{print $1}'
  elif command -v shasum >/dev/null 2>&1; then
    shasum -a 256 "$1" | awk '{print $1}'
  else
    printf 'sha256-unavailable'
  fi
}
