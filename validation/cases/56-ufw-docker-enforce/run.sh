#!/usr/bin/env bash
# shellcheck disable=SC1091
source "$(cd "$(dirname "${BASH_SOURCE[0]}")" && pwd)/../../_lib.sh"

# D8 opt-in enforcement. Two halves:
#   A) WITHOUT --ufw-docker, nothing changes: the ufw-docker-enforce unit is
#      skipped, no marker lands in after.rules, only the consultative guard runs.
#   B) WITH --ufw-docker, the pinned ufw-docker is installed and its managed block
#      (marker `# BEGIN UFW AND DOCKER`) is posed; state records it and doctor
#      reflects it. If the box can't fetch the pinned script (no outbound network
#      on this runner), the enforcement half is skipped cleanly, not failed (D15).

# --- A) opt-out is the default: nothing changes ------------------------------
server "converge web WITHOUT --ufw-docker (baseline)" "setup --profile web"
check "consultative guard still runs" "$(out_has 'ufw-docker-guard')"
check "enforce unit skipped without the flag (opt-in, D8)" \
  "$(out_has 'skip: ufw-docker-enforce')"
check "no ufw-docker marker in after.rules" \
  "$(box_ok '! grep -q "^# BEGIN UFW AND DOCKER" /etc/ufw/after.rules')"
check "state records ufw_docker: 0" \
  "$(box_ok 'grep -qx "ufw_docker: 0" /var/lib/server-setup/state.yaml')"

# --- B) opt-in installs and enforces -----------------------------------------
# swap may fail on this host, so (like case 09) we don't assert the exit code.
server "converge web WITH --ufw-docker (opt-in enforcement)" \
  "setup --profile web --ufw-docker"

if [[ "$(box_ok 'grep -q "^# BEGIN UFW AND DOCKER" /etc/ufw/after.rules')" == 1 ]]; then
  check "ufw-docker marker installed in after.rules" 1
  check "state records ufw_docker: 1" \
    "$(box_ok 'grep -qx "ufw_docker: 1" /var/lib/server-setup/state.yaml')"
  # doctor reads ufw_docker:1 from state, so it now evaluates the enforce unit.
  box "doctor reflects the enabled enforce unit" "/repo/bin/server doctor || true"
  check "doctor lists the enforce unit (state-driven)" "$(out_has 'ufw-docker-enforce')"
  # Idempotent: re-running with the flag is a no-op (block already correct).
  server "re-run with --ufw-docker (idempotent)" "setup --profile web --ufw-docker"
  check "still exactly one ufw-docker block" \
    "$(box_ok 'grep -c "^# BEGIN UFW AND DOCKER" /etc/ufw/after.rules | grep -qx 1')"
elif [[ "$(out_has 'checksum mismatch')" == 1 ]]; then
  # A wrong pinned checksum is a real regression, not an environment issue.
  check "pinned ufw-docker checksum matches (regression if this fails)" 0
elif [[ "$(out_has 'failed to download pinned ufw-docker')" == 1 ]]; then
  printf '  [skip] no outbound network to fetch the pinned ufw-docker — enforcement not exercised in this box (D15)\n' | tee -a "$LOG"
else
  # Marker absent for an unexpected reason — surface it rather than green-wash it.
  check "ufw-docker enforcement produced a marker or a known skip reason" 0
fi

verdict
