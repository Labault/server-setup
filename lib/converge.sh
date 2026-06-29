# shellcheck shell=bash
# The convergence engine (§9.3): for each unit of the resolved profile, evaluate
# its assertion -> if satisfied, skip (idempotence) -> otherwise act -> re-assert
# to confirm. Managed files go through backup_file before being overwritten and
# are hashed into state.yaml; every unit records its assertion (id + status).
#
# This file also holds the per-unit ACTIONS (do_*). Predicates live in assert.sh
# (the shared source of truth); a new unit type = a new predicate there + a new
# action here (CDC §7).

# shellcheck source=lib/assert.sh
source "$SERVER_ROOT/lib/assert.sh"
# shellcheck source=lib/backup.sh
source "$SERVER_ROOT/lib/backup.sh"
# shellcheck source=lib/state.sh
source "$SERVER_ROOT/lib/state.sh"
# shellcheck source=lib/deadman.sh
source "$SERVER_ROOT/lib/deadman.sh"
# shellcheck source=lib/manifest.sh
source "$SERVER_ROOT/lib/manifest.sh"

# Units a profile declares but the engine deliberately skips. Empty now that the
# SSH cutover (unit 12) is implemented behind its anti-lockout sequence; kept as
# a mechanism for any future not-yet-built unit.
DEFERRED_UNITS=""

# ---------------------------------------------------------------------------
# File / package helpers
# ---------------------------------------------------------------------------

# Run apt-get update at most once per converge, lazily (only when a package is
# actually missing).
APT_UPDATED=0
ensure_pkg() {
  local pkg="$1"
  dpkg -s "$pkg" >/dev/null 2>&1 && return 0
  if [[ "$APT_UPDATED" == 0 ]]; then
    log_info "apt-get update…"
    DEBIAN_FRONTEND=noninteractive apt-get update -qq || die "apt-get update failed"
    APT_UPDATED=1
  fi
  log_info "installing ${pkg}…"
  DEBIAN_FRONTEND=noninteractive apt-get install -y -qq "$pkg" || die "failed to install ${pkg}"
}

# install_managed_file <tpl-src> <dest> [mode] -> deposit a template at an
# absolute dest, backing up any DIFFERING existing file first. Idempotent: an
# identical file is left untouched (no backup, no rewrite).
install_managed_file() {
  local src="$1" dest="$2" mode="${3:-0644}" bak
  if [[ -f "$dest" ]] && cmp -s "$src" "$dest"; then
    return 0
  fi
  if [[ "${NO_OVERWRITE:-0}" == 1 && -e "$dest" ]]; then
    log_warn "skip ${dest} (--no-overwrite)"
    return 0
  fi
  bak="$(backup_file "$dest")"
  [[ -n "$bak" ]] && log_info "backed up $(tildify "$dest") -> ${bak}"
  mkdir -p "$(dirname "$dest")"
  install -m "$mode" "$src" "$dest"
}

# write_managed_file <dest> <mode> -> deposit generated content (read from
# stdin) at dest, with the same backup + idempotence semantics.
write_managed_file() {
  local dest="$1" mode="${2:-0644}" tmp bak
  tmp="$(mktemp)"
  cat >"$tmp"
  if [[ -f "$dest" ]] && cmp -s "$tmp" "$dest"; then
    rm -f "$tmp"
    return 0
  fi
  if [[ "${NO_OVERWRITE:-0}" == 1 && -e "$dest" ]]; then
    rm -f "$tmp"
    log_warn "skip ${dest} (--no-overwrite)"
    return 0
  fi
  bak="$(backup_file "$dest")"
  [[ -n "$bak" ]] && log_info "backed up $(tildify "$dest") -> ${bak}"
  mkdir -p "$(dirname "$dest")"
  install -m "$mode" "$tmp" "$dest"
  rm -f "$tmp"
}

# sysctl_template -> path of the sysctl drop-in to deposit (empty baseline by
# default, hardening variant under --paranoid). Used by both the action and the
# state writer so the recorded tpl_sha256 matches what was deposited.
sysctl_template() {
  if [[ "${PARANOID:-0}" == 1 ]]; then
    printf '%s\n' "$SERVER_ROOT/templates/sysctl/99-server-setup.paranoid.conf"
  else
    printf '%s\n' "$SERVER_ROOT/templates/sysctl/99-server-setup.conf"
  fi
}

