#!/usr/bin/env bash
# shellcheck disable=SC1091
source "$(cd "$(dirname "${BASH_SOURCE[0]}")" && pwd)/../../_lib.sh"

# Reference proof: the box is converged to `web`. Re-running is a no-op (web
# units already satisfied), and the push-to-deploy DOORMAT is in place — exactly
# what push-to-deploy needs to clone and `docker compose up -d` with no manual
# step in between.
server "re-converge web (idempotent)" "setup --profile web"
check "idempotent: nothing re-converged" "$(out_has '0 converged')"

check "Docker daemon up" "$(box_ok 'systemctl is-active --quiet docker')"
check "web network present" "$(box_ok 'docker network inspect web')"
check "deploy user present" "$(box_ok 'id -u deploy')"
check "deploy in the docker group" "$(box_ok 'id -nG deploy | grep -qw docker')"
# One explicit NTP path: timesyncd installed and enabled, the chrony shipped by
# the box purged. In a container the unit is condition-skipped (host owns the
# clock), so is-enabled is as far as we can probe — same invariant assert_timesync
# accepts here; is-active is dogfooded on the real VPS (D15).
check "systemd-timesyncd enabled" "$(box_ok 'systemctl is-enabled --quiet systemd-timesyncd')"
check "chrony purged" "$(box_ok '! dpkg -s chrony >/dev/null 2>&1')"
check "ufw 22 open" "$(box_ok 'ufw status | grep 22/tcp | grep -qw ALLOW')"
check "ufw 80 open" "$(box_ok 'ufw status | grep 80/tcp | grep -qw ALLOW')"
check "ufw 443 open" "$(box_ok 'ufw status | grep 443/tcp | grep -qw ALLOW')"
verdict
