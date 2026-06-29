# shellcheck shell=bash
# Shared helpers for the validation cases. Each case/run.sh sources this. Unlike
# bootstrap (which deposits files into temp dirs), server-setup MUTATES a system,
# so the cases run their `server` commands inside a shared, disposable,
# systemd-enabled container (the "box"), started by run-all.sh. Cases run in
# numeric order and share the box's accumulating state (converge minimal, then
# docker, then web). Each case writes RESULT.txt + output.log into its folder.
set -uo pipefail

# The running validation container, created by run-all.sh; the repo is mounted
# at /repo inside it.
BOX="${SERVER_BOX:-server-setup-validation}"

# CASE_DIR = folder of the run.sh that sourced us (where log + result land).
CASE_DIR="$(cd "$(dirname "${BASH_SOURCE[1]}")" && pwd)"
LOG="$CASE_DIR/output.log"
RESULT="$CASE_DIR/RESULT.txt"
rm -f "$LOG" "$RESULT"

# box "<label>" "<cmd>" -> run a shell command inside the box AS ROOT, recording
# combined output in LAST_OUT and the exit code in LAST_RC.
box() {
  local label="$1" cmd="$2"
  { printf '\n# %s\n$ %s\n' "$label" "$cmd"; } >>"$LOG"
  LAST_OUT="$(docker exec "$BOX" bash -lc "$cmd" 2>&1)"
  LAST_RC=$?
  printf '%s\n[exit=%s]\n' "$LAST_OUT" "$LAST_RC" >>"$LOG"
}

# box_as "<user>" "<label>" "<cmd>" -> same, but as an unprivileged user.
box_as() {
  local user="$1" label="$2" cmd="$3"
  { printf '\n# %s (as %s)\n$ %s\n' "$label" "$user" "$cmd"; } >>"$LOG"
  LAST_OUT="$(docker exec -u "$user" "$BOX" bash -lc "$cmd" 2>&1)"
  LAST_RC=$?
  printf '%s\n[exit=%s]\n' "$LAST_OUT" "$LAST_RC" >>"$LOG"
}

# server "<label>" "<args>" -> run the server CLI inside the box.
server() { box "$1" "/repo/bin/server $2"; }

# --- Assertions. A case passes only if ALL of its checks pass. ---------------
_FAILS=0
check() { # check "<description>" <0-or-1 truth>
  local desc="$1" ok="$2"
  if [[ "$ok" == 1 ]]; then
    printf '  [ok ] %s\n' "$desc" | tee -a "$LOG"
  else
    printf '  [FAIL] %s\n' "$desc" | tee -a "$LOG"
    _FAILS=$((_FAILS + 1))
  fi
}

exit_is() { [[ "$LAST_RC" == "$1" ]] && echo 1 || echo 0; }
exit_nonzero() { [[ "$LAST_RC" -ne 0 ]] && echo 1 || echo 0; }
out_has() { [[ "$LAST_OUT" == *"$1"* ]] && echo 1 || echo 0; }
out_hasnt() { [[ "$LAST_OUT" != *"$1"* ]] && echo 1 || echo 0; }
# grep -c already prints "0" on no match (and exits 1); `|| true` just swallows
# that exit. Using `|| echo 0` would DOUBLE the output to "0\n0" and break the
# numeric comparisons that consume it.
out_count() { grep -c -- "$1" <<<"$LAST_OUT" 2>/dev/null || true; }
# box_ok "<cmd>" -> 1 when the command exits 0 inside the box (state probe).
box_ok() { docker exec "$BOX" bash -lc "$1" >/dev/null 2>&1 && echo 1 || echo 0; }

# wait_box "<label>" "<cmd>" [tries] -> poll a box command (as root) until it
# exits 0, up to <tries> attempts one second apart. Lets a case wait for an
# asynchronous state change (e.g. a systemd-run timer firing) without a blind
# sleep that's either flaky or needlessly slow. Logs the outcome; returns 0 as
# soon as the command succeeds, non-zero if it never does.
wait_box() {
  local label="$1" cmd="$2" tries="${3:-20}" i
  for ((i = 1; i <= tries; i++)); do
    if docker exec "$BOX" bash -lc "$cmd" >/dev/null 2>&1; then
      { printf '\n# %s — satisfied after %ds\n' "$label" "$i"; } >>"$LOG"
      return 0
    fi
    sleep 1
  done
  { printf '\n# %s — NOT satisfied after %ds\n' "$label" "$tries"; } >>"$LOG"
  return 1
}

# verdict -> write RESULT.txt (PASS/FAIL) and return accordingly.
verdict() {
  if [[ "$_FAILS" -eq 0 ]]; then
    printf 'PASS\n' >"$RESULT"
    echo "==> PASS"
  else
    printf 'FAIL (%s assertion(s))\n' "$_FAILS" >"$RESULT"
    echo "==> FAIL ($_FAILS)"
  fi
  [[ "$_FAILS" -eq 0 ]]
}