# unit_managed_file <unit id> -> "dest<TAB>tpl-src" for units that own a managed
# file (recorded in state.yaml's files[]), empty for assertion-only units.
unit_managed_file() {
  case "$1" in
  deploy-user) printf '%s\t%s\n' "$DEPLOY_SUDOERS" "" ;;
  fail2ban) printf '%s\t%s\n' "/etc/fail2ban/jail.local" "$SERVER_ROOT/templates/fail2ban/jail.local" ;;
  unattended-upgrades) printf '%s\t%s\n' "/etc/apt/apt.conf.d/52-server-setup.conf" "$SERVER_ROOT/templates/unattended/52-server-setup.conf" ;;
  journald-cap) printf '%s\t%s\n' "/etc/systemd/journald.conf.d/99-server-setup.conf" "$SERVER_ROOT/templates/journald/99-server-setup.conf" ;;
  sysctl-baseline) printf '%s\t%s\n' "/etc/sysctl.d/99-server-setup.conf" "$(sysctl_template)" ;;
  ssh-hardening) printf '%s\t%s\n' "/etc/ssh/sshd_config.d/99-server-setup.conf" "$SERVER_ROOT/templates/ssh/99-server-setup.conf" ;;
  docker-daemon-json) printf '%s\t%s\n' "/etc/docker/daemon.json" "$SERVER_ROOT/templates/docker/daemon.json" ;;
  *) : ;;
  esac
}

# unit_describe <unit id> -> one-line human description, for the --dry-run plan.
unit_describe() {
  case "$1" in
  deploy-user) printf 'create non-root sudoer %s (NOPASSWD, visudo-validated) + seed its SSH key' "$DEPLOY_USER" ;;
  ufw-base) printf 'ufw deny-incoming / allow-out, allow 22/tcp, then enable' ;;
  fail2ban) printf 'install fail2ban + sshd jail' ;;
  unattended-upgrades) printf 'auto security upgrades + auto-reboot 04:00' ;;
  timezone) printf 'set timezone to %s' "${DESIRED_TIMEZONE:-UTC}" ;;
  locale) printf 'generate + set en_US.UTF-8' ;;
  timesync) printf 'enable systemd-timesyncd' ;;
  swap) printf 'create %s (2G) + vm.swappiness=10' "$SWAP_FILE" ;;
  journald-cap) printf 'cap journald SystemMaxUse' ;;
  github-known-hosts) printf 'pin github.com host key into ssh_known_hosts' ;;
  sysctl-baseline)
    if [[ "${PARANOID:-0}" == 1 ]]; then
      printf 'apply paranoid sysctl hardening'
    else
      printf 'empty sysctl baseline (pass --paranoid to harden)'
    fi
    ;;
  ssh-hardening) printf 'disable root + password SSH login (anti-lockout cutover)' ;;
  docker-engine) printf 'install Docker Engine + compose plugin (official apt repo)' ;;
  docker-daemon-json) printf 'write daemon.json with log rotation (the 16 GB lesson)' ;;
  deploy-docker-group) printf 'add %s to the docker group' "$DEPLOY_USER" ;;
  ufw-web) printf 'ufw allow 80/tcp + 443/tcp (firewall grows with the profile)' ;;
  web-network) printf 'create the docker web network (idempotent, owned by server-setup)' ;;
  ufw-docker-guard) printf 'assert no non-Caddy container publishes 80/443 (ufw×Docker footgun)' ;;
  *) printf '?' ;;
  esac
}

# ---------------------------------------------------------------------------
# Per-unit actions (do_*). Each returns 0 on success, non-zero on failure.
# ---------------------------------------------------------------------------

do_deploy_user() {
  local user="$DEPLOY_USER"
  if ! id -u "$user" >/dev/null 2>&1; then
    useradd -m -s /bin/bash "$user" || return 1
  fi
  usermod -aG sudo "$user" || return 1

  # sudoers NOPASSWD, validated by `visudo -cf` BEFORE install (§10.4): never
  # leave a broken sudoers that could lock you out of privilege escalation.
  local tmp
  tmp="$(mktemp)"
  printf '%s ALL=(ALL) NOPASSWD:ALL\n' "$user" >"$tmp"
  if ! visudo -cf "$tmp" >/dev/null 2>&1; then
    rm -f "$tmp"
    die "generated sudoers for ${user} failed visudo validation — refusing to install"
  fi
  if [[ ! -f "$DEPLOY_SUDOERS" ]] || ! cmp -s "$tmp" "$DEPLOY_SUDOERS"; then
    backup_file "$DEPLOY_SUDOERS" >/dev/null
    install -m 0440 "$tmp" "$DEPLOY_SUDOERS"
  fi
  rm -f "$tmp"

  seed_deploy_authorized_keys "$user"
}

