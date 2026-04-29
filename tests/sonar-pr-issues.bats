#!/usr/bin/env bats
# CLI / behavior tests for agent/sonar-pr-issues.sh.
# Stubs `sonar` and `gh` so no network calls happen.
#
# Note: the project-key lookup tests double as a regression test for the
# shfmt assoc-array corruption bug (commit 87c6eb1 fix). If shfmt ever
# rewrites the keys back into arithmetic form, "client-portal", "polaris-api",
# and "polaris-web" lookups will fail and these tests will catch it.

setup() {
  load 'test_helper/bats-support/load'
  load 'test_helper/bats-assert/load'
  SCRIPT="$BATS_TEST_DIRNAME/../agent/sonar-pr-issues.sh"

  STUBDIR="$(mktemp -d)"
  export PATH="$STUBDIR:$PATH"
}

teardown() {
  [[ -d "$STUBDIR" ]] && rm -rf "$STUBDIR"
}

# Helper: extract just the trailing JSON object from output.
get_json() { printf '%s\n' "$output" | awk '/^\{/,/^\}$/'; }

# Stub sonar that returns a fixed canned issue set on page 1 and empty on
# subsequent pages (single-page result).
write_sonar_stub() {
  cat >"$STUBDIR/sonar" <<'EOF'
#!/usr/bin/env bash
# args: auth status | list issues -p PROJECT --pull-request PR --format json --page N
case "$1 $2" in
  "auth status") exit 0 ;;
  "list issues")
    page=1
    fmt="json"
    proj=""
    pr=""
    while [[ $# -gt 0 ]]; do
      case "$1" in
        --page) page="$2"; shift 2 ;;
        --format) fmt="$2"; shift 2 ;;
        -p) proj="$2"; shift 2 ;;
        --pull-request) pr="$2"; shift 2 ;;
        *) shift ;;
      esac
    done
    if [[ "$fmt" == "toon" ]]; then
      echo "TOON OUTPUT for $proj PR $pr"
      exit 0
    fi
    if [[ "$page" == "1" ]]; then
      cat <<'JSON'
{
  "issues": [
    {"key":"a1","severity":"BLOCKER","issueStatus":"OPEN","component":"wpromote_polaris-web:src/foo.ts","message":"crit"},
    {"key":"a2","severity":"MAJOR","issueStatus":"OPEN","component":"wpromote_polaris-web:src/bar.ts","message":"maj"},
    {"key":"a3","severity":"MINOR","issueStatus":"CLOSED","component":"wpromote_polaris-web:src/baz.ts","message":"min-closed"},
    {"key":"a4","severity":"INFO","issueStatus":"OPEN","component":"wpromote_polaris-web:src/qux.ts","message":"info"}
  ],
  "paging": {"total": 4, "pageIndex": 1, "pageSize": 100}
}
JSON
    else
      echo '{"issues":[],"paging":{"total":4,"pageIndex":'"$page"',"pageSize":100}}'
    fi
    ;;
  *) echo "stub sonar: unhandled: $*" >&2; exit 99 ;;
esac
EOF
  chmod +x "$STUBDIR/sonar"
}

# Stub gh that always returns no sonar checks (so ci_status falls through).
write_gh_stub_nochecks() {
  cat >"$STUBDIR/gh" <<'EOF'
#!/usr/bin/env bash
case "$1" in
  pr) echo '[]' ;;
  *) exit 0 ;;
esac
EOF
  chmod +x "$STUBDIR/gh"
}

# --- --help -------------------------------------------------------------------

@test "sonar-pr-issues: --help exits 0 and prints usage" {
  run "$SCRIPT" --help
  assert_success
  assert_output --partial "Usage: sonar-pr-issues"
  assert_output --partial "Supported repos:"
}

@test "sonar-pr-issues: -h exits 0 and prints usage" {
  run "$SCRIPT" -h
  assert_success
  assert_output --partial "Usage: sonar-pr-issues"
}

# --- project-key lookup (regression test for shfmt assoc-array bug) ----------

@test "sonar-pr-issues: client-portal repo resolves to wpromote_client-portal" {
  write_sonar_stub
  write_gh_stub_nochecks
  # Fake repo detection by running from a tmp git repo with that remote.
  tmpdir="$(mktemp -d)"
  (
    cd "$tmpdir" && git init -q
    git remote add origin "git@github.com:wpromote/client-portal.git"
  )
  cd "$tmpdir"
  run "$SCRIPT" 1
  cd /; rm -rf "$tmpdir"
  assert_success
  get_json | jq -e '.project == "wpromote_client-portal"' >/dev/null
}

@test "sonar-pr-issues: polaris-api repo resolves to wpromote_polaris-api" {
  write_sonar_stub
  write_gh_stub_nochecks
  tmpdir="$(mktemp -d)"
  (cd "$tmpdir" && git init -q && git remote add origin "git@github.com:wpromote/polaris-api.git")
  cd "$tmpdir"
  run "$SCRIPT" 1
  cd /; rm -rf "$tmpdir"
  assert_success
  get_json | jq -e '.project == "wpromote_polaris-api"' >/dev/null
}

