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

write_gh_happy_path_stub() {
  cat >"$STUBDIR/gh" <<'EOF'
#!/usr/bin/env bash
case "$1" in
  auth)
    exit 0
    ;;
  pr)
    case "$2" in
      view)
        args=" $* "
        if [[ "$args" == *" --jq "* ]]; then
          cat <<'JSON'
["src/foo.ts","src/bar.ts"]
JSON
        else
          cat <<'JSON'
{"number":123,"title":"Test PR","body":"Body","state":"OPEN","baseRefName":"main","headRefName":"feature/test","author":{"login":"alice"},"mergeable":"MERGEABLE","url":"https://github.com/wpromote/polaris-web/pull/123"}
JSON
        fi
        ;;
      *)
        echo "stub gh: unhandled pr command: $*" >&2
        exit 99
        ;;
    esac
    ;;
  api)
    args=" $* "
    if [[ "$args" == *"reviewThreads"* ]]; then
      cat <<'JSON'
{"data":{"repository":{"pullRequest":{"reviewThreads":{"pageInfo":{"hasNextPage":false,"endCursor":null},"nodes":[{"isResolved":false,"isOutdated":false,"comments":{"nodes":[{"author":{"login":"bob"},"body":"Please fix","path":"src/foo.ts","line":10,"originalLine":10,"createdAt":"2026-05-20T00:00:00Z","url":"https://example.test/thread","outdated":false}]}}]}}}}}
JSON
    elif [[ "$args" == *"reviews"* ]]; then
      cat <<'JSON'
{"data":{"repository":{"pullRequest":{"reviews":{"pageInfo":{"hasNextPage":false,"endCursor":null},"nodes":[{"author":{"login":"carol"},"state":"COMMENTED","body":"Looks good","createdAt":"2026-05-20T00:00:00Z","url":"https://example.test/review"}]}}}}}
JSON
    else
      echo "stub gh: unhandled graphql query: $*" >&2
      exit 99
    fi
    ;;
  *)
    echo "stub gh: unhandled: $*" >&2
    exit 99
    ;;
esac
EOF
  chmod +x "$STUBDIR/gh"
}

get_json() { printf '%s\n' "$output" | awk '/^\{/,/^\}$/'; }

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

@test "gh-pr-comments: happy path output has version, counts, and expected arrays" {
  write_gh_happy_path_stub
  run "$SCRIPT" --owner wpromote --repo polaris-web --pr 123 --no-diff --no-commits
  assert_success
  get_json | jq -e '
    .version == 1 and
    .metadata.number == 123 and
    .metadata.title == "Test PR" and
    (.reviews | type == "array") and
    (.threads | type == "array") and
    (.files | type == "array") and
    (.commits | type == "array") and
    .diff == "" and
    .counts.reviews == (.reviews | length) and
    .counts.threads == (.threads | length) and
    .counts.files == (.files | length) and
    .counts.commits == (.commits | length) and
    .counts.reviews == 1 and
    .counts.threads == 1 and
    .counts.files == 2 and
    .counts.commits == 0
  ' >/dev/null
}

# --- gh auth gating -----------------------------------------------------------
# Note: the unauthed -> exit 4 path is unit-tested against require_auth in
# tests/common.bats; not re-tested per-script.
