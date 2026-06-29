# shellcheck shell=bash
# Re-checkable predicates — the SECOND nature of state (§4.1, §10.1) and the
# SINGLE source of truth for "is this unit satisfied?". `setup` calls these to
# decide whether to act; `doctor` will call the very same functions to detect
# drift (§9.5) — so they must stay PURE: read-only, no mutation, no stdout, and
# they must not abort under `set -e`. System probes are wrapped with 2>/dev/null
# so a preview on a non-Ubuntu dev box (where the tools are absent) reports
# "not satisfied" quietly instead of spewing errors.
#
# Each predicate returns 0 when the desired state holds, non-zero otherwise.
# Naming: assert_<unit id with dashes turned to underscores>.

# --- Shared constants --------------------------------------------------------
DEPLOY_USER="deploy"
DEPLOY_SUDOERS="/etc/sudoers.d/90-server-setup-deploy"
SWAP_FILE="/swapfile"
SWAP_SIZE_BYTES=$((2 * 1024 * 1024 * 1024)) # 2 GiB

# --- Predicates (units 1–11; ssh-hardening/unit 12 is deferred to Prompt 3) ---

assert_deploy_user() {
  id -u "$DEPLOY_USER" >/dev/null 2>&1 || return 1
  id -nG "$DEPLOY_USER" 2>/dev/null | tr ' ' '\n' | grep -qx sudo || return 1
  [[ -f "$DEPLOY_SUDOERS" ]] || return 1
  # NOPASSWD present means the validated sudoers we install is in place. The
  # authorized_keys seed is best-effort (depends on root having a key) and is
  # intentionally NOT part of this predicate, so idempotence holds on a box
  # whose root has no key yet (e.g. a CI container) — see do_deploy_user.
  grep -q 'NOPASSWD' "$DEPLOY_SUDOERS" 2>/dev/null || return 1
}

assert_ufw_base() {
  command -v ufw >/dev/null 2>&1 || return 1
  local s
  s="$(ufw status verbose 2>/dev/null)" || return 1
  grep -q 'Status: active' <<<"$s" || return 1
  grep -q 'deny (incoming)' <<<"$s" || return 1
  ufw status 2>/dev/null | grep -qE '22/tcp[[:space:]]+ALLOW' || return 1
}

assert_fail2ban() {
  command -v fail2ban-client >/dev/null 2>&1 || return 1
  systemctl is-active --quiet fail2ban 2>/dev/null || return 1
  fail2ban-client status sshd >/dev/null 2>&1 || return 1
}

assert_unattended_upgrades() {
  dpkg -s unattended-upgrades >/dev/null 2>&1 || return 1
  grep -q '04:00' /etc/apt/apt.conf.d/52-server-setup.conf 2>/dev/null || return 1
  grep -q 'Unattended-Upgrade "1"' /etc/apt/apt.conf.d/20auto-upgrades 2>/dev/null || return 1
}

assert_timezone() {
  command -v timedatectl >/dev/null 2>&1 || return 1
  local cur
  cur="$(timedatectl show -p Timezone --value 2>/dev/null)" || return 1
  [[ "$cur" == "${DESIRED_TIMEZONE:-UTC}" ]]
}

assert_locale() {
  locale -a 2>/dev/null | grep -qiE '^en_us\.utf-?8$' || return 1
  grep -q 'LANG=en_US.UTF-8' /etc/default/locale 2>/dev/null || return 1
}

assert_timesync() {
  command -v systemctl >/dev/null 2>&1 || return 1
  systemctl is-enabled --quiet systemd-timesyncd 2>/dev/null || return 1
  systemctl is-active --quiet systemd-timesyncd 2>/dev/null && return 0
  # In a container the unit is intentionally condition-skipped (the host syncs
  # the clock), so "enabled" is as far as we can get — accept it there. On a real
  # VPS the unit must actually be active, so this branch fails and reports drift.
  systemd-detect-virt --container --quiet 2>/dev/null
}

assert_swap() {
  [[ -f "$SWAP_FILE" ]] || return 1
  [[ "$(stat -c %s "$SWAP_FILE" 2>/dev/null)" == "$SWAP_SIZE_BYTES" ]] || return 1
  swapon --show=NAME --noheadings 2>/dev/null | grep -qx "$SWAP_FILE" || return 1
  [[ "$(sysctl -n vm.swappiness 2>/dev/null)" == "10" ]] || return 1
  grep -qE "^${SWAP_FILE}[[:space:]]" /etc/fstab 2>/dev/null || return 1
}

assert_journald_cap() {
  grep -q 'SystemMaxUse' /etc/systemd/journald.conf.d/99-server-setup.conf 2>/dev/null || return 1
}

assert_github_known_hosts() {
  grep -q '^github.com ' /etc/ssh/ssh_known_hosts 2>/dev/null || return 1
}

assert_sysctl_baseline() {
  local f=/etc/sysctl.d/99-server-setup.conf
  [[ -f "$f" ]] || return 1
  # The file is always present; its CONTENT is what --paranoid toggles. A
  # paranoid box must carry the hardening lines; a default box must not.
  if [[ "${PARANOID:-0}" == 1 ]]; then
    grep -q 'rp_filter' "$f" 2>/dev/null || return 1
  else
    if grep -q 'rp_filter' "$f" 2>/dev/null; then
      return 1
    fi
  fi
}

# assert_unit <unit id> -> dispatch to the predicate above. ssh-hardening is
# declared by the profile but deliberately deferred (Prompt 3): the convergence
# loop skips it before ever reaching here.
assert_unit() {
  case "$1" in
  deploy-user) assert_deploy_user ;;
  ufw-base) assert_ufw_base ;;
  fail2ban) assert_fail2ban ;;
  unattended-upgrades) assert_unattended_upgrades ;;
  timezone) assert_timezone ;;
  locale) assert_locale ;;
  timesync) assert_timesync ;;
  swap) assert_swap ;;
  journald-cap) assert_journald_cap ;;
  github-known-hosts) assert_github_known_hosts ;;
  sysctl-baseline) assert_sysctl_baseline ;;
  *) die "Unknown unit (no assertion): $1" ;;
  esac
}
