# shellcheck shell=bash
# `server doctor` — re-evaluate the converged profile's predicates and report
# drift (§9.5). Golden rule: doctor REPORTS, it never mutates (no --fix in v1).
# It reuses lib/assert.sh as the SINGLE source of the predicates, so doctor and
# setup can never disagree. It also reports push-to-deploy's health as a bonus.
#
# Exit codes: 0 = conformant, non-zero = drift / missing. --strict also fails
# when push-to-deploy is deployed-but-degraded (for CI). A push-to-deploy that
# isn't deployed yet is reported, never a failure (it's expected at the doormat).

# converge.sh gives us assert_unit, unit_describe and resolve_units (it pulls in
# assert.sh, manifest.sh, …). We only ever CALL the read-only predicates here —
# never an action — so doctor stays non-mutating.
# shellcheck source=lib/converge.sh
source "$SERVER_ROOT/lib/converge.sh"
# shellcheck source=lib/state_read.sh
source "$SERVER_ROOT/lib/state_read.sh"

# check_line <status> <id> <detail> — print one aligned, coloured report line.
# status: pass | fail | warn | skip
_doctor_line() {
  local status="$1" id="$2" detail="$3" mark colour
  case "$status" in
  pass) mark="✓" colour="$C_GREEN" ;;
  fail) mark="✗" colour="$C_RED" ;;
  warn) mark="!" colour="$C_YELLOW" ;;
  *) mark="–" colour="$C_DIM" ;;
  esac
  printf '  %s%s%s %-22s %s\n' "$colour" "$mark" "$C_RESET" "$id" "$detail"
}

cmd_doctor() {
  local strict=0
  while [[ $# -gt 0 ]]; do
    case "$1" in
    --strict) strict=1 ;;
    -h | --help)
      cat >&2 <<EOF
Usage: server doctor [--strict]

Re-evaluate the converged profile's assertions and report drift (it never
changes anything). Exit 0 when conformant, non-zero on drift. --strict also
fails when push-to-deploy is deployed but unhealthy.
EOF
      return 0
      ;;
    *) die "Unknown option for 'doctor': $1" ;;
    esac
    shift
  done

  [[ -f "$STATE_FILE" ]] || die "no state at ${STATE_FILE} — run 'server setup' first."

  if [[ "${EUID:-$(id -u)}" -ne 0 ]]; then
    log_warn "not running as root — sshd/ufw/docker checks may read as failed. Re-run with sudo for an accurate report."
  fi

  local profile converged version confirm
  profile="$(state_profile "$STATE_FILE")"
  converged="$(state_converged_at "$STATE_FILE")"
  version="$(state_version "$STATE_FILE")"
  confirm="$(state_confirm_state "$STATE_FILE")"
  [[ -n "$profile" ]] || die "state file has no profile — corrupt ${STATE_FILE}?"

  # doctor can't read timezone/paranoid from the locked state schema (§10.1), so
  # it uses the same defaults setup does. PARANOID is cheaply derivable from the
  # deposited sysctl drop-in, so derive it for an accurate sysctl check.
  DESIRED_TIMEZONE="UTC"
  PARANOID=0
  if grep -q 'rp_filter' /etc/sysctl.d/99-server-setup.conf 2>/dev/null; then
    PARANOID=1
  fi

  printf '%sserver doctor%s — profile %s%s%s (converged %s, v%s)\n' \
    "$C_BOLD" "$C_RESET" "$C_BOLD" "$profile" "$C_RESET" "${converged:-?}" "${version:-?}"

  local warns=0
  if [[ "$confirm" == "pending-confirmation" ]]; then
    _doctor_line warn confirm-state "SSH cutover not confirmed — run 'server confirm' (the dead-man's switch may roll it back)"
    warns=$((warns + 1))
  fi

  # --- Hardening: re-evaluate every unit predicate of the converged profile ---
  printf '\n%sHardening%s\n' "$C_BOLD" "$C_RESET"
  local u fails=0 oks=0
  while IFS= read -r u; do
    [[ -z "$u" ]] && continue
    [[ "$DEFERRED_UNITS" == *" $u "* ]] && continue
    if assert_unit "$u"; then
      _doctor_line pass "$u" "$(unit_describe "$u")"
      oks=$((oks + 1))
    else
      _doctor_line fail "$u" "$(unit_describe "$u")"
      fails=$((fails + 1))
    fi
  done < <(resolve_units "$profile")

  # --- push-to-deploy health (informational; never fails the hardening) -------
  printf '\n%spush-to-deploy%s\n' "$C_BOLD" "$C_RESET"
  local ptd_degraded=0
  _doctor_ptd_health || ptd_degraded=$?

  # --- Summary + exit ---------------------------------------------------------
  local rc=0
  printf '\n'
  if [[ "$fails" -gt 0 ]]; then
    printf '%sDrift: %d/%d hardening checks failed.%s\n' "$C_RED" "$fails" "$((oks + fails))" "$C_RESET"
    rc=1
  else
    printf '%sConformant: %d/%d hardening checks pass.%s\n' "$C_GREEN" "$oks" "$oks" "$C_RESET"
  fi
  [[ "$warns" -gt 0 ]] && printf '%s%d warning(s).%s\n' "$C_YELLOW" "$warns" "$C_RESET"
  if [[ "$strict" == 1 && "$ptd_degraded" -gt 0 ]]; then
    printf '%s--strict: push-to-deploy is deployed but unhealthy.%s\n' "$C_RED" "$C_RESET"
    rc=1
  fi
  return "$rc"
}