# Seed the deploy user's authorized_keys so you can reconnect as deploy after the
# (later) SSH cutover. Two sources, in priority order:
#   1. --authorized-keys (ADMIN_KEYS_FILE): explicit admin key(s), appended and
#      deduped. This decouples deploy from "whatever root happened to have" and
#      is what lets the cutover pass its key gate without root owning a key.
#   2. Fallback (no --authorized-keys): copy root's incoming key, best-effort. If
#      root has none either, warn loudly rather than fail — the structural part of
#      the unit still holds.
seed_deploy_authorized_keys() {
  local user="$1" home ssh_dir ak root_ak="/root/.ssh/authorized_keys"
  home="$(getent passwd "$user" | cut -d: -f6)"
  ssh_dir="$home/.ssh"
  ak="$ssh_dir/authorized_keys"
  install -d -m 0700 -o "$user" -g "$user" "$ssh_dir"

  # Priority: explicit admin keys. Always (re-)merge so re-running stays a no-op
  # in content; dedup keeps it idempotent even if deploy already had the key.
  if [[ -n "${ADMIN_KEYS_FILE:-}" ]]; then
    seed_keys_from_file "$user" "$ak" "$ADMIN_KEYS_FILE"
    return 0
  fi

  if [[ -s "$ak" ]]; then
    return 0
  fi
  if [[ -s "$root_ak" ]]; then
    install -m 0600 -o "$user" -g "$user" "$root_ak" "$ak"
  else
    log_warn "root has no authorized_keys to seed for ${user} — add one before the SSH cutover, or pass --authorized-keys <file>"
  fi
}

# Append the public keys from <src> into <ak> (deploy's authorized_keys), then
# install the result 0600, owner deploy. Existing keys are preserved; the merge
# below dedups whole lines, so this is safe to re-run.
seed_keys_from_file() {
  local user="$1" ak="$2" src="$3" tmp
  tmp="$(mktemp)"
  merge_authorized_keys "$ak" "$src" >"$tmp"
  install -m 0600 -o "$user" -g "$user" "$tmp" "$ak"
  rm -f "$tmp"
}

# merge_authorized_keys <existing> <src> -> deduped, blank-stripped keys on
# stdout, existing keys first then the new ones. Pure (no writes, no ownership)
# so it's unit-testable; the caller handles placement, mode and ownership.
merge_authorized_keys() {
  local existing="$1" src="$2"
  if [[ -s "$existing" ]]; then
    awk 'NF && !seen[$0]++' "$existing" "$src"
  else
    awk 'NF && !seen[$0]++' "$src"
  fi
}

# deploy_has_authorized_key -> 0 if the deploy user's authorized_keys exists and
# is non-empty, 1 otherwise. Pure/read-only: it's the cutover safety gate, so it
# must never mutate. A non-empty file is the proof that key-only SSH won't lock
# us out (the seed above is best-effort, so this is checked, not assumed).
deploy_has_authorized_key() {
  local home
  home="$(getent passwd "$DEPLOY_USER" | cut -d: -f6)"
  [[ -n "$home" ]] || return 1
  [[ -s "$home/.ssh/authorized_keys" ]]
}

do_ufw_base() {
  ensure_pkg ufw
  # Order is vital (anti-lockout): set policy, ALLOW 22, and only THEN enable.
  # Never enable a deny-incoming firewall before SSH is allowed.
  ufw default deny incoming >/dev/null || return 1
  ufw default allow outgoing >/dev/null || return 1
  ufw allow 22/tcp >/dev/null || return 1
  ufw --force enable >/dev/null || return 1
}

do_fail2ban() {
  ensure_pkg fail2ban
  install_managed_file "$SERVER_ROOT/templates/fail2ban/jail.local" /etc/fail2ban/jail.local
  systemctl enable fail2ban >/dev/null 2>&1 || true
  systemctl restart fail2ban || return 1
  # fail2ban-server opens its socket a beat after the unit reports started; wait
  # for it to answer so the immediate re-assert doesn't race a cold server.
  local i
  for ((i = 0; i < 30; i++)); do
    fail2ban-client ping >/dev/null 2>&1 && break
    sleep 0.5
  done
}

