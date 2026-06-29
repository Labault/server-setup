# shellcheck shell=bash
# Reader for /var/lib/server-setup/state.yaml (written by lib/state.sh). Used by
# `doctor` to re-evaluate the converged profile. Parsed with awk, no yq, matching
# the exact shape we write.

# state_scalar <file> <key> -> value of a top-level scalar key (empty if absent)
state_scalar() {
  awk -v key="$2" '
    index($0, key ":") == 1 {
      v = substr($0, length(key) + 2)
      sub(/[[:space:]]*#.*/, "", v)
      gsub(/^[[:space:]]+|[[:space:]]+$/, "", v)
      print v; exit
    }
  ' "$1"
}

state_profile() { state_scalar "$1" profile; }
state_version() { state_scalar "$1" server_setup_version; }
state_commit() { state_scalar "$1" server_setup_commit; }
state_converged_at() { state_scalar "$1" converged_at; }
state_confirm_state() { state_scalar "$1" confirm_state; }
# timezone/paranoid: absent in states written before they were persisted —
# callers must fall back when these come back empty (backward compatibility).
state_timezone() { state_scalar "$1" timezone; }
state_paranoid() { state_scalar "$1" paranoid; }

# state_files <file> -> "path<TAB>sha256<TAB>tpl_sha256" per line.
# tpl_sha256 is empty when the entry didn't record one.
state_files() {
  awk '
    function clean(x) { sub(/[[:space:]]*#.*/, "", x); gsub(/^[[:space:]]+|[[:space:]]+$/, "", x); return x }
    /^[^[:space:]#]/ { inblk = ($0 ~ /^files:/) }
    inblk && /^[[:space:]]*-[[:space:]]*path:/ {
      if (have) print path "\t" sha "\t" tpl
      v = $0; sub(/.*path:[[:space:]]*/, "", v); path = clean(v); sha = ""; tpl = ""; have = 1
    }
    inblk && /^[[:space:]]*sha256:/     { v = $0; sub(/.*sha256:[[:space:]]*/, "", v);     sha = clean(v) }
    inblk && /^[[:space:]]*tpl_sha256:/ { v = $0; sub(/.*tpl_sha256:[[:space:]]*/, "", v); tpl = clean(v) }
    END { if (have) print path "\t" sha "\t" tpl }
  ' "$1"
}

# state_assertions <file> -> "id<TAB>status<TAB>checked_at" per line.
state_assertions() {
  awk '
    function clean(x) { sub(/[[:space:]]*#.*/, "", x); gsub(/^[[:space:]]+|[[:space:]]+$/, "", x); return x }
    /^[^[:space:]#]/ { inblk = ($0 ~ /^assertions:/) }
    inblk && /^[[:space:]]*-[[:space:]]*id:/ {
      if (have) print id "\t" status "\t" checked
      v = $0; sub(/.*id:[[:space:]]*/, "", v); id = clean(v); status = ""; checked = ""; have = 1
    }
    inblk && /^[[:space:]]*status:/     { v = $0; sub(/.*status:[[:space:]]*/, "", v);     status  = clean(v) }
    inblk && /^[[:space:]]*checked_at:/ { v = $0; sub(/.*checked_at:[[:space:]]*/, "", v); checked = clean(v) }
    END { if (have) print id "\t" status "\t" checked }
  ' "$1"
}
