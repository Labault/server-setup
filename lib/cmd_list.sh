# shellcheck shell=bash
# `server list` — list available profiles and their resolved content.

# shellcheck source=lib/manifest.sh
source "$SERVER_ROOT/lib/manifest.sh"

cmd_list() {
  while [[ $# -gt 0 ]]; do
    case "$1" in
    -h | --help)
      cat >&2 <<EOF
Usage: server list

List the available profiles, their inheritance, required binaries, the desired-
state units they converge, and the system files they manage (inheritance
resolved).
EOF
      return 0
      ;;
    *) die "Unknown option for 'list': $1" ;;
    esac
  done

  local manifest profile parent bins units count
  local found=0
  for manifest in "$SERVER_ROOT"/profiles/*.yaml; do
    [[ -e "$manifest" ]] || continue
    found=1
    profile="$(basename "$manifest" .yaml)"
    parent="$(manifest_extends "$manifest")"

    if [[ -n "$parent" ]]; then
      printf '%s%s%s  %s(extends %s)%s\n' \
        "$C_BOLD" "$profile" "$C_RESET" "$C_DIM" "$parent" "$C_RESET"
    else
      printf '%s%s%s\n' "$C_BOLD" "$profile" "$C_RESET"
    fi

    bins="$(resolve_requires_bin "$profile" | paste -sd ' ' -)"
    printf '  %srequires_bin:%s %s\n' "$C_DIM" "$C_RESET" "${bins:--}"

    units="$(resolve_units "$profile")"
    count="$(printf '%s' "$units" | grep -c . || true)"
    printf '  %sunits (%s):%s\n' "$C_DIM" "$count" "$C_RESET"
    if [[ -n "$units" ]]; then
      printf '%s\n' "$units" | while IFS= read -r u; do
        printf '    %s\n' "$u"
      done
    fi

    count="$(resolve_files "$profile" | grep -c . || true)"
    printf '  %sfiles (%s):%s\n' "$C_DIM" "$count" "$C_RESET"
    resolve_files "$profile" | while IFS=$'\t' read -r _src dest; do
      [[ -z "$dest" ]] && continue
      printf '    %s\n' "$dest"
    done
    printf '\n'
  done

  [[ "$found" == 1 ]] || die "No profiles found in $SERVER_ROOT/profiles/"
}