do_unattended_upgrades() {
  ensure_pkg unattended-upgrades
  install_managed_file "$SERVER_ROOT/templates/unattended/52-server-setup.conf" \
    /etc/apt/apt.conf.d/52-server-setup.conf
  write_managed_file /etc/apt/apt.conf.d/20auto-upgrades 0644 <<'EOF'
// Managed by server-setup.
APT::Periodic::Update-Package-Lists "1";
APT::Periodic::Unattended-Upgrade "1";
EOF
  systemctl enable unattended-upgrades >/dev/null 2>&1 || true
}

do_timezone() {
  local tz="${DESIRED_TIMEZONE:-UTC}"
  [[ -f "/usr/share/zoneinfo/$tz" ]] || die "unknown timezone: ${tz}"
  timedatectl set-timezone "$tz" || return 1
}

do_locale() {
  ensure_pkg locales
  if ! locale -a 2>/dev/null | grep -qiE '^en_us\.utf-?8$'; then
    sed -i 's/^# *en_US.UTF-8 UTF-8/en_US.UTF-8 UTF-8/' /etc/locale.gen 2>/dev/null || true
    grep -q '^en_US.UTF-8 UTF-8' /etc/locale.gen 2>/dev/null ||
      printf 'en_US.UTF-8 UTF-8\n' >>/etc/locale.gen
    locale-gen >/dev/null || return 1
  fi
  update-locale LANG=en_US.UTF-8 || return 1
}

do_timesync() {
  timedatectl set-ntp true >/dev/null 2>&1 || true
  systemctl enable systemd-timesyncd >/dev/null 2>&1 || true
  # Don't hard-fail on start: inside a container the unit is condition-skipped by
  # design (the host keeps the clock). The re-assert decides what counts.
  systemctl start systemd-timesyncd >/dev/null 2>&1 || true
}

do_swap() {
  # Idempotent: only (re)create the swapfile when it's missing or the wrong
  # size — never rewrite a healthy 2G swap for the fun of it (§4.3).
  if ! swap_file_ready; then
    swapoff "$SWAP_FILE" 2>/dev/null || true
    rm -f "$SWAP_FILE"
    if ! fallocate -l "$SWAP_SIZE_BYTES" "$SWAP_FILE" 2>/dev/null; then
      dd if=/dev/zero of="$SWAP_FILE" bs=1M count=2048 status=none || return 1
    fi
    chmod 600 "$SWAP_FILE"
    mkswap "$SWAP_FILE" >/dev/null || return 1
    swapon "$SWAP_FILE" || return 1
  fi
  grep -qE "^${SWAP_FILE}[[:space:]]" /etc/fstab 2>/dev/null ||
    printf '%s none swap sw 0 0\n' "$SWAP_FILE" >>/etc/fstab
  write_managed_file /etc/sysctl.d/99-server-setup-swappiness.conf 0644 <<'EOF'
# Managed by server-setup (swap unit).
vm.swappiness=10
EOF
  sysctl -q -w vm.swappiness=10 || return 1
}

# swap_file_ready -> true when /swapfile exists at the right size and is active.
swap_file_ready() {
  [[ -f "$SWAP_FILE" ]] || return 1
  [[ "$(stat -c %s "$SWAP_FILE" 2>/dev/null)" == "$SWAP_SIZE_BYTES" ]] || return 1
  swapon --show=NAME --noheadings 2>/dev/null | grep -qx "$SWAP_FILE" || return 1
}

do_journald_cap() {
  install_managed_file "$SERVER_ROOT/templates/journald/99-server-setup.conf" \
    /etc/systemd/journald.conf.d/99-server-setup.conf
  systemctl restart systemd-journald 2>/dev/null || true
}

do_github_known_hosts() {
  local kh=/etc/ssh/ssh_known_hosts src="$SERVER_ROOT/templates/ssh/github_known_hosts"
  mkdir -p /etc/ssh
  if ! grep -q '^github.com ' "$kh" 2>/dev/null; then
    backup_file "$kh" >/dev/null
    grep -vE '^[[:space:]]*(#|$)' "$src" >>"$kh"
  fi
}

