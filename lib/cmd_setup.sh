# shellcheck shell=bash
# `server setup --profile <p>` — converge the box toward a profile's desired
# state (§4, §9.3). This is the SKELETON of the convergence loop: it resolves the
# profile, enumerates the units, and (in --dry-run) reports what it would
# converge. No unit is actually implemented yet — the per-unit predicate +
# action will land in lib/assert.sh + lib/converge.sh.

# shellcheck source=lib/manifest.sh
source "$SERVER_ROOT/lib/manifest.sh"

cmd_setup() {
  local profile="" timezone="UTC"
  local paranoid=0 skip_bin_check=0 no_overwrite=0

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
      timezone="$2"
      shift
      ;;
    --timezone=*) timezone="${1#*=}" ;;
    --paranoid) paranoid=1 ;;
    --skip-bin-check) skip_bin_check=1 ;;
    --no-overwrite) no_overwrite=1 ;;
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

  # Resolve the inheritance chain and the units it activates (parent first).
  local chain units
  chain="$(resolve_chain "$profile" | paste -sd ' ' -)"
  units="$(resolve_units "$profile")"

  log_info "profile ${C_BOLD}${profile}${C_RESET} (chain: ${chain}) — timezone ${timezone}$([[ "$paranoid" == 1 ]] && printf ', paranoid')"

  if [[ -z "$units" ]]; then
    log_warn "profile '$profile' declares no units."
    return 0
  fi

  if is_dry_run; then
    # The convergence loop's preview: list every unit the profile would converge.
    printf '%s\n' "$units" | while IFS= read -r u; do
      log_dry "would converge: ${u}"
    done
    return 0
  fi

  # --- Real run: mutating, so EUID 0 is required (§9.2, decision B) -----------
  require_root

  # Required-binary guard (per profile, §9.2). minimal needs none; later profiles
  # (docker…) do. --skip-bin-check forces past it.
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

  # The convergence engine (assert -> act on drift -> re-assert, then write
  # state.yaml) is not implemented in this skeleton. Refuse loudly rather than
  # pretend a box was hardened. no_overwrite is reserved for that engine.
  : "$no_overwrite"
  die "The convergence engine is not implemented yet — no unit was converged. Run with --dry-run to preview the plan."
}
