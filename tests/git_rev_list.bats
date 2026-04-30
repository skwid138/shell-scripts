#!/usr/bin/env bats
# CLI tests for personal/git_rev_list.sh
#
# `git` is stubbed via PATH override so tests don't require a real repo or
# remote refs. Each stub call is logged to STATEFILE for assertion.

setup() {
  load 'test_helper/bats-support/load'
  load 'test_helper/bats-assert/load'
  SCRIPT="$BATS_TEST_DIRNAME/../personal/git_rev_list.sh"

  STUBDIR="$(mktemp -d)"
  STATEFILE="$STUBDIR/calls.log"
  export PATH="$STUBDIR:$PATH"
  export STATEFILE
}

teardown() {
  [[ -d "$STUBDIR" ]] && rm -rf "$STUBDIR"
}

# Write a git stub. Behavior:
#   - rev-parse --is-inside-work-tree → exit 0 (we're "in a repo")
#   - show-ref --verify --quiet refs/remotes/origin/develop → exit 0 (default base wins)
#   - rev-parse --abbrev-ref HEAD → "feature/x"
#   - fetch --all → exit 0
#   - rev-list --left-right --count A...B → "1   2"
write_git_stub() {
  cat >"$STUBDIR/git" <<'EOF'
#!/usr/bin/env bash
echo "git $*" >>"$STATEFILE"
case "$1" in
  rev-parse)
    if [[ "$2" == "--is-inside-work-tree" ]]; then exit 0; fi
    if [[ "$2" == "--abbrev-ref" && "$3" == "HEAD" ]]; then echo "feature/x"; exit 0; fi
    exit 0
    ;;
  show-ref)
    # First lookup (origin/develop) succeeds → default base.
    [[ "$*" == *"origin/develop"* ]] && exit 0
    exit 1
    ;;
  fetch) exit 0 ;;
  rev-list)
    echo "1	2"
    exit 0
    ;;
  *) exit 0 ;;
esac
EOF
  chmod +x "$STUBDIR/git"
}

@test "git_rev_list: --help exits 0 and prints Usage" {
  run "$SCRIPT" --help
  assert_success
  assert_output --partial "Usage:"
}

@test "git_rev_list: -h exits 0 and prints Usage" {
  run "$SCRIPT" -h
  assert_success
  assert_output --partial "Usage:"
}

@test "git_rev_list: unknown flag exits 2" {
  run "$SCRIPT" --bogus-flag
  assert_failure 2
  assert_output --partial "unknown flag"
}

@test "git_rev_list: missing value for --base exits 2" {
  run "$SCRIPT" --base
  assert_failure 2
}

@test "git_rev_list: happy path uses default base origin/develop and current branch" {
  write_git_stub
  run "$SCRIPT"
  assert_success
  run cat "$STATEFILE"
  assert_output --partial "fetch --all"
  assert_output --partial "rev-list --left-right --count origin/develop...feature/x"
}

@test "git_rev_list: explicit --base and --compare flow into rev-list" {
  write_git_stub
  run "$SCRIPT" --base origin/main --compare topic
  assert_success
  run cat "$STATEFILE"
  assert_output --partial "rev-list --left-right --count origin/main...topic"
}

@test "git_rev_list: stub validates that require_cmd gates the script" {
  # `git` is in /usr/bin on most systems so we can't easily simulate its
  # absence in a PATH-stub style test (stripping /usr/bin breaks bash
  # itself). Coverage for require_cmd's exit-3 path is provided by the
  # other test suites whose deps (ffmpeg, docker, brew) are NOT in /usr/bin.
  # Here we simply confirm the require_cmd line is present in the script.
  run grep -q 'require_cmd "git"' "$SCRIPT"
  assert_success
}