@test "sonar-pr-issues: polaris-web repo resolves to wpromote_polaris-web" {
  write_sonar_stub
  write_gh_stub_nochecks
  tmpdir="$(mktemp -d)"
  (cd "$tmpdir" && git init -q && git remote add origin "git@github.com:wpromote/polaris-web.git")
  cd "$tmpdir"
  run "$SCRIPT" 1
  cd /; rm -rf "$tmpdir"
  assert_success
  get_json | jq -e '.project == "wpromote_polaris-web"' >/dev/null
}

@test "sonar-pr-issues: kraken repo resolves to wpromote_kraken" {
  write_sonar_stub
  write_gh_stub_nochecks
  tmpdir="$(mktemp -d)"
  (cd "$tmpdir" && git init -q && git remote add origin "git@github.com:wpromote/kraken.git")
  cd "$tmpdir"
  run "$SCRIPT" 1
  cd /; rm -rf "$tmpdir"
  assert_success
  get_json | jq -e '.project == "wpromote_kraken"' >/dev/null
}

@test "sonar-pr-issues: unsupported repo fails with friendly error and lists supported" {
  write_sonar_stub
  write_gh_stub_nochecks
  tmpdir="$(mktemp -d)"
  (cd "$tmpdir" && git init -q && git remote add origin "git@github.com:wpromote/unsupported-repo.git")
  cd "$tmpdir"
  run "$SCRIPT" 1
  cd /; rm -rf "$tmpdir"
  assert_failure
  assert_output --partial "has no SonarCloud project"
  assert_output --partial "client-portal"
  assert_output --partial "polaris-web"
}

# --- arg parsing --------------------------------------------------------------

@test "sonar-pr-issues: explicit --project bypasses repo detection" {
  write_sonar_stub
  write_gh_stub_nochecks
  run "$SCRIPT" --project wpromote_polaris-web 1
  assert_success
  get_json | jq -e '.project == "wpromote_polaris-web" and .pr == 1' >/dev/null
}

@test "sonar-pr-issues: non-numeric positional arg is rejected" {
  write_sonar_stub
  write_gh_stub_nochecks
  run "$SCRIPT" --project wpromote_polaris-web abc123
  assert_failure
  assert_output --partial "Unexpected argument:"
}

# --- severity filtering -------------------------------------------------------

@test "sonar-pr-issues: no --severity returns all OPEN/CONFIRMED issues (skip CLOSED)" {
  write_sonar_stub
  write_gh_stub_nochecks
  run "$SCRIPT" --project wpromote_polaris-web 1
  assert_success
  # Stub returns 4 issues; 1 is CLOSED so 3 should remain.
  get_json | jq -e '.total == 3' >/dev/null
}

@test "sonar-pr-issues: --severity MAJOR keeps only BLOCKER+CRITICAL+MAJOR" {
  write_sonar_stub
  write_gh_stub_nochecks
  run "$SCRIPT" --project wpromote_polaris-web --severity MAJOR 1
  assert_success
  # Stub OPEN issues: BLOCKER, MAJOR, INFO -> filter keeps BLOCKER+MAJOR = 2.
  get_json | jq -e '.total == 2' >/dev/null
  # And no INFO should remain.
  get_json | jq -e '[.issues[].severity] | (index("INFO") // null) == null' >/dev/null
}

@test "sonar-pr-issues: --severity BLOCKER keeps only BLOCKER" {
  write_sonar_stub
  write_gh_stub_nochecks
  run "$SCRIPT" --project wpromote_polaris-web --severity BLOCKER 1
  assert_success
  get_json | jq -e '.total == 1 and .issues[0].severity == "BLOCKER"' >/dev/null
}

@test "sonar-pr-issues: --severity is case-insensitive (lowercase accepted)" {
  write_sonar_stub
  write_gh_stub_nochecks
  run "$SCRIPT" --project wpromote_polaris-web --severity blocker 1
  assert_success
  get_json | jq -e '.total == 1' >/dev/null
}

# --- component-path stripping -------------------------------------------------

@test "sonar-pr-issues: strips '<project>:' prefix from component paths" {
  write_sonar_stub
  write_gh_stub_nochecks
  run "$SCRIPT" --project wpromote_polaris-web 1
  assert_success
  # Component should be 'src/foo.ts', not 'wpromote_polaris-web:src/foo.ts'.
  get_json | jq -e '[.issues[].component] | all(. | startswith("wpromote_") | not)' >/dev/null
  get_json | jq -e '.issues[0].component | test("^src/")' >/dev/null
}

# --- output shape -------------------------------------------------------------

@test "sonar-pr-issues: output JSON has expected top-level keys" {
  write_sonar_stub
  write_gh_stub_nochecks
  run "$SCRIPT" --project wpromote_polaris-web 1
  assert_success
  get_json | jq -e '
    has("project") and has("pr") and has("ci_status") and
    has("total") and has("issues") and
    (.issues | type == "array")
  ' >/dev/null
}

@test "sonar-pr-issues: --format toon passes through raw CLI output" {
  write_sonar_stub
  write_gh_stub_nochecks
  run "$SCRIPT" --project wpromote_polaris-web --format toon 1
  assert_success
  assert_output --partial "TOON OUTPUT for wpromote_polaris-web PR 1"
}
