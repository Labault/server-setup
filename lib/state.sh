# shellcheck shell=bash
# Writes /var/lib/server-setup/state.yaml — the single trace of what `setup`
# converged (§4.2, §10.1). Written by `setup` only (never in dry-run); read later
# by `doctor`. Hand-edits are not expected. We emit YAML by hand (no yq) in a
# shape our own awk reader (state_read.sh) can read back.
#
# The state has TWO natures (§4.1 divergence #2 vs bootstrap):
#   - files:      managed system files, with on-disk + template hashes
#   - assertions: re-checkable predicates (id + status), the part you can't hash
#
# The convergence loop populates two arrays before calling the writer:
#   STATE_FILES      entries: "<abs path>\t<sha256>\t<tpl_sha256>"
#   STATE_ASSERTIONS entries: "<id>\t<status>"   (status: pass | fail)

# write_server_state <profile> <confirm_state>
# confirm_state: pending-confirmation | confirmed (anti-lockout, §9.4).
write_server_state() {
  local profile="$1" confirm_state="$2"
  local version converged_at commit
  version="$(server_version)"
  converged_at="$(date -u +%Y-%m-%dT%H:%M:%SZ)"
  # The repo commit at setup time — answers not just "which version" but "from
  # which exact commit" the box was converged (double version field, §10.1).
  commit="$(git -C "$SERVER_ROOT" rev-parse HEAD 2>/dev/null || printf 'unknown')"

  mkdir -p "$STATE_DIR"
  # Write to a temp IN THE STATE DIR so the final mv is same-filesystem (atomic):
  # no reader ever sees a half-written state file.
  local tmp
  tmp="$(mktemp "$STATE_DIR/state.yaml.XXXXXX")" || die "cannot write state in ${STATE_DIR}"
  {
    printf '# Managed by server-setup — do not edit by hand.\n'
    # Literal backticks in a comment; nothing to expand.
    # shellcheck disable=SC2016
    printf '# Written by `server setup`; read by `server doctor`.\n'
    printf 'profile: %s\n' "$profile"
    printf 'server_setup_version: %s\n' "$version"
    printf 'server_setup_commit: %s\n' "$commit"
    printf 'converged_at: %s\n' "$converged_at"
    printf 'confirm_state: %s\n' "$confirm_state"

    printf 'files:\n'
    local entry path sha tpl
    for entry in ${STATE_FILES[@]+"${STATE_FILES[@]}"}; do
      IFS=$'\t' read -r path sha tpl <<<"$entry"
      printf '  - path: %s\n' "$path"
      printf '    sha256: %s\n' "$sha"
      if [[ -n "$tpl" ]]; then
        printf '    tpl_sha256: %s\n' "$tpl"
      fi
    done

    printf 'assertions:\n'
    local id status
    for entry in ${STATE_ASSERTIONS[@]+"${STATE_ASSERTIONS[@]}"}; do
      IFS=$'\t' read -r id status <<<"$entry"
      printf '  - id: %s\n' "$id"
      printf '    status: %s\n' "$status"
      printf '    checked_at: %s\n' "$converged_at"
    done
  } >"$tmp"

  mv "$tmp" "$STATE_FILE"
}

# state_set_confirm_state <value> -> rewrite just the confirm_state line of an
# existing state file (used by `server confirm`). Atomic; leaves everything else
# untouched. Values: pending-confirmation | confirmed.
state_set_confirm_state() {
  local value="$1" tmp
  [[ -f "$STATE_FILE" ]] || die "state file not found: ${STATE_FILE}"
  tmp="$(mktemp "$STATE_DIR/state.yaml.XXXXXX")" || die "cannot write state in ${STATE_DIR}"
  sed "s/^confirm_state:.*/confirm_state: ${value}/" "$STATE_FILE" >"$tmp"
  mv "$tmp" "$STATE_FILE"
}