do_sysctl_baseline() {
  install_managed_file "$(sysctl_template)" /etc/sysctl.d/99-server-setup.conf
  if [[ "${PARANOID:-0}" == 1 ]]; then
    sysctl --system >/dev/null 2>&1 || true
  fi
}

# --- SSH cutover (unit 12) — the dangerous gesture, §9.4 -------------------

# sshd_live_permissive -> true when the CURRENTLY running sshd still allows root
# login or password auth, i.e. this cutover is genuinely restrictive and must be
# protected by the dead-man's switch. If we can't read the live config, assume
# permissive (arm, to be safe). Drives the conditional-arming rule (§11.2).
sshd_live_permissive() {
  local cfg
  cfg="$(sshd -T 2>/dev/null)" || return 0
  grep -qi '^passwordauthentication yes' <<<"$cfg" && return 0
  grep -qiE '^permitrootlogin (yes|prohibit-password|without-password|forced-commands-only)' <<<"$cfg" && return 0
  return 1
}

# ssh_restore_dropin <dropin> <prev-snapshot-or-empty> -> put the drop-in back to
# its pre-cutover state (restore the snapshot, or remove it if there was none).
ssh_restore_dropin() {
  local dropin="$1" prev="$2"
  if [[ -n "$prev" && -f "$prev" ]]; then
    cp -a -- "$prev" "$dropin"
  else
    rm -f -- "$dropin"
  fi
}

# ssh_self_test <dropin> -> stand up a throwaway sshd on the loopback, bound to a
# high port, that Includes the candidate drop-in, and prove a KEY login passes
# under it (pubkey accepted, password/root off don't block a key). Uses an
# ephemeral keypair and host key; touches neither the live sshd nor real keys.
# Returns 0 if the key login succeeds, non-zero otherwise.
ssh_self_test() {
  local dropin="$1"
  local sshd_bin tmp rc=1 pid i port="" p
  sshd_bin="$(command -v sshd || printf '/usr/sbin/sshd')"
  tmp="$(mktemp -d)"
  # sshd, after privsep, reads AuthorizedKeysFile AS the target user, so the temp
  # dir and key file must be traversable/readable by deploy (mktemp -d is 0700).
  chmod 0755 "$tmp"

  # Pick a free loopback port rather than a hardcoded one, so we never connect to
  # something else already listening (which would give a false self-test result).
  for p in 53122 53123 53124 53125 53126 53127; do
    if ! ss -ltn 2>/dev/null | grep -q ":${p} "; then
      port="$p"
      break
    fi
  done
  [[ -n "$port" ]] || {
    rm -rf "$tmp"
    return 1
  }

  ssh-keygen -q -t ed25519 -f "$tmp/hostkey" -N '' || {
    rm -rf "$tmp"
    return 1
  }
  ssh-keygen -q -t ed25519 -f "$tmp/userkey" -N '' || {
    rm -rf "$tmp"
    return 1
  }
  cp "$tmp/userkey.pub" "$tmp/authorized_keys"
  chmod 0644 "$tmp/authorized_keys"

  # UsePAM yes mirrors the real Ubuntu sshd: the deploy user has a locked
  # password (no password login), which PAM still lets log in by key — exactly
  # the production setup. With UsePAM no, sshd would reject the locked account
  # and the self-test would be a false negative.
  cat >"$tmp/sshd_config" <<EOF
Port $port
ListenAddress 127.0.0.1
HostKey $tmp/hostkey
PidFile $tmp/sshd.pid
AuthorizedKeysFile $tmp/authorized_keys
UsePAM yes
StrictModes no
Include $dropin
EOF

  if ! "$sshd_bin" -t -f "$tmp/sshd_config" 2>/dev/null; then
    rm -rf "$tmp"
    return 1
  fi

  "$sshd_bin" -f "$tmp/sshd_config" -D -E "$tmp/sshd.log" &
  pid=$!
  for ((i = 0; i < 40; i++)); do
    if ss -ltn 2>/dev/null | grep -q "127.0.0.1:$port"; then break; fi
    sleep 0.25
  done

  if ssh -i "$tmp/userkey" -p "$port" \
    -o StrictHostKeyChecking=no -o UserKnownHostsFile=/dev/null \
    -o BatchMode=yes -o ConnectTimeout=5 \
    "${DEPLOY_USER}@127.0.0.1" true 2>/dev/null; then
    rc=0
  fi

  kill "$pid" 2>/dev/null || true
  wait "$pid" 2>/dev/null || true
  rm -rf "$tmp"
  return "$rc"
}

