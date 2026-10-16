#!/usr/bin/env bats
bats_require_minimum_version 1.5.0
# CLI tests for agent/jira-sprint-tickets.sh.
#
# Stubs `acli` on PATH so no Atlassian network call is made. The stub records
# the exact argv it received (one arg per line) so tests assert the real
# `--jql` / flag argv, not just the `.jql` echo in the envelope. The stub
# mirrors verified acli behavior: `jira workitem search` returns a top-level
# JSON array and rejects --fields values outside key/summary/status/issuetype
# (real acli rejects `components` and `*all` on search).

setup() {
  load 'test_helper/bats-support/load'
  load 'test_helper/bats-assert/load'
  SCRIPT="$BATS_TEST_DIRNAME/../agent/jira-sprint-tickets.sh"

  STUBDIR="$BATS_TEST_TMPDIR/stub"
  mkdir -p "$STUBDIR"
  ARGV_FILE="$BATS_TEST_TMPDIR/acli-search-argv"
  export ARGV_FILE
  write_acli_stub
  export PATH="$STUBDIR:$PATH"

  # Defaults: authed, search succeeds with an empty array.
  export ACLI_AUTH_RC=0
  export ACLI_SEARCH_RC=0
  export ACLI_SEARCH_OUT='[]'
  export ACLI_SEARCH_ERR=''
}

write_acli_stub() {
  cat >"$STUBDIR/acli" <<'EOF'
#!/usr/bin/env bash
case "$1 $2" in
  "auth status") exit "${ACLI_AUTH_RC:-0}" ;;
  "jira workitem")
    if [[ "$3" != "search" ]]; then
      echo "stub acli: unhandled: $*" >&2
      exit 99
    fi
    printf '%s\n' "$@" >"$ARGV_FILE"
    # Reject unsupported --fields values, like real acli search does.
    prev=""
    for a in "$@"; do
      if [[ "$prev" == "--fields" ]]; then
        IFS=',' read -r -a fs <<<"$a"
        for f in "${fs[@]}"; do
          case "$f" in
            key | summary | status | issuetype) ;;
            *)
              echo "stub acli: unsupported field: $f" >&2
              exit 1
              ;;
          esac
        done
      fi
      prev="$a"
    done
    [[ -n "${ACLI_SEARCH_ERR:-}" ]] && printf '%s\n' "$ACLI_SEARCH_ERR" >&2
    printf '%s' "${ACLI_SEARCH_OUT-}"
    exit "${ACLI_SEARCH_RC:-0}"
    ;;
  *)
    echo "stub acli: unhandled: $*" >&2
    exit 99
    ;;
esac
EOF
  chmod +x "$STUBDIR/acli"
}

# Expected argv (one per line) for a search call with the given JQL and tail flags.
expected_argv() {
  local jql="$1"
  shift
  printf '%s\n' jira workitem search --jql "$jql" --fields 'key,summary,status,issuetype' --json "$@"
}

assert_acli_argv() {
  [[ -f "$ARGV_FILE" ]] || fail "acli search was never called"
  assert_equal "$(cat "$ARGV_FILE")" "$(expected_argv "$@")"
}

assert_no_search() {
  [[ ! -e "$ARGV_FILE" ]] || fail "acli search should not have been called; argv: $(cat "$ARGV_FILE")"
}

# stdout must be exactly one parseable JSON document.
assert_single_json_doc() {
  local n
  n="$(printf '%s' "$output" | jq -s 'length')" || fail "stdout is not valid JSON: $output"
  assert_equal "$n" "1"
}

DEFAULT_JQL='project = BIXB AND assignee = currentUser() AND sprint in openSprints() ORDER BY created ASC'

# --- --help -------------------------------------------------------------------

@test "jira-sprint-tickets: --help exits 0 and prints usage" {
  run --separate-stderr "$SCRIPT" --help
  assert_success
  assert_output --partial "Usage: jira-sprint-tickets"
  assert_output --partial "--project"
  assert_no_search
}

@test "jira-sprint-tickets: -h exits 0 and prints usage" {
  run --separate-stderr "$SCRIPT" -h
  assert_success
  assert_output --partial "Usage: jira-sprint-tickets"
}

# --- default query ------------------------------------------------------------

