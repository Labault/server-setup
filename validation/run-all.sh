#!/usr/bin/env bash
# Black-box validation harness. It boots ONE disposable, systemd-enabled
# container (the "box"), mounts the repo read-only, and runs every case against
# it in numeric order — the box's state accumulates (converge minimal -> docker
# -> web), so cases must stay ordered. Each case writes its own RESULT.txt.
#
# Why a container (D15): server-setup hardens a machine, so it can't be tested by
# depositing files in a temp dir like bootstrap. We converge a THROWAWAY
# container, never the CI runner's host — we don't cut root SSH on an ephemeral
# runner. The two things a container physically can't do (swapon; the real,
# lock-you-out SSH reload) are dogfooded on the real VPS instead — see README.md.
#
# Usage: ./run-all.sh [--keep] [case-prefix...]
#        ./run-all.sh 03 09      # run only cases starting with 03 / 09
#        ./run-all.sh --keep     # leave the box running for inspection
set -uo pipefail

HERE="$(cd "$(dirname "${BASH_SOURCE[0]}")" && pwd)"
REPO="$(cd "$HERE/.." && pwd)"
IMAGE="server-setup-validation:latest"
BOX="server-setup-validation"
export SERVER_REPO="$REPO"
export SERVER_BOX="$BOX"

KEEP=0
declare -a FILTERS=()
for arg in "$@"; do
  case "$arg" in
  --keep) KEEP=1 ;;
  *) FILTERS+=("$arg") ;;
  esac
done

command -v docker >/dev/null 2>&1 || {
  echo "docker is required to run the validation harness." >&2
  exit 1
}

cleanup() {
  if [[ "$KEEP" == 1 ]]; then
    echo "(--keep) box left running: docker exec -it $BOX bash" >&2
  else
    docker rm -f "$BOX" >/dev/null 2>&1 || true
  fi
}
trap cleanup EXIT

echo "• building the validation box image…" >&2
docker build -q -t "$IMAGE" "$HERE/box" >/dev/null

echo "• starting the box…" >&2
docker rm -f "$BOX" >/dev/null 2>&1 || true
docker run -d --privileged --name "$BOX" \
  --tmpfs /run --tmpfs /run/lock \
  -v "$REPO":/repo:ro \
  "$IMAGE" >/dev/null

echo "• waiting for systemd + sshd…" >&2
ready=0
for _ in $(seq 1 60); do
  state="$(docker exec "$BOX" systemctl is-system-running 2>/dev/null || true)"
  if [[ "$state" == "running" || "$state" == "degraded" ]] &&
    docker exec "$BOX" systemctl is-active --quiet ssh 2>/dev/null; then
    ready=1
    break
  fi
  sleep 1
done
[[ "$ready" == 1 ]] || {
  echo "box did not become ready in time." >&2
  exit 1
}

# --- Run the cases in order -------------------------------------------------
cases=("$HERE"/cases/*/)
pass=0
fail=0
printf '\n%-34s %s\n' "CASE" "RESULT"
printf '%s\n' "------------------------------------------------"
for dir in "${cases[@]}"; do
  name="$(basename "$dir")"
  if [[ ${#FILTERS[@]} -gt 0 ]]; then
    match=0
    for pat in "${FILTERS[@]}"; do [[ "$name" == "$pat"* ]] && match=1; done
    [[ "$match" == 1 ]] || continue
  fi
  bash "$dir/run.sh" >/dev/null 2>&1 || true
  res="$(cat "$dir/RESULT.txt" 2>/dev/null || echo 'NO RESULT')"
  if [[ "$res" == PASS ]]; then
    pass=$((pass + 1))
    mark="✅"
  else
    fail=$((fail + 1))
    mark="❌"
  fi
  printf '%-34s %s %s\n' "$name" "$mark" "$res"
  # Surface a failing case's log inline so CI shows WHY without artifacts.
  if [[ "$res" != PASS ]]; then
    printf '%s\n' "----- $name/output.log -----"
    sed 's/^/    /' "$dir/output.log" 2>/dev/null || true
    printf '%s\n' "----------------------------"
  fi
done
printf '%s\n' "------------------------------------------------"
printf 'TOTAL: %s passed, %s failed\n\n' "$pass" "$fail"

[[ "$fail" -eq 0 ]]