# do_ssh_hardening -> the §9.4 cutover, in order:
#   1. write the candidate drop-in, then `sshd -t` on the MERGED config; abort
#      before any reload if it's invalid.
#   2. loopback key self-test under the new config; abort before reload on fail.
#   3. arm the dead-man's switch (only if the change is really restrictive) and
#      flag state as pending-confirmation.
#   4. `systemctl reload ssh` — never restart.
#   5. print the reconnect/confirm instruction (incl. the reboot-edge warning).
do_ssh_hardening() {
  local tpl="$SERVER_ROOT/templates/ssh/99-server-setup.conf"
  local dropin=/etc/ssh/sshd_config.d/99-server-setup.conf

  # Fail-fast safety gate (§9.4): the self-test validates the CONFIG with an
  # EPHEMERAL key, so a passing self-test does NOT prove you can reconnect as
  # deploy. If deploy has no real key, key-only SSH would lock you out and only
  # the dead-man's switch would save you. Refuse BEFORE touching the drop-in —
  # we install nothing and arm nothing. Override only if the key arrives
  # out-of-band (you own the lockout risk then).
  if [[ "${ALLOW_KEYLESS_SSH_CUTOVER:-0}" != 1 ]] && ! deploy_has_authorized_key; then
    die "refusing the SSH cutover: ${DEPLOY_USER} has no authorized_keys — key-only SSH would lock you out.
  Fix it first: seed a key for ${DEPLOY_USER} — pass --authorized-keys <file> with your admin public key(s),
  or add one to /root/.ssh/authorized_keys — then re-run setup. If the key arrives out-of-band and you accept
  the lockout risk, re-run with --allow-keyless-ssh-cutover."
  fi

  ensure_pkg openssh-server
  command -v ssh >/dev/null 2>&1 || ensure_pkg openssh-client
  # Privilege-separation dir: `sshd -t` (and the self-test's throwaway sshd)
  # refuse to run without it. It normally exists because sshd is running, but
  # create it defensively so validation works even if /run was just cleaned.
  [[ -d /run/sshd ]] || mkdir -p /run/sshd

  # Arming gate (§11.2): only arm when we're actually disabling something the
  # live config still permits. Computed BEFORE we touch the drop-in.
  local arm=0
  sshd_live_permissive && arm=1

  # Snapshot the previous drop-in for rollback (empty => it didn't exist).
  local prev=""
  if [[ -f "$dropin" ]]; then
    mkdir -p "$STATE_DIR"
    prev="$STATE_DIR/ssh-rollback.prev"
    cp -a -- "$dropin" "$prev"
  fi

  # Step 1: candidate drop-in + validate the merged config.
  install_managed_file "$tpl" "$dropin" 0644
  if ! sshd -t 2>/dev/null; then
    log_error "sshd -t failed on the merged config — aborting BEFORE any reload"
    ssh_restore_dropin "$dropin" "$prev"
    return 1
  fi

  # Step 2: loopback key self-test.
  if ! ssh_self_test "$dropin"; then
    log_error "loopback key self-test failed under the new SSH config — aborting before reload"
    ssh_restore_dropin "$dropin" "$prev"
    return 1
  fi

  # Step 3: arm (conditional) + flag pending-confirmation.
  local window="${SERVER_DEADMAN_WINDOW:-$DEADMAN_WINDOW_DEFAULT}"
  if [[ "$arm" == 1 ]]; then
    deadman_arm "$dropin" "$prev" "$window"
    PENDING_CONFIRMATION=1
  else
    log_info "SSH already non-permissive — applying the drop-in without arming the dead-man's switch"
  fi

  # Step 4: reload, NEVER restart (a restart kills established sessions, §9.4/D9).
  systemctl reload ssh 2>/dev/null || systemctl reload sshd 2>/dev/null ||
    die "failed to reload ssh"

  # Step 5: the instruction.
  if [[ "$arm" == 1 ]]; then
    log_warn "SSH hardened: root login OFF, password auth OFF. Anti-lockout armed for ${window}."
    log_warn "Reconnect as '${DEPLOY_USER}' by key and run 'server confirm' within ${window}, or SSH ROLLS BACK automatically."
    log_warn "A reboot during the window loses the timer — CONFIRM BEFORE ANY REBOOT."
  fi
}

