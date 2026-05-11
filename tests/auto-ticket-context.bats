#!/usr/bin/env bats
# CLI tests for agent/auto-ticket-context.sh

setup() {
  load 'test_helper/bats-support/load'
  load 'test_helper/bats-assert/load'
  SCRIPT="$BATS_TEST_DIRNAME/../agent/auto-ticket-context.sh"

  # Create a temp dir with a stub jira-fetch-ticket.sh alongside a symlink
  # to the real script, so $(dirname "$0")/jira-fetch-ticket.sh resolves to our stub.
  TEST_BIN="$(mktemp -d)"
  cp "$SCRIPT" "$TEST_BIN/auto-ticket-context.sh"
  chmod +x "$TEST_BIN/auto-ticket-context.sh"
  # Symlink lib so source paths resolve
  ln -s "$BATS_TEST_DIRNAME/../lib" "$TEST_BIN/../lib" 2>/dev/null ||
    ln -sf "$(cd "$BATS_TEST_DIRNAME/../lib" && pwd)" "$TEST_BIN/lib"
}

teardown() {
  rm -rf "$TEST_BIN"
}

# Helper: write a stub jira-fetch-ticket.sh into TEST_BIN
_stub_jira() {
  local body="$1" exit_code="${2:-0}"
  cat >"$TEST_BIN/jira-fetch-ticket.sh" <<STUB
#!/usr/bin/env bash
if [[ "$exit_code" -ne 0 ]]; then
  echo "upstream error" >&2
  exit $exit_code
fi
echo '$body'
STUB
  chmod +x "$TEST_BIN/jira-fetch-ticket.sh"
}

# --- Tests --------------------------------------------------------------------

@test "auto-ticket-context: --help exits 0 and prints usage" {
  run "$SCRIPT" --help
  assert_success
  assert_output --partial "Usage: auto-ticket-context"
}

@test "auto-ticket-context: branch matches and jira succeeds" {
  _stub_jira '{"key":"PROJ-123","summary":"test"}'
  run "$TEST_BIN/auto-ticket-context.sh" "feature/PROJ-123-foo"
  assert_success
  assert_output '{"key":"PROJ-123","summary":"test"}'
}

@test "auto-ticket-context: branch matches and jira fails" {
  _stub_jira '' 5
  run "$TEST_BIN/auto-ticket-context.sh" "feature/PROJ-123-foo"
  assert_failure 5
  assert_output --partial "upstream error"
}

@test "auto-ticket-context: branch doesnt match" {
  _stub_jira ''
  run "$TEST_BIN/auto-ticket-context.sh" "main"
  assert_failure
  assert_output --partial "no ticket"
}

@test "auto-ticket-context: explicit branch arg extracts ticket" {
  _stub_jira '{"key":"PROJ-456"}'
  # Also verify jira-fetch-ticket.sh receives the right arg
  cat >"$TEST_BIN/jira-fetch-ticket.sh" <<'STUB'
#!/usr/bin/env bash
echo "CALLED_WITH=$1"
STUB
  chmod +x "$TEST_BIN/jira-fetch-ticket.sh"
  run "$TEST_BIN/auto-ticket-context.sh" "feature/PROJ-456-bar"
  assert_success
  assert_output "CALLED_WITH=PROJ-456"
}