@test "jira-sprint-tickets: defaults to currentUser() unquoted, open sprints, paginated" {
  run --separate-stderr "$SCRIPT" --project BIXB
  assert_success
  assert_acli_argv "$DEFAULT_JQL" --paginate
  assert_single_json_doc
  assert_equal "$(jq -cS . <<<"$output")" \
    "$(jq -cnS --arg jql "$DEFAULT_JQL" '{version:1, jql:$jql, count:0, limited:false, tickets:[]}')"
}

# --- normalization ------------------------------------------------------------

# Shaped like real `acli jira workitem search --json` output: a top-level array
# with .key, .fields.summary, .fields.status.name, .fields.issuetype.name.
MULTI_FIXTURE='[
  {"id":"10001","key":"BIXB-101","fields":{"summary":"Plain ticket","status":{"name":"Ready for Release","id":"1"},"issuetype":{"name":"Story","id":"7"}}},
  {"id":"10002","key":"BIXB-102","fields":{"summary":"Résumé — 日本語 ✓ \"quoted\"","status":{"name":"In QA Review"},"issuetype":{"name":"Bug"}}},
  {"id":"10003","key":"BIXB-103","fields":{"summary":null,"status":null}},
  {"id":"10004","key":"BIXB-104"}
]'

@test "jira-sprint-tickets: normalizes multi-ticket acli output (Unicode, missing fields)" {
  ACLI_SEARCH_OUT="$MULTI_FIXTURE" run --separate-stderr "$SCRIPT" --project BIXB
  assert_success
  assert_single_json_doc
  expected="$(jq -cnS --arg jql "$DEFAULT_JQL" '{
    version: 1, jql: $jql, count: 4, limited: false,
    tickets: [
      {key:"BIXB-101", summary:"Plain ticket", status:"Ready for Release", type:"Story"},
      {key:"BIXB-102", summary:"Résumé — 日本語 ✓ \"quoted\"", status:"In QA Review", type:"Bug"},
      {key:"BIXB-103", summary:"", status:"", type:""},
      {key:"BIXB-104", summary:"", status:"", type:""}
    ]}')"
  assert_equal "$(jq -cS . <<<"$output")" "$expected"
}

# --- query construction -------------------------------------------------------

@test "jira-sprint-tickets: email assignee becomes a quoted JQL string literal" {
  run --separate-stderr "$SCRIPT" --project BIXB --assignee 'someone@example.com'
  assert_success
  jql='project = BIXB AND assignee = "someone@example.com" AND sprint in openSprints() ORDER BY created ASC'
  assert_acli_argv "$jql" --paginate
  assert_equal "$(jq -r .jql <<<"$output")" "$jql"
}

@test "jira-sprint-tickets: only the exact currentUser() sentinel is unquoted" {
  run --separate-stderr "$SCRIPT" --project BIXB --assignee 'currentUser() OR 1=1'
  assert_success
  assert_acli_argv 'project = BIXB AND assignee = "currentUser() OR 1=1" AND sprint in openSprints() ORDER BY created ASC' --paginate
}

@test "jira-sprint-tickets: embedded quotes and backslashes are escaped" {
  run --separate-stderr "$SCRIPT" --project BIXB --assignee 'a"b\c'
  assert_success
  assert_acli_argv 'project = BIXB AND assignee = "a\"b\\c" AND sprint in openSprints() ORDER BY created ASC' --paginate
}

@test "jira-sprint-tickets: two statuses with spaces combine as status in (...)" {
  run --separate-stderr "$SCRIPT" --project BIXB --status 'Ready for Release' --status 'In QA Review'
  assert_success
  assert_acli_argv 'project = BIXB AND assignee = currentUser() AND sprint in openSprints() AND status in ("Ready for Release", "In QA Review") ORDER BY created ASC' --paginate
}

@test "jira-sprint-tickets: status values with quotes/backslashes are escaped" {
  run --separate-stderr "$SCRIPT" --project BIXB --status 'Odd "name" \ here'
  assert_success
  assert_acli_argv 'project = BIXB AND assignee = currentUser() AND sprint in openSprints() AND status in ("Odd \"name\" \\ here") ORDER BY created ASC' --paginate
}

@test "jira-sprint-tickets: numeric sprint ID becomes sprint = N" {
  run --separate-stderr "$SCRIPT" --project BIXB --sprint 4521
  assert_success
  assert_acli_argv 'project = BIXB AND assignee = currentUser() AND sprint = 4521 ORDER BY created ASC' --paginate
}

@test "jira-sprint-tickets: explicit --sprint open uses openSprints()" {
  run --separate-stderr "$SCRIPT" --project BIXB --sprint open
  assert_success
  assert_acli_argv "$DEFAULT_JQL" --paginate
}