# _doctor_ptd_health -> print the push-to-deploy section. Returns the number of
# degraded components (0 when absent or fully healthy). proxy_caddy /
# proxy_webhook are the container names from push-to-deploy's compose.
_doctor_ptd_health() {
  if ! command -v docker >/dev/null 2>&1; then
    _doctor_line skip docker "not installed — push-to-deploy cannot run here"
    return 0
  fi
  if ! docker ps >/dev/null 2>&1; then
    _doctor_line skip docker "daemon unreachable — cannot check push-to-deploy"
    return 0
  fi

  local caddy webhook
  caddy="$(docker ps -a --filter 'name=^/proxy_caddy$' --format '{{.Names}}' 2>/dev/null || true)"
  webhook="$(docker ps -a --filter 'name=^/proxy_webhook$' --format '{{.Names}}' 2>/dev/null || true)"

  if [[ -z "$caddy" && -z "$webhook" ]]; then
    _doctor_line skip not-deployed "push-to-deploy not deployed yet (expected at the doormat stage)"
    if docker network inspect web >/dev/null 2>&1; then
      _doctor_line pass web-network "docker network present — ready for push-to-deploy"
    else
      _doctor_line fail web-network "docker network missing — push-to-deploy cannot start"
    fi
    return 0
  fi

  local degraded=0
  if [[ "$(docker inspect -f '{{.State.Running}}' proxy_caddy 2>/dev/null || true)" == "true" ]]; then
    _doctor_line pass proxy_caddy "Caddy proxy container running (publishes 80/443)"
  else
    _doctor_line fail proxy_caddy "Caddy proxy container not running"
    degraded=$((degraded + 1))
  fi

  if [[ "$(docker inspect -f '{{.State.Running}}' proxy_webhook 2>/dev/null || true)" == "true" ]] &&
    docker inspect -f '{{json .NetworkSettings.Networks}}' proxy_webhook 2>/dev/null | grep -q '"web"'; then
    _doctor_line pass proxy_webhook "webhook listener running and reachable on the web network"
  else
    _doctor_line fail proxy_webhook "webhook listener down or off the web network"
    degraded=$((degraded + 1))
  fi

  if docker network inspect web >/dev/null 2>&1; then
    _doctor_line pass web-network "docker network present"
  else
    _doctor_line fail web-network "docker network missing"
    degraded=$((degraded + 1))
  fi

  return "$degraded"
}
