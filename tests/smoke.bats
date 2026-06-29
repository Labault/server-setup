#!/usr/bin/env bats
# Managed by bootstrap (shell profile). A trivial smoke test so `bats tests/` is
# green from the first run — bats exits non-zero on an empty tests/ directory.
# Replace it with real tests as your suite grows.
load test_helper

@test "bats harness runs" {
  run true
  [ "$status" -eq 0 ]
}
