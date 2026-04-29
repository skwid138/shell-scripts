#!/usr/bin/env bats
# CLI / behavior tests for agent/gh-pr-checks-summary.sh.
# Stubs `gh` so no network calls happen.

setup() {
  load 'test_helper/bats-support/load'
  load 'test_helper/bats-assert/load'
  SCRIPT="$BATS_TEST_DIRNAME/../agent/gh-pr-checks-summary.sh"

  STUBDIR="$(mktemp -d)"
  export PATH="$STUBDIR:$PATH"
}

teardown() {
  [[ -d "$STUBDIR" ]] && rm -rf "$STUBDIR"
}

# Helper: extract just the JSON object from output (info() goes to stderr
# but bats merges stderr with stdout in $output by default).
get_json() { printf '%s\n' "$output" | awk '/^\{/,/^\}$/'; }

# Stub `gh` whose behavior on `gh pr checks ...` is controlled per-test by
# the GH_CHECKS_OUT and GH_CHECKS_RC env vars.
write_gh_stub() {
  cat >"$STUBDIR/gh" <<'EOF'
#!/usr/bin/env bash
case "$1" in
  auth) exit 0 ;;
  pr)
    if [[ "$2" == "checks" ]]; then
      [[ -n "${GH_CHECKS_OUT:-}" ]] && printf '%s\n' "$GH_CHECKS_OUT"
      [[ -n "${GH_CHECKS_ERR:-}" ]] && printf '%s\n' "$GH_CHECKS_ERR" >&2
      exit "${GH_CHECKS_RC:-0}"
    fi
    ;;
esac
echo "stub gh: unhandled: $*" >&2
exit 99
EOF
  chmod +x "$STUBDIR/gh"
}

# Canned check sets (gh pr checks --json name,bucket,state,workflow,link).
CHECKS_MIXED='[
  {"name":"Lint",       "bucket":"pass",     "state":"SUCCESS",       "workflow":"CI", "link":"https://e/1"},
  {"name":"Test",       "bucket":"pass",     "state":"SUCCESS",       "workflow":"CI", "link":"https://e/2"},
  {"name":"SonarCloud Code Analysis", "bucket":"pass", "state":"SUCCESS", "workflow":"sonar", "link":"https://e/3"},
  {"name":"Deploy",     "bucket":"skipping", "state":"SKIPPED",       "workflow":"CD", "link":"https://e/4"},
  {"name":"E2E",        "bucket":"fail",     "state":"FAILURE",       "workflow":"CI", "link":"https://e/5"},
  {"name":"Slow Test",  "bucket":"pending",  "state":"IN_PROGRESS",   "workflow":"CI", "link":"https://e/6"}
]'

# --- --help -------------------------------------------------------------------

@test "gh-pr-checks-summary: --help exits 0 and prints usage" {
  run "$SCRIPT" --help
  assert_success
  assert_output --partial "Usage: gh-pr-checks-summary"
}

@test "gh-pr-checks-summary: -h exits 0 and prints usage" {
  run "$SCRIPT" -h
  assert_success
  assert_output --partial "Usage: gh-pr-checks-summary"
}

# --- usage errors -------------------------------------------------------------

@test "gh-pr-checks-summary: --filter without value exits 2" {
  write_gh_stub
  run "$SCRIPT" --filter
  assert_failure 2
  assert_output --partial "Usage error:"
}

@test "gh-pr-checks-summary: extra positional exits 2" {
  write_gh_stub
  export GH_CHECKS_OUT="$CHECKS_MIXED"
  run "$SCRIPT" "wpromote/polaris-web#271" extra
  assert_failure 2
  assert_output --partial "Unexpected argument:"
}

# --- default JSON output ------------------------------------------------------

@test "gh-pr-checks-summary: classifies bucket=pass as passed, fail as failed, pending as running" {
  write_gh_stub
  export GH_CHECKS_OUT="$CHECKS_MIXED"
  run "$SCRIPT" "wpromote/polaris-web#271"
  assert_success
  get_json | jq -e '
    .summary.total   == 6 and
    .summary.passed  == 3 and
    .summary.failed  == 1 and
    .summary.running == 1 and
    .summary.other   == 1
  ' >/dev/null
}

@test "gh-pr-checks-summary: synthetic summary_state field is added per check" {
  write_gh_stub
  export GH_CHECKS_OUT="$CHECKS_MIXED"
  run "$SCRIPT" "wpromote/polaris-web#271"
  assert_success
  get_json | jq -e '
    [.checks[].summary_state] | sort | unique
    == ["failed","other","passed","running"]
  ' >/dev/null
}