# --- limit vs paginate --------------------------------------------------------

@test "jira-sprint-tickets: --limit passes --limit N (no --paginate) and sets limited:true" {
  ACLI_SEARCH_OUT='[{"key":"BIXB-1","fields":{"summary":"s","status":{"name":"Ready to Test"},"issuetype":{"name":"Task"}}}]' \
    run --separate-stderr "$SCRIPT" --project BIXB --limit 3
  assert_success
  assert_acli_argv "$DEFAULT_JQL" --limit 3
  assert_single_json_doc
  assert_equal "$(jq -c '[.count, .limited]' <<<"$output")" '[1,true]'
}

# --- usage validation (exit 2, before any search, empty stdout) ---------------

# assert_usage_error <args...> — run the script and require exit 2, empty
# stdout, a usage message on stderr, and no acli search call.
assert_usage_error() {
  rm -f "$ARGV_FILE"
  run --separate-stderr "$SCRIPT" "$@"
  [[ "$status" -eq 2 ]] || fail "expected exit 2 for args [$*], got $status (stderr: $stderr)"
  [[ -z "$output" ]] || fail "expected empty stdout for args [$*], got: $output"
  [[ "$stderr" == *"Usage error"* ]] || fail "expected usage error on stderr for args [$*], got: $stderr"
  assert_no_search
}

@test "jira-sprint-tickets: --project is required" {
  assert_usage_error
  assert_usage_error --assignee 'currentUser()'
}

@test "jira-sprint-tickets: unknown flags and positional args are rejected" {
  assert_usage_error --project BIXB --bogus
  assert_usage_error --project BIXB extra
}

@test "jira-sprint-tickets: injection-shaped or malformed project keys are rejected" {
  assert_usage_error --project 'BIXB OR project = SECRET'
  assert_usage_error --project 'bixb'
  assert_usage_error --project 'B'
  assert_usage_error --project '1BIXB'
  assert_usage_error --project 'BIXB-1'
  assert_usage_error --project 'BIXB)'
}

@test "jira-sprint-tickets: injection-shaped or malformed sprints are rejected" {
  assert_usage_error --project BIXB --sprint '1 OR 1=1'
  assert_usage_error --project BIXB --sprint 'openSprints()'
  assert_usage_error --project BIXB --sprint 'OPEN'
  assert_usage_error --project BIXB --sprint '-5'
  assert_usage_error --project BIXB --sprint '0'
}

@test "jira-sprint-tickets: missing or empty option values are rejected" {
  assert_usage_error --project
  assert_usage_error --project ''
  assert_usage_error --project BIXB --assignee
  assert_usage_error --project BIXB --assignee ''
  assert_usage_error --project BIXB --sprint ''
  assert_usage_error --project BIXB --status ''
  assert_usage_error --project BIXB --status
  assert_usage_error --project BIXB --limit
  assert_usage_error --project BIXB --limit ''
}

@test "jira-sprint-tickets: non-positive or non-integer limits are rejected" {
  assert_usage_error --project BIXB --limit 0
  assert_usage_error --project BIXB --limit -1
  assert_usage_error --project BIXB --limit abc
  assert_usage_error --project BIXB --limit 1.5
  assert_usage_error --project BIXB --limit ' 3'
}

@test "jira-sprint-tickets: control characters in values are rejected" {
  assert_usage_error --project BIXB --assignee $'a@b.com\nOR 1=1'
  assert_usage_error --project BIXB --status $'Ready\tfor Release'
  assert_usage_error --project BIXB --status $'x\x7f'
}

# assert_control_char_error <args...> — usage error whose diagnostic is the
# control-character rejection, not the empty-value one. A value stripped of its
# newline would hit the empty-value or format checks instead.
assert_control_char_error() {
  assert_usage_error "$@"
  [[ "$stderr" == *"must not contain control characters"* ]] ||
    fail "expected control-character diagnostic for args [$*], got: $stderr"
  [[ "$stderr" != *"requires a non-empty value"* ]] ||
    fail "value was treated as empty (newline stripped?) for args [$*]: $stderr"
}

@test "jira-sprint-tickets: trailing newline in assignee is rejected, not stripped" {
  assert_control_char_error --project BIXB --assignee $'a@b.com\n'
}

@test "jira-sprint-tickets: newline-only status is rejected, not stripped" {
  assert_control_char_error --project BIXB --status $'\n'
}

# --- upstream output handling -------------------------------------------------

