#!/usr/bin/env bats
# CLI tests for agent/branch-to-ticket.sh

setup() {
  load 'test_helper/bats-support/load'
  load 'test_helper/bats-assert/load'
  SCRIPT="$BATS_TEST_DIRNAME/../agent/branch-to-ticket.sh"
}

# --- --help / -h --------------------------------------------------------------

@test "branch-to-ticket: --help exits 0 and prints usage" {
  run "$SCRIPT" --help
  assert_success
  assert_output --partial "Usage: branch-to-ticket"
}

@test "branch-to-ticket: -h exits 0 and prints usage" {
  run "$SCRIPT" -h
  assert_success
  assert_output --partial "Usage: branch-to-ticket"
}

# --- explicit branch arg ------------------------------------------------------

@test "branch-to-ticket: bixb_18835 -> BIXB-18835" {
  run "$SCRIPT" "bixb_18835"
  assert_success
  assert_output "BIXB-18835"
}

@test "branch-to-ticket: bixb-18835-some-description -> BIXB-18835" {
  run "$SCRIPT" "bixb-18835-some-description"
  assert_success
  assert_output "BIXB-18835"
}

@test "branch-to-ticket: feature/bixb_123 -> BIXB-123" {
  run "$SCRIPT" "feature/bixb_123"
  assert_success
  assert_output "BIXB-123"
}

@test "branch-to-ticket: BIXB-18835 -> BIXB-18835 (already canonical)" {
  run "$SCRIPT" "BIXB-18835"
  assert_success
  assert_output "BIXB-18835"
}

# --- failure paths ------------------------------------------------------------

@test "branch-to-ticket: 'main' fails with clear error" {
  run "$SCRIPT" "main"
  assert_failure
  assert_output --partial "Error:"
  assert_output --partial "main"
}

@test "branch-to-ticket: '123-no-prefix' fails (no letter prefix)" {
  run "$SCRIPT" "123-no-prefix"
  assert_failure
}

@test "branch-to-ticket: empty arg falls back to current branch (no-arg path)" {
  # Run from a temporary git repo with a branch we control.
  tmpdir="$(mktemp -d)"
  (
    cd "$tmpdir"
    git init -q
    git checkout -q -b proj-456-feature 2>/dev/null
    git commit -q --allow-empty -m init
  )
  cd "$tmpdir"
  run "$SCRIPT"
  cd /
  rm -rf "$tmpdir"
  assert_success
  assert_output "PROJ-456"
}
