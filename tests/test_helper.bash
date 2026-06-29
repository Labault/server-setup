# Shared helpers for the bats suite (managed by bootstrap, shell profile).
# `load test_helper` in a .bats file pulls this in — add common setup/teardown
# and helper functions here as your suite grows.
#
# Variables defined here are consumed by the .bats files that load this helper,
# so their use isn't visible when this file is analyzed on its own.
# shellcheck disable=SC2034

# Repo root, resolved from this file's location so tests can reference scripts by
# absolute path regardless of the directory bats is invoked from.
REPO_ROOT="${REPO_ROOT:-$(cd "$(dirname "${BASH_SOURCE[0]}")/.." && pwd)}"