# --- docker profile actions (units 13–15, CDC §6.2) ------------------------

do_docker_engine() {
  ensure_pkg ca-certificates
  ensure_pkg curl
  # Official Docker apt repo (the documented, supported install path).
  install -m 0755 -d /etc/apt/keyrings
  if [[ ! -f /etc/apt/keyrings/docker.asc ]]; then
    curl -fsSL https://download.docker.com/linux/ubuntu/gpg -o /etc/apt/keyrings/docker.asc ||
      return 1
    chmod a+r /etc/apt/keyrings/docker.asc
  fi
  local arch codename list want
  arch="$(dpkg --print-architecture)"
  codename="$(. /etc/os-release && printf '%s' "$VERSION_CODENAME")"
  list=/etc/apt/sources.list.d/docker.list
  want="deb [arch=${arch} signed-by=/etc/apt/keyrings/docker.asc] https://download.docker.com/linux/ubuntu ${codename} stable"
  if [[ ! -f "$list" ]] || ! grep -qF "$want" "$list"; then
    printf '%s\n' "$want" >"$list"
    DEBIAN_FRONTEND=noninteractive apt-get update -qq || die "apt-get update failed (docker repo)"
  fi
  if ! dpkg -s docker-ce >/dev/null 2>&1; then
    DEBIAN_FRONTEND=noninteractive apt-get install -y -qq \
      docker-ce docker-ce-cli containerd.io docker-buildx-plugin docker-compose-plugin ||
      return 1
  fi
  systemctl enable --now docker || return 1
}

do_docker_daemon_json() {
  local f=/etc/docker/daemon.json src="$SERVER_ROOT/templates/docker/daemon.json" changed=0
  if [[ ! -f "$f" ]] || ! cmp -s "$src" "$f"; then changed=1; fi
  install_managed_file "$src" "$f"
  # Apply the new daemon config only if it actually changed and docker is up.
  if [[ "$changed" == 1 ]] && systemctl is-active --quiet docker 2>/dev/null; then
    systemctl restart docker || return 1
  fi
}

do_deploy_docker_group() {
  getent group docker >/dev/null 2>&1 || return 1
  # DEPLOY_USER is a module constant (assert.sh), never reassigned — the pipeline
  # predicates that read it just confuse shellcheck's subshell heuristic.
  # shellcheck disable=SC2031
  usermod -aG docker "$DEPLOY_USER" || return 1
}

# --- web profile actions (units 16–18, CDC §6.3) ---------------------------

do_ufw_web() {
  # 80/443 are opened HERE and only here (D4). ufw is already active (ufw-base).
  ufw allow 80/tcp >/dev/null || return 1
  ufw allow 443/tcp >/dev/null || return 1
}

do_web_network() {
  # server-setup owns the `web` network (D5): create idempotently, never delete.
  docker network inspect web >/dev/null 2>&1 || docker network create web >/dev/null || return 1
}

do_ufw_docker_guard() {
  # D8: we do NOT enable ufw-docker automatically (it's opt-in). Nothing to
  # mutate at the doormat stage — the invariant holds because no app container
  # exists yet. If a stray non-Caddy container ever publishes 80/443, the
  # re-assert fails and a human fixes it; we won't kill someone's container.
  log_info "ufw×Docker (D8): only the Caddy proxy should publish 80/443; keep app services on internal networks. ufw-docker stays opt-in — see docs/profiles/web."
}

# do_unit <unit id> -> dispatch to the action above.
do_unit() {
  case "$1" in
  deploy-user) do_deploy_user ;;
  ufw-base) do_ufw_base ;;
  fail2ban) do_fail2ban ;;
  unattended-upgrades) do_unattended_upgrades ;;
  timezone) do_timezone ;;
  locale) do_locale ;;
  timesync) do_timesync ;;
  swap) do_swap ;;
  journald-cap) do_journald_cap ;;
  github-known-hosts) do_github_known_hosts ;;
  sysctl-baseline) do_sysctl_baseline ;;
  ssh-hardening) do_ssh_hardening ;;
  docker-engine) do_docker_engine ;;
  docker-daemon-json) do_docker_daemon_json ;;
  deploy-docker-group) do_deploy_docker_group ;;
  ufw-web) do_ufw_web ;;
  web-network) do_web_network ;;
  ufw-docker-guard) do_ufw_docker_guard ;;
  *) die "Unknown unit (no action): $1" ;;
  esac
}

