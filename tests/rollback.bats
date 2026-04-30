#!/usr/bin/env bats
# CLI tests for personal/docker_rollback/rollback.sh
#
# `brew` and `curl` are stubbed via PATH override. Happy-path behavior is
# interactive (read confirmations); we drive it with `<<<` heredoc input,
# but most tests only exercise --help / flag-parsing paths to stay
# deterministic.

setup() {
  load 'test_helper/bats-support/load'
  load 'test_helper/bats-assert/load'
  SCRIPT="$BATS_TEST_DIRNAME/../personal/docker_rollback/rollback.sh"

  STUBDIR="$(mktemp -d)"
  STATEFILE="$STUBDIR/calls.log"
  export PATH="$STUBDIR:$PATH"
  export STATEFILE
}

teardown() {
  [[ -d "$STUBDIR" ]] && rm -rf "$STUBDIR"
}

write_min_stubs() {
  cat >"$STUBDIR/brew" <<'EOF'
#!/usr/bin/env bash
echo "brew $*" >>"$STATEFILE"
exit 0
EOF
  chmod +x "$STUBDIR/brew"

  cat >"$STUBDIR/curl" <<'EOF'
#!/usr/bin/env bash
echo "curl $*" >>"$STATEFILE"
exit 0
EOF
  chmod +x "$STUBDIR/curl"
}

@test "rollback: --help exits 0 and prints Usage" {
  run "$SCRIPT" --help
  assert_success
  assert_output --partial "Usage:"
}

@test "rollback: -h exits 0 and prints Usage" {
  run "$SCRIPT" -h
  assert_success
  assert_output --partial "Usage:"
}

@test "rollback: unknown flag exits 2" {
  run "$SCRIPT" --bogus-flag
  assert_failure 2
  assert_output --partial "unknown flag"
}

@test "rollback: extra positional arg exits 2" {
  run "$SCRIPT" 4.47.0 4.46.0
  assert_failure 2
}

@test "rollback: user declines confirmation → exits 0 cleanly" {
  write_min_stubs
  # Reply 'n' to the y/N prompt; bypass any GitHub commit hash prompt.
  run bash -c "printf 'n\n' | '$SCRIPT' 4.47.0"
  assert_success
  assert_output --partial "Operation cancelled"
}

@test "rollback: missing brew on PATH exits 3" {
  PATH="/usr/bin:/bin" run "$SCRIPT" 4.47.0
  assert_failure 3
  assert_output --partial "brew"
}

@test "rollback: target version appears in confirmation banner" {
  write_min_stubs
  run bash -c "printf 'n\n' | '$SCRIPT' 4.46.0"
  assert_success
  assert_output --partial "Target version: 4.46.0"
}
