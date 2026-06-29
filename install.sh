#!/usr/bin/env bash
#
# install.sh — make the `server` CLI callable, façon mac-setup / bootstrap.
# It symlinks bin/server into a directory on PATH (the server-side equivalent of
# bootstrap's ~/.local/bin is /usr/local/bin). It installs no other binaries and
# touches no server state — that is `server setup`'s job. Idempotent. Honors
# --dry-run.
#
set -euo pipefail

if ((BASH_VERSINFO[0] < 4)); then
  printf 'install: bash 4+ required (found %s).\n' "${BASH_VERSION}" >&2
  exit 1
fi

SCRIPT_DIR="$(cd -P "$(dirname "${BASH_SOURCE[0]}")" >/dev/null 2>&1 && pwd)"
# shellcheck source=lib/common.sh
source "$SCRIPT_DIR/lib/common.sh"

DRY_RUN=0
for arg in "$@"; do
  case "$arg" in
  --dry-run) DRY_RUN=1 ;;
  -h | --help)
    cat >&2 <<EOF
Usage: ./install.sh [--dry-run]

Symlink the server CLI into a directory on PATH.

Environment:
  SERVER_BIN_DIR   Target dir for the symlink (default: /usr/local/bin)
EOF
    exit 0
    ;;
  *) die "Unknown option: $arg" ;;
  esac
done

BIN_DIR="${SERVER_BIN_DIR:-/usr/local/bin}"
SRC="$SCRIPT_DIR/bin/server"
LINK="$BIN_DIR/server"

[[ -f "$SRC" ]] || die "Cannot find the CLI at $SRC"

# Already correctly linked? Nothing to do.
if [[ -L "$LINK" && "$(readlink "$LINK")" == "$SRC" ]]; then
  log_ok "server already installed: $(tildify "$LINK") -> $(tildify "$SRC")"
else
  if is_dry_run; then
    [[ -d "$BIN_DIR" ]] || log_dry "would create $(tildify "$BIN_DIR")"
    if [[ -e "$LINK" || -L "$LINK" ]]; then
      log_dry "would back up existing $(tildify "$LINK") then replace it"
    fi
    log_dry "would symlink $(tildify "$LINK") -> $(tildify "$SRC")"
  else
    mkdir -p "$BIN_DIR"
    chmod +x "$SRC"
    # Back up anything already at the target that isn't our symlink.
    if [[ -e "$LINK" || -L "$LINK" ]]; then
      backup="${LINK}.bak.$(date +%Y%m%dT%H%M%S)"
      mv "$LINK" "$backup"
      log_warn "backed up existing $(tildify "$LINK") -> $(tildify "$backup")"
    fi
    ln -s "$SRC" "$LINK"
    log_ok "installed server: $(tildify "$LINK") -> $(tildify "$SRC")"
  fi
fi

# PATH check.
case ":$PATH:" in
*":$BIN_DIR:"*) : ;;
*)
  log_warn "$(tildify "$BIN_DIR") is not on your PATH. Add it, e.g.:"
  # The literal $PATH below is intentional — it's a snippet the user pastes.
  # shellcheck disable=SC2016
  printf '    echo '\''export PATH="%s:$PATH"'\'' >> ~/.bashrc\n' "$BIN_DIR" >&2
  ;;
esac

if ! is_dry_run; then
  log_info "Try it: server --version && server list"
fi