@test "gh-pr-checks-summary: preserves raw bucket/state fields alongside summary_state" {
  write_gh_stub
  export GH_CHECKS_OUT="$CHECKS_MIXED"
  run "$SCRIPT" "wpromote/polaris-web#271"
  assert_success
  get_json | jq -e '
    (.checks[0] | has("bucket") and has("state") and has("summary_state"))
  ' >/dev/null
}

# --- --filter -----------------------------------------------------------------

@test "gh-pr-checks-summary: --filter narrows by case-insensitive name regex" {
  write_gh_stub
  export GH_CHECKS_OUT="$CHECKS_MIXED"
  run "$SCRIPT" --filter SONAR "wpromote/polaris-web#271"
  assert_success
  get_json | jq -e '
    .summary.total == 1 and
    .checks[0].name == "SonarCloud Code Analysis" and
    .checks[0].summary_state == "passed"
  ' >/dev/null
}

@test "gh-pr-checks-summary: --filter zero matches yields total=0 (no error)" {
  write_gh_stub
  export GH_CHECKS_OUT="$CHECKS_MIXED"
  run "$SCRIPT" --filter "no-such-check" "wpromote/polaris-web#271"
  assert_success
  get_json | jq -e '.summary.total == 0' >/dev/null
}

# --- --status -----------------------------------------------------------------

@test "gh-pr-checks-summary: --status with --filter sonar (all green) prints 'passed'" {
  write_gh_stub
  export GH_CHECKS_OUT="$CHECKS_MIXED"
  run "$SCRIPT" --filter sonar --status "wpromote/polaris-web#271"
  assert_success
  assert_output "passed"
}

@test "gh-pr-checks-summary: --status with no filter and a failure prints 'failed'" {
  write_gh_stub
  export GH_CHECKS_OUT="$CHECKS_MIXED"
  run "$SCRIPT" --status "wpromote/polaris-web#271"
  assert_success
  # Mixed set has 1 failure; failed wins over running wins over passed.
  assert_output "failed"
}

@test "gh-pr-checks-summary: --status precedence: failed > running > passed" {
  write_gh_stub
  export GH_CHECKS_OUT='[
    {"name":"a","bucket":"pass","state":"SUCCESS","workflow":"","link":""},
    {"name":"b","bucket":"pending","state":"IN_PROGRESS","workflow":"","link":""}
  ]'
  run "$SCRIPT" --status "wpromote/polaris-web#271"
  assert_success
  assert_output "running"
}

@test "gh-pr-checks-summary: --status with zero matches prints 'not_found'" {
  write_gh_stub
  export GH_CHECKS_OUT="$CHECKS_MIXED"
  run "$SCRIPT" --filter "no-such" --status "wpromote/polaris-web#271"
  assert_success
  assert_output "not_found"
}

@test "gh-pr-checks-summary: --status with zero checks at all prints 'not_found'" {
  write_gh_stub
  export GH_CHECKS_OUT='[]'
  run "$SCRIPT" --status "wpromote/polaris-web#271"
  assert_success
  assert_output "not_found"
}

# --- gh edge cases ------------------------------------------------------------

@test "gh-pr-checks-summary: 'no checks reported' on stderr is treated as empty" {
  write_gh_stub
  export GH_CHECKS_OUT=""
  export GH_CHECKS_ERR="no checks reported on the 'main' branch"
  export GH_CHECKS_RC=1
  run "$SCRIPT" "wpromote/polaris-web#271"
  assert_success
  get_json | jq -e '.summary.total == 0 and (.checks | length == 0)' >/dev/null
}

@test "gh-pr-checks-summary: real upstream gh failure exits 5 (die_upstream)" {
  write_gh_stub
  export GH_CHECKS_OUT=""
  export GH_CHECKS_ERR="HTTP 502: bad gateway"
  export GH_CHECKS_RC=1
  run "$SCRIPT" "wpromote/polaris-web#271"
  assert_failure 5
  assert_output --partial "Upstream failure:"
}

@test "gh-pr-checks-summary: gh rc=8 (checks pending) is not treated as failure" {
  write_gh_stub
  export GH_CHECKS_OUT='[
    {"name":"slow","bucket":"pending","state":"IN_PROGRESS","workflow":"","link":""}
  ]'
  export GH_CHECKS_RC=8
  run "$SCRIPT" "wpromote/polaris-web#271"
  assert_success
  get_json | jq -e '.summary.running == 1' >/dev/null
}