# ---------------------------------------------------------------------------
# The loop
# ---------------------------------------------------------------------------

# record_assertion <id> <status> -> append to the STATE_ASSERTIONS array.
record_assertion() {
  STATE_ASSERTIONS+=("$1"$'\t'"$2")
}

# record_managed_file <dest> <tpl-src> -> hash the on-disk file (and its
# template, if any) and append to the STATE_FILES array.
record_managed_file() {
  local dest="$1" tpl="$2" sha tpl_sha=""
  sha="$(file_sha256 "$dest")"
  [[ -n "$tpl" && -f "$tpl" ]] && tpl_sha="$(file_sha256 "$tpl")"
  STATE_FILES+=("$dest"$'\t'"$sha"$'\t'"$tpl_sha")
}

# force_action <unit id> -> 0 when the unit's action must run even though its
# assertion already passes. The desired-state loop normally skips a satisfied
# unit; the one exception is an explicit --authorized-keys request, whose key
# seed is deliberately NOT part of assert_deploy_user (it must stay idempotent on
# a keyless box, e.g. CI). do_deploy_user is itself idempotent, so re-running it
# to (re-)seed the admin key(s) is safe.
force_action() {
  [[ "$1" == deploy-user && -n "${ADMIN_KEYS_FILE:-}" ]]
}

# converge_profile <profile> -> run the loop over the profile's resolved units.
# In --dry-run it only evaluates assertions and prints the plan (no mutation, no
# state write). On a real run it acts on drift and writes state.yaml.
converge_profile() {
  local profile="$1"
  local -a units_arr=()
  local u
  while IFS= read -r u; do
    [[ -n "$u" ]] && units_arr+=("$u")
  done < <(resolve_units "$profile")

  STATE_FILES=()
  STATE_ASSERTIONS=()
  # Set to 1 by the SSH cutover when it arms the dead-man's switch; it makes the
  # state record confirm_state: pending-confirmation until `server confirm`.
  PENDING_CONFIRMATION=0
  local status converged=0 skipped=0 failed=0 deferred=0

  for u in "${units_arr[@]}"; do
    # Skip deferred units (ssh-hardening) entirely — declared, but not ours yet.
    if [[ "$DEFERRED_UNITS" == *" $u "* ]]; then
      log_warn "skip: ${u} — deferred to the SSH cutover (Prompt 3)"
      deferred=$((deferred + 1))
      continue
    fi

    if assert_unit "$u" && ! force_action "$u"; then
      log_ok "ok: ${u}$(is_dry_run && printf ' (already satisfied)')"
      status=pass
      skipped=$((skipped + 1))
    elif is_dry_run; then
      log_dry "would converge: ${u} — $(unit_describe "$u")"
      continue
    else
      log_info "converging: ${u}…"
      if do_unit "$u" && assert_unit "$u"; then
        log_ok "converged: ${u}"
        status=pass
        converged=$((converged + 1))
      else
        log_error "${u}: still not satisfied after action"
        status=fail
        failed=$((failed + 1))
      fi
    fi

    # Record state for real runs only (dry-run writes nothing).
    if ! is_dry_run; then
      record_assertion "$u" "$status"
      local mf dest tpl
      mf="$(unit_managed_file "$u")"
      if [[ -n "$mf" ]]; then
        IFS=$'\t' read -r dest tpl <<<"$mf"
        [[ -f "$dest" ]] && record_managed_file "$dest" "$tpl"
      fi
    fi
  done

  if is_dry_run; then
    log_info "dry-run: ${#units_arr[@]} unit(s) evaluated, ${deferred} deferred. Nothing changed."
    return 0
  fi

  # pending-confirmation while the dead-man's switch is armed (SSH cutover),
  # otherwise confirmed — there is nothing left to confirm.
  local confirm="confirmed"
  [[ "$PENDING_CONFIRMATION" == 1 ]] && confirm="pending-confirmation"
  write_server_state "$profile" "$confirm"
  log_ok "state written: ${STATE_FILE} (${converged} converged, ${skipped} already-ok, ${failed} failed, ${deferred} deferred)"
  [[ "$failed" -eq 0 ]]
}
