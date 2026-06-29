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
check "ufw 22 open" "$(box_ok 'ufw status | grep 22/tcp | grep -qw ALLOW')"
check "ufw 80 open" "$(box_ok 'ufw status | grep 80/tcp | grep -qw ALLOW')"
check "ufw 443 open" "$(box_ok 'ufw status | grep 443/tcp | grep -qw ALLOW')"
verdict
