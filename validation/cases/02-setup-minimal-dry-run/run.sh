#!/usr/bin/env bash
# shellcheck disable=SC1091
source "$(cd "$(dirname "${BASH_SOURCE[0]}")" && pwd)/../../_lib.sh"

server "dry-run minimal" "setup --profile minimal --dry-run"
check "would converge deploy-user" "$(out_has 'would converge: deploy-user')"
check "lists ssh-hardening" "$(out_has 'ssh-hardening')"
check "nothing changed note" "$(out_has 'Nothing changed')"
check "exit 0" "$(exit_is 0)"
# dry-run must not mutate: nothing converged yet at this point in the run.
check "no state file written" "$(box_ok '[ ! -f /var/lib/server-setup/state.yaml ]')"
check "deploy user not created" "$(box_ok '! id -u deploy >/dev/null 2>&1')"
verdict
