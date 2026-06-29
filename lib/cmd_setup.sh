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
    --paranoid) PARANOID=1 ;;
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
  --paranoid        Enable the sysctl network-hardening baseline (D6).
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

  friday_wink # D14: non-blocking; the duck never bars the road.

  # Resolve the inheritance chain (validates the profile too).
  local chain
  chain="$(resolve_chain "$profile" | paste -sd ' ' -)"
  log_info "profile ${C_BOLD}${profile}${C_RESET} (chain: ${chain}) — timezone ${DESIRED_TIMEZONE}$([[ "$PARANOID" == 1 ]] && printf ', paranoid')"

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
