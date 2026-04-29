#!/usr/bin/env bats
# Tests for lib/common.sh helpers and exit-code conventions.

setup() {
  load 'test_helper/bats-support/load'
  load 'test_helper/bats-assert/load'
}

# --- re-source guard ---------------------------------------------------------

@test "common.sh: sets _LIB_COMMON_LOADED=1 on first source" {
  run bash -c 'source "'"$BATS_TEST_DIRNAME"'/../lib/common.sh"; echo "$_LIB_COMMON_LOADED"'
  assert_success
  assert_output "1"
}

@test "common.sh: re-sourcing is a no-op (guard works)" {
  # Set a sentinel that the body would not overwrite if guard works.
  run bash -c '
    source "'"$BATS_TEST_DIRNAME"'/../lib/common.sh"
    # Mutate a var the body sets so we can detect re-init.
    RED="SENTINEL"
    source "'"$BATS_TEST_DIRNAME"'/../lib/common.sh"
    echo "$RED"
  '
  assert_success
  assert_output "SENTINEL"
}

# --- die_* exit-code conventions ---------------------------------------------

@test "die: exits 1 with Error: prefix" {
  run bash -c 'source "'"$BATS_TEST_DIRNAME"'/../lib/common.sh"; die "boom"'
  assert_failure 1
  assert_output --partial "Error:"
  assert_output --partial "boom"
}

@test "die_usage: exits 2" {
  run bash -c 'source "'"$BATS_TEST_DIRNAME"'/../lib/common.sh"; die_usage "bad flag"'
  assert_failure 2
  assert_output --partial "Usage error:"
  assert_output --partial "bad flag"
}

@test "die_missing_dep: exits 3" {
  run bash -c 'source "'"$BATS_TEST_DIRNAME"'/../lib/common.sh"; die_missing_dep "no widget"'
  assert_failure 3
  assert_output --partial "Missing dependency:"
}

@test "die_unauthed: exits 4" {
  run bash -c 'source "'"$BATS_TEST_DIRNAME"'/../lib/common.sh"; die_unauthed "creds gone"'
  assert_failure 4
  assert_output --partial "Not authenticated:"
}

@test "die_upstream: exits 5" {
  run bash -c 'source "'"$BATS_TEST_DIRNAME"'/../lib/common.sh"; die_upstream "5xx from API"'
  assert_failure 5
  assert_output --partial "Upstream failure:"
}

# --- require_cmd -------------------------------------------------------------

@test "require_cmd: succeeds for existing command" {
  run bash -c 'source "'"$BATS_TEST_DIRNAME"'/../lib/common.sh"; require_cmd "bash"'
  assert_success
}

@test "require_cmd: exits 3 for missing command" {
  run bash -c 'source "'"$BATS_TEST_DIRNAME"'/../lib/common.sh"; require_cmd "definitely_not_a_real_cmd_xyz"'
  assert_failure 3
  assert_output --partial "Missing dependency:"
}

@test "require_cmd: includes hint when provided" {
  run bash -c 'source "'"$BATS_TEST_DIRNAME"'/../lib/common.sh"; require_cmd "no_such_cmd_xyz" "brew install no-such"'
  assert_failure 3
  assert_output --partial "brew install no-such"
}

# --- json_error: escapes content properly ------------------------------------

@test "json_error: escapes embedded double-quote" {
  run bash -c 'source "'"$BATS_TEST_DIRNAME"'/../lib/common.sh"; json_error "she said \"hi\""'
  assert_failure 1
  # Should produce parseable JSON
  echo "$output" | jq -e '.error' >/dev/null
}

@test "json_error: escapes backslash" {
  run bash -c 'source "'"$BATS_TEST_DIRNAME"'/../lib/common.sh"; json_error "path C:\\Users\\foo"'
  assert_failure 1
  echo "$output" | jq -e '.error' >/dev/null
}
