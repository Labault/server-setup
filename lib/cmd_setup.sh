# shellcheck shell=bash
# `server setup --profile <p>` — converge the box toward a profile's desired
# state (§4, §9.3). It resolves the profile, then drives the convergence engine
# (lib/converge.sh): for each unit, assert -> act on drift -> re-assert, writing
# state.yaml at the end. The dangerous SSH cutover (unit 12) is NOT performed
# here — it is deferred to the dedicated cutover step (Prompt 3).

# shellcheck source=lib/manifest.sh
source "$SERVER_ROOT/lib/manifest.sh"
# shellcheck source=lib/converge.sh
source "$SERVER_ROOT/lib/converge.sh"

cmd_setup() {
  local profile=""
  # These become the globals the engine and predicates read.
  DESIRED_TIMEZONE="UTC"
  PARANOID=0
  NO_OVERWRITE=0
  ALLOW_KEYLESS_SSH_CUTOVER=0
  UFW_DOCKER=0
  ADMIN_KEYS_FILE=""
  DEPLOY_USER="deploy"
  local skip_bin_check=0

  while [[ $# -gt 0 ]]; do
    case "$1" in
    --profile)
      [[ $# -ge 2 ]] || die "--profile requires a value"
      profile="$2"
      shift
      ;;
    --profile=*) profile="${1#*=}" ;;
    --timezone)
      [[ $# -ge 2 ]] || die "--timezone requires a value"
      DESIRED_TIMEZONE="$2"
      shift
      ;;
    --timezone=*) DESIRED_TIMEZONE="${1#*=}" ;;
    --user)
      [[ $# -ge 2 ]] || die "--user requires a value"
      DEPLOY_USER="$2"
      shift
      ;;
    --user=*) DEPLOY_USER="${1#*=}" ;;
    --paranoid) PARANOID=1 ;;
    --ufw-docker) UFW_DOCKER=1 ;;
    --authorized-keys)
      [[ $# -ge 2 ]] || die "--authorized-keys requires a file path"
      ADMIN_KEYS_FILE="$2"
      shift
      ;;
    --authorized-keys=*) ADMIN_KEYS_FILE="${1#*=}" ;;
    --allow-keyless-ssh-cutover) ALLOW_KEYLESS_SSH_CUTOVER=1 ;;
    --skip-bin-check) skip_bin_check=1 ;;
    --no-overwrite) NO_OVERWRITE=1 ;;
    -h | --help)
      cat >&2 <<EOF
Usage: server setup --profile <minimal|docker|web> [options]

Converge the box toward the profile's desired state and write state.yaml.
--profile is mandatory and explicit — provisioning is never inferred (A1).

Options:
  --profile <p>     Required. Which profile to converge (minimal|docker|web).
  --timezone <tz>   Timezone to set (default: UTC).
  --user <name>     Name of the non-root sudoer to converge (default: deploy).
                    A bootstrap-time choice: changing it on an already-converged
                    box creates the new account and rewrites the sudoers to its
                    name; the old account is left alone (we never delete a user).
  --paranoid        Enable the sysctl network-hardening baseline (D6).
  --ufw-docker      web profile only. Opt-in (D8): install the pinned ufw-docker
                    integration so ufw actually governs the ports Docker
                    publishes (rewrites ufw's after.rules). OFF by default and
                    never auto-enabled; without it only the consultative guard
                    runs. ufw-docker rewrites ufw's tables and can surprise you —
                    strict opt-in. See docs/profiles/web.md.
                    Seed the deploy user with the admin public key(s) in <file>
                    (one per line), appended and deduped. Decouples deploy from
                    whatever /root had; this is what lets the SSH cutover pass
                    its key gate. Without it, deploy inherits root's key (§10.4).
  --allow-keyless-ssh-cutover
                    Crowbar: proceed with the key-only SSH cutover even if the
                    deploy user has no authorized_keys. Use ONLY when the key
                    arrives out-of-band — otherwise you WILL be locked out.
  --skip-bin-check  Skip the required-binary guard.
  --no-overwrite    Do not overwrite existing managed files.
  --dry-run         Show what would be converged without acting.
EOF
      return 0
      ;;
    *) die "Unknown option for 'setup': $1" ;;
    esac
    shift
  done

  # --profile is mandatory and explicit: no silent default, no `detect` (A1).
  [[ -n "$profile" ]] || die "--profile is required (minimal|docker|web). There is no default."

  # Reject a bad --user BEFORE any mutation (and even under --dry-run): a typo
  # must never half-create an account. Two gates: a name useradd would accept,
  # and a name that isn't root — the whole point of the unit is a NON-root
  # sudoer, and the SSH cutover turns root login off right after.
  valid_deploy_user "$DEPLOY_USER" ||
    die "--user: invalid username '${DEPLOY_USER}' (expected [a-z_][a-z0-9_-]*, max 32 chars)"
  if [[ "$(id -u "$DEPLOY_USER" 2>/dev/null || printf -- -1)" == 0 ]]; then
    die "--user: '${DEPLOY_USER}' is uid 0 — server-setup converges a NON-root sudoer, and the SSH cutover disables root login."
  fi

  # If admin keys were given, fail fast on a bad path BEFORE any mutation (and
  # even under --dry-run): an unreadable or empty key file is a typo, not a key.
  if [[ -n "$ADMIN_KEYS_FILE" ]]; then
    [[ -r "$ADMIN_KEYS_FILE" ]] || die "--authorized-keys: cannot read ${ADMIN_KEYS_FILE}"
    [[ -s "$ADMIN_KEYS_FILE" ]] || die "--authorized-keys: ${ADMIN_KEYS_FILE} is empty"
  fi

  friday_wink # D14: non-blocking; the duck never bars the road.

  # Resolve the inheritance chain (validates the profile too).
  local chain
  chain="$(resolve_chain "$profile" | paste -sd ' ' -)"
  log_info "profile ${C_BOLD}${profile}${C_RESET} (chain: ${chain}) — user ${DEPLOY_USER}, timezone ${DESIRED_TIMEZONE}$([[ "$PARANOID" == 1 ]] && printf ', paranoid')"

  # --- Mutating runs only: EUID 0 (§9.2, decision B) + required-binary guard ---
  if ! is_dry_run; then
    require_root
    if [[ "$skip_bin_check" == 0 ]]; then
      local bin missing=()
      while IFS= read -r bin; do
        [[ -z "$bin" ]] && continue
        command -v "$bin" >/dev/null 2>&1 || missing+=("$bin")
      done < <(resolve_requires_bin "$profile")
      if [[ ${#missing[@]} -gt 0 ]]; then
        die "Missing required binaries: ${missing[*]} (install them, or pass --skip-bin-check)."
      fi
    fi
  fi

  converge_profile "$profile"
}
