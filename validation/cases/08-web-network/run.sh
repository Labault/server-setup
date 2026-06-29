#!/usr/bin/env bash
# shellcheck disable=SC1091
source "$(cd "$(dirname "${BASH_SOURCE[0]}")" && pwd)/../../_lib.sh"

# Converge the web profile — this is where the `web` network gets created and
# 80/443 get opened.
server "converge web" "setup --profile web"
check "web-network processed" "$(out_has 'web-network')"
check "docker web network exists" "$(box_ok 'docker network inspect web')"
check "ufw-web processed" "$(out_has 'ufw-web')"
verdict
