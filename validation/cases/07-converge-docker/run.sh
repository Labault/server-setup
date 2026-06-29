#!/usr/bin/env bash
# shellcheck disable=SC1091
source "$(cd "$(dirname "${BASH_SOURCE[0]}")" && pwd)/../../_lib.sh"

# Converge the docker profile on top of minimal.
server "converge docker" "setup --profile docker"
check "docker-engine processed" "$(out_has 'docker-engine')"
check "docker daemon is active" "$(box_ok 'systemctl is-active --quiet docker')"
check "compose plugin present" "$(box_ok 'docker compose version')"
check "daemon.json has log rotation" "$(box_ok 'grep -q max-size /etc/docker/daemon.json')"
check "deploy is in the docker group" "$(box_ok 'id -nG deploy | grep -qw docker')"
verdict
