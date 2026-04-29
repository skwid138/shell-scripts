#!/usr/bin/env bats
# CLI / arg-parsing tests for agent/gh-pr-comments.sh.
#
# This script's main work happens behind `gh api` / `gh pr view` calls.
# Exhaustive end-to-end testing belongs in an integration suite. Here we
# verify CLI surface, exit-code discipline, and that the script's
# `_parse_pr_ref` shim still resolves to lib/detect.sh::parse_pr_ref.

setup() {
  load 'test_helper/bats-support/load'
  load 'test_helper/bats-assert/load'
  SCRIPT="$BATS_TEST_DIRNAME/../agent/gh-pr-comments.sh"

  STUBDIR="$(mktemp -d)"
  export PATH="$STUBDIR:$PATH"
}

teardown() {
  [[ -d "$STUBDIR" ]] && rm -rf "$STUBDIR"
}

# Stub `gh` so that `gh auth status` succeeds but any other call exits 1
# immediately. That lets the script reach (and fail at) the network step,
# proving arg parsing succeeded.
stub_gh_authed_but_no_network() {
  cat >"$STUBDIR/gh" <<'EOF'
#!/usr/bin/env bash
case "$1" in
  auth) exit 0 ;;
  *)    echo "stub gh: refusing network call: $*" >&2; exit 1 ;;
esac
EOF
  chmod +x "$STUBDIR/gh"
}

# --- --help -------------------------------------------------------------------

@test "gh-pr-comments: --help exits 0 and prints usage" {
  run "$SCRIPT" --help
  assert_success
  assert_output --partial "Usage: gh-pr-comments"
  assert_output --partial "PR_REF"
}

@test "gh-pr-comments: -h exits 0 and prints usage" {
  run "$SCRIPT" -h
  assert_success
  assert_output --partial "Usage: gh-pr-comments"
}

# --- arg parse failures (run before any network) ------------------------------

@test "gh-pr-comments: extra positional after --pr is rejected" {
  stub_gh_authed_but_no_network
  run "$SCRIPT" --pr 123 unexpected_extra
  assert_failure
  assert_output --partial "Unexpected argument:"
}

# --- PR ref parsing happens locally before any gh call -----------------------

@test "gh-pr-comments: invalid URL form fails before network" {
  stub_gh_authed_but_no_network
  run "$SCRIPT" "https://example.com/not-a-pr-url"
  assert_failure
  # Should hit detect.sh's parse error, not the gh stub's "refusing network".
  refute_output --partial "stub gh: refusing"
}

@test "gh-pr-comments: owner/repo#NUM positional populates fields and reaches network" {
  stub_gh_authed_but_no_network
  run "$SCRIPT" "wpromote/polaris-web#275" --no-diff --no-commits
  # gh stub will fail on the gh pr view call, but that's POST-parse: proves
  # the positional was accepted and OWNER/REPO/PR_NUMBER set.
  assert_failure
  assert_output --partial "Could not access PR #275"
  assert_output --partial "wpromote/polaris-web"
}

@test "gh-pr-comments: bare number with --owner/--repo reaches network" {
  stub_gh_authed_but_no_network
  run "$SCRIPT" --pr 123 --owner wpromote --repo polaris-api --no-diff --no-commits
  assert_failure
  assert_output --partial "Could not access PR #123"
  assert_output --partial "wpromote/polaris-api"
}

# --- gh auth gating -----------------------------------------------------------
# Note: the unauthed -> exit 4 path is unit-tested against require_auth in
# tests/common.bats; not re-tested per-script.
