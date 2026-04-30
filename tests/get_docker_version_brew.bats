#!/usr/bin/env bats
# CLI tests for personal/docker_rollback/get_docker_version_brew.sh
#
# `curl` and `open` are stubbed via PATH override.

setup() {
  load 'test_helper/bats-support/load'
  load 'test_helper/bats-assert/load'
  SCRIPT="$BATS_TEST_DIRNAME/../personal/docker_rollback/get_docker_version_brew.sh"

  STUBDIR="$(mktemp -d)"
  STATEFILE="$STUBDIR/calls.log"
  export PATH="$STUBDIR:$PATH"
  export STATEFILE
}

teardown() {
  [[ -d "$STUBDIR" ]] && rm -rf "$STUBDIR"
}

write_stubs() {
  cat >"$STUBDIR/curl" <<'EOF'
#!/usr/bin/env bash
echo "curl $*" >>"$STATEFILE"
# Emit minimal-but-parseable JSON-ish to the output redirection target.
# The script redirects via `>"$TEMP_FILE"` so curl just writes to stdout.
cat <<'JSON'
  "sha": "abc123def456",
  "message": "Update docker-desktop to 4.47.0"
JSON
exit 0
EOF
  chmod +x "$STUBDIR/curl"

  cat >"$STUBDIR/open" <<'EOF'
#!/usr/bin/env bash
echo "open $*" >>"$STATEFILE"
exit 0
EOF
  chmod +x "$STUBDIR/open"
}

@test "get_docker_version_brew: --help exits 0 and prints Usage" {
  run "$SCRIPT" --help
  assert_success
  assert_output --partial "Usage:"
}

@test "get_docker_version_brew: -h exits 0 and prints Usage" {
  run "$SCRIPT" -h
  assert_success
  assert_output --partial "Usage:"
}

@test "get_docker_version_brew: unknown flag exits 2" {
  run "$SCRIPT" --bogus-flag
  assert_failure 2
  assert_output --partial "unknown flag"
}

@test "get_docker_version_brew: extra positional arg exits 2" {
  run "$SCRIPT" 4.47.0 4.46.0
  assert_failure 2
}

@test "get_docker_version_brew: happy path defaults to 4.47.0 and calls curl + open" {
  write_stubs
  run "$SCRIPT"
  assert_success
  assert_output --partial "Searching for version: 4.47.0"
  run cat "$STATEFILE"
  assert_output --partial "open"
  assert_output --partial "curl"
  assert_output --partial "Homebrew/homebrew-cask/commits"
}

@test "get_docker_version_brew: explicit version flows into output" {
  write_stubs
  run "$SCRIPT" 4.46.0
  assert_success
  assert_output --partial "Searching for version: 4.46.0"
}

@test "get_docker_version_brew: require_cmd gate is present" {
  # `curl` lives in /usr/bin on most systems, so a PATH-stripping test
  # would also remove the coreutils the script's source line depends on.
  # Coverage for the exit-3 path is provided by other suites whose deps
  # are not in /usr/bin. Here we just confirm the gate exists.
  run grep -q 'require_cmd "curl"' "$SCRIPT"
  assert_success
}