# assert_upstream_error — require exit 5, empty stdout, and an upstream message.
assert_upstream_error() {
  [[ "$status" -eq 5 ]] || fail "expected exit 5, got $status (stdout: $output; stderr: $stderr)"
  [[ -z "$output" ]] || fail "expected empty stdout on upstream error, got: $output"
  [[ "$stderr" == *"Upstream failure"* ]] || fail "expected 'Upstream failure' on stderr, got: $stderr"
}

@test "jira-sprint-tickets: valid empty array yields an empty envelope" {
  ACLI_SEARCH_OUT='[]' run --separate-stderr "$SCRIPT" --project BIXB --limit 5
  assert_success
  assert_single_json_doc
  assert_equal "$(jq -cS . <<<"$output")" \
    "$(jq -cnS --arg jql "$DEFAULT_JQL" '{version:1, jql:$jql, count:0, limited:true, tickets:[]}')"
}

@test "jira-sprint-tickets: acli search failure exits 5 with upstream stderr, not upstream rc" {
  ACLI_SEARCH_RC=42 ACLI_SEARCH_ERR='JQL error: field does not exist' ACLI_SEARCH_OUT='' \
    run --separate-stderr "$SCRIPT" --project BIXB
  assert_upstream_error
  [[ "$stderr" == *"JQL error: field does not exist"* ]] || fail "upstream stderr not preserved: $stderr"
}

@test "jira-sprint-tickets: empty acli stdout exits 5" {
  ACLI_SEARCH_OUT='' run --separate-stderr "$SCRIPT" --project BIXB
  assert_upstream_error
}

@test "jira-sprint-tickets: malformed JSON exits 5" {
  ACLI_SEARCH_OUT='[{"key":"BIXB-1",' run --separate-stderr "$SCRIPT" --project BIXB
  assert_upstream_error
}

@test "jira-sprint-tickets: object envelope instead of array exits 5" {
  ACLI_SEARCH_OUT='{"issues":[{"key":"BIXB-1"}],"total":1}' run --separate-stderr "$SCRIPT" --project BIXB
  assert_upstream_error
}

@test "jira-sprint-tickets: array of non-objects exits 5" {
  ACLI_SEARCH_OUT='["BIXB-1","BIXB-2"]' run --separate-stderr "$SCRIPT" --project BIXB
  assert_upstream_error
}

@test "jira-sprint-tickets: multiple JSON documents from acli exit 5" {
  ACLI_SEARCH_OUT='[] []' run --separate-stderr "$SCRIPT" --project BIXB
  assert_upstream_error
}

@test "jira-sprint-tickets: non-JSON text with rc 0 exits 5" {
  ACLI_SEARCH_OUT='No work items found.' run --separate-stderr "$SCRIPT" --project BIXB
  assert_upstream_error
}

# --- preflight ----------------------------------------------------------------

# run_with_only <cmd...> — run the script with PATH restricted to a dir holding
# only the named commands (symlinks to the stub or real binaries) plus dirname,
# which the script needs to source lib/common.sh.
run_with_only() {
  local minbin="$BATS_TEST_TMPDIR/minbin" bash_bin cmd src
  bash_bin="$(type -P bash)"
  mkdir -p "$minbin"
  for cmd in dirname "$@"; do
    src="$(type -P "$cmd")" || fail "test setup: $cmd not found"
    ln -sf "$src" "$minbin/$cmd"
  done
  run --separate-stderr env PATH="$minbin" "$bash_bin" "$SCRIPT" --project BIXB
}

@test "jira-sprint-tickets: missing acli exits 3 before searching" {
  run_with_only jq
  assert_equal "$status" 3
  assert_equal "$output" ""
  [[ "$stderr" == *"Missing dependency"*"acli"* ]] || fail "stderr: $stderr"
  assert_no_search
}

@test "jira-sprint-tickets: missing jq exits 3 before searching" {
  run_with_only acli
  assert_equal "$status" 3
  assert_equal "$output" ""
  [[ "$stderr" == *"Missing dependency"*"jq"* ]] || fail "stderr: $stderr"
  assert_no_search
}

@test "jira-sprint-tickets: failed acli auth preflight exits 4 before searching" {
  ACLI_AUTH_RC=1 run --separate-stderr "$SCRIPT" --project BIXB
  assert_equal "$status" 4
  assert_equal "$output" ""
  [[ "$stderr" == *"acli auth login"* ]] || fail "stderr: $stderr"
  assert_no_search
}
