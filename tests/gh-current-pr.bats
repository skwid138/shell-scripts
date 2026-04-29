#!/usr/bin/env bats
# CLI tests for agent/gh-current-pr.sh
# We stub `gh` via PATH override to avoid hitting GitHub.

setup() {
  load 'test_helper/bats-support/load'
  load 'test_helper/bats-assert/load'
  SCRIPT="$BATS_TEST_DIRNAME/../agent/gh-current-pr.sh"

  # Per-test stubs dir prepended to PATH.
  STUBDIR="$(mktemp -d)"
  export PATH="$STUBDIR:$PATH"
}

teardown() {
  [[ -d "$STUBDIR" ]] && rm -rf "$STUBDIR"
}

# Helper: write a fake `gh` binary that branches on its first arg.
write_gh_stub() {
  cat >"$STUBDIR/gh" <<'EOF'
#!/usr/bin/env bash
# Args:  $1 = subcommand (auth | pr | api …)
case "$1" in
  auth) exit 0 ;;                              # always authed
  pr)   shift; eval "$GH_PR_BEHAVIOR" ;;       # caller-controlled
  *)    echo "unexpected gh args: $*" >&2; exit 99 ;;
esac
EOF
  chmod +x "$STUBDIR/gh"
}

# --- --help -------------------------------------------------------------------

@test "gh-current-pr: --help exits 0 and prints usage" {
  run "$SCRIPT" --help
  assert_success
  assert_output --partial "Usage: gh-current-pr"
}

@test "gh-current-pr: -h exits 0 and prints usage" {
  run "$SCRIPT" -h
  assert_success
  assert_output --partial "Usage: gh-current-pr"
}

# --- bare invocation: prints PR number ---------------------------------------

@test "gh-current-pr: prints PR number from gh stub" {
  write_gh_stub
  export GH_PR_BEHAVIOR='echo "275"'
  run "$SCRIPT"
  assert_success
  assert_output "275"
}

@test "gh-current-pr: 'no PR found' -> exit 1 with friendly error" {
  write_gh_stub
  export GH_PR_BEHAVIOR='echo "no pull requests found for branch foo" >&2; exit 1'
  run "$SCRIPT"
  assert_failure 1
  assert_output --partial "No open PR found"
}

@test "gh-current-pr: real upstream failure -> exit 5 (die_upstream)" {
  write_gh_stub
  export GH_PR_BEHAVIOR='echo "HTTP 502: bad gateway" >&2; exit 1'
  run "$SCRIPT"
  assert_failure 5
  assert_output --partial "Upstream failure:"
}

# --- --json: outputs full JSON ------------------------------------------------

@test "gh-current-pr: --json prints JSON object on success" {
  write_gh_stub
  export GH_PR_BEHAVIOR='echo "{\"number\":275,\"url\":\"https://example.com/x/pull/275\",\"headRefName\":\"feat\",\"baseRefName\":\"main\"}"'
  run "$SCRIPT" --json
  assert_success
  echo "$output" | jq -e '.number == 275 and .baseRefName == "main"' >/dev/null
}

@test "gh-current-pr: --json with no PR fails with friendly error" {
  write_gh_stub
  export GH_PR_BEHAVIOR='exit 1'
  run "$SCRIPT" --json
  assert_failure
  assert_output --partial "No open PR found"
}
