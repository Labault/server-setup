#!/usr/bin/env bash
# shellcheck disable=SC1091
source "$(cd "$(dirname "${BASH_SOURCE[0]}")" && pwd)/../../_lib.sh"

# DoD #5, the half a container CAN prove: the anti-lockout dead-man's switch
# actually FIRES and rolls SSH back when nobody confirms. convergence.bats only
# renders the rollback script (deadman_render_rollback); case 03 confirms right
# away, so the firing is exercised nowhere. Here we arm a SHORT window, refuse to
# confirm, wait, and assert SSH reverted to its pre-cutover (permissive) state.
# The real lock-you-out reload on a live VPS stays dogfooded (D15) — this proves
# the timer + rollback mechanics, which a container can do safely.

DROPIN=/etc/ssh/sshd_config.d/99-server-setup.conf
PERMISSIVE="sshd -T 2>/dev/null | grep -qiE '^permitrootlogin (yes|prohibit-password|without-password|forced-commands-only)'"

# 1. Make SSH permissive again (drop our drop-in + reload), so the next setup
#    re-detects a restrictive mutation and RE-ARMS. The rollback snapshot is then
#    empty (no prior drop-in), so the rollback's job is to REMOVE the drop-in.
box "make SSH permissive so the cutover re-arms" "rm -f $DROPIN && systemctl reload ssh"
check "drop-in removed (pre-cutover state)" "$(box_ok "[ ! -f $DROPIN ]")"
check "sshd is permissive before the cutover" "$(box_ok "$PERMISSIVE")"

# 2. Arm with a short window and DELIBERATELY do not confirm. 6s leaves room for
#    the post-arm probes below without racing the timer; the rollback is then
#    waited for by polling, not a blind sleep.
box "converge with a 6s dead-man window" \
  "SERVER_DEADMAN_WINDOW=6s /repo/bin/server setup --profile minimal"

# 3. Just after arming: the cutover applied (drop-in back), the timer is armed,
#    and state records pending-confirmation (the rollback never rewrites state,
#    so this stays true even after the timer fires — a safe, non-racy probe).
check "drop-in installed by the cutover" "$(box_ok "[ -f $DROPIN ]")"
check "dead-man's switch is armed" "$(box_ok 'systemctl is-active --quiet server-setup-deadman.timer')"
check "state is pending-confirmation" \
  "$(box_ok "grep -q '^confirm_state: pending-confirmation' /var/lib/server-setup/state.yaml")"

# 4 & 5. Do NOT confirm. Wait past the window for the timer to fire, then prove
#    the rollback: the drop-in is gone again and sshd -T is permissive once more.
wait_box "anti-lockout fires (drop-in restored to its pre-cutover absence)" "[ ! -f $DROPIN ]" 30
check "drop-in rolled back (removed)" "$(box_ok "[ ! -f $DROPIN ]")"
check "sshd is permissive again after rollback" "$(box_ok "$PERMISSIVE")"

# 6. CLEANUP (mandatory): restore the exact state case 03 leaves — hardened and
#    confirmed, timer disarmed — so the ordered cases after us (04+) see the box
#    they expect. Re-converge re-arms; confirm freezes it.
server "re-converge minimal (cleanup)" "setup --profile minimal"
check "ssh re-hardened" "$(box_ok "[ -f $DROPIN ]")"
server "confirm (cleanup)" "confirm"
check "back to confirm_state: confirmed" \
  "$(box_ok "grep -q '^confirm_state: confirmed' /var/lib/server-setup/state.yaml")"
check "dead-man's switch disarmed" "$(box_ok '! systemctl is-active --quiet server-setup-deadman.timer')"
verdict
