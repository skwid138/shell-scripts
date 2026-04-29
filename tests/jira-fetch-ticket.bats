#!/usr/bin/env bats
# CLI tests for agent/jira-fetch-ticket.sh.
# Stubs `acli` so no Atlassian network call is made.

setup() {
  load 'test_helper/bats-support/load'
  load 'test_helper/bats-assert/load'
  SCRIPT="$BATS_TEST_DIRNAME/../agent/jira-fetch-ticket.sh"

  STUBDIR="$(mktemp -d)"
  export PATH="$STUBDIR:$PATH"
}

teardown() {
  [[ -d "$STUBDIR" ]] && rm -rf "$STUBDIR"
}

# Stub `acli` that simulates a healthy authed Jira CLI returning canned data.
write_acli_stub() {
  cat >"$STUBDIR/acli" <<'EOF'
#!/usr/bin/env bash
# Args: jira workitem <view|comment|link|attachment> ...
case "$1 $2" in
  "auth status") exit 0 ;;
  "jira workitem")
    case "$3" in
      view)
        # Plain text or JSON?
        if printf '%s\n' "$@" | grep -q -- '--json'; then
          echo '{"key":"BIXB-1","fields":{"summary":"hi"}}'
        else
          cat <<'TXT'
Key: BIXB-1
Summary: hi

Description:
The body text.
More.
TXT
        fi
        ;;
      comment)
        echo '{"comments":[{"id":"1","body":"first"}],"isLast":true,"maxResults":50,"startAt":0,"total":1}'
        ;;
      link)
        echo '{"links":[],"isLast":true,"maxResults":50,"startAt":0,"total":0}'
        ;;
      attachment)
        echo '{"attachments":[],"isLast":true,"maxResults":50,"startAt":0,"total":0}'
        ;;
      *) echo "stub acli: unhandled: $*" >&2; exit 99 ;;
    esac
    ;;
  *) echo "stub acli: unhandled: $*" >&2; exit 99 ;;
esac
EOF
  chmod +x "$STUBDIR/acli"
}

# Helper: extract only the JSON object from script output (info() prints
# decorative status to stderr, which bats merges with stdout by default).
get_json() {
  printf '%s\n' "$output" | awk '/^\{/,/^\}$/'
}

# --- --help -------------------------------------------------------------------

@test "jira-fetch-ticket: --help exits 0 and prints usage" {
  run "$SCRIPT" --help
  assert_success
  assert_output --partial "Usage: jira-fetch-ticket"
  assert_output --partial "TICKET-ID"
}

@test "jira-fetch-ticket: -h exits 0 and prints usage" {
  run "$SCRIPT" -h
  assert_success
  assert_output --partial "Usage: jira-fetch-ticket"
}

# --- ticket-id parsing --------------------------------------------------------

@test "jira-fetch-ticket: missing ticket-id exits with friendly error" {
  write_acli_stub
  run "$SCRIPT"
  assert_failure
  assert_output --partial "TICKET-ID is required"
}

@test "jira-fetch-ticket: lowercase ticket-id is uppercased" {
  write_acli_stub
  run "$SCRIPT" bixb-1
  assert_success
  get_json | jq -e '.ticket_id == "BIXB-1"' >/dev/null
}

@test "jira-fetch-ticket: Atlassian URL extracts ticket-id" {
  write_acli_stub
  run "$SCRIPT" "https://wpromote.atlassian.net/browse/BIXB-1"
  assert_success
  get_json | jq -e '.ticket_id == "BIXB-1"' >/dev/null
}

@test "jira-fetch-ticket: malformed URL fails with clear error" {
  write_acli_stub
  run "$SCRIPT" "https://example.com/not-jira"
  assert_failure
  assert_output --partial "Cannot parse ticket ID"
}

# --- output assembly ----------------------------------------------------------

@test "jira-fetch-ticket: bare ticket-id outputs valid JSON skeleton" {
  write_acli_stub
  run "$SCRIPT" BIXB-1
  assert_success
  get_json | jq -e '
    .ticket_id == "BIXB-1" and
    (.plain_view | type) == "string" and
    (.description | type) == "string" and
    .comments == [] and
    .links == [] and
    .attachments == []
  ' >/dev/null
}

@test "jira-fetch-ticket: --comments populates comments envelope" {
  write_acli_stub
  run "$SCRIPT" --comments BIXB-1
  assert_success
  get_json | jq -e '
    .comments.total == 1 and
    .comments.isLast == true and
    .comments.comments[0].id == "1"
  ' >/dev/null
}

@test "jira-fetch-ticket: --all populates comments, links, attachments" {
  write_acli_stub
  run "$SCRIPT" --all BIXB-1
  assert_success
  get_json | jq -e '
    (.comments.total // 0) >= 0 and
    (.links | type) == "object" and
    (.attachments | type) == "object"
  ' >/dev/null
}

@test "jira-fetch-ticket: description is extracted from plain view" {
  write_acli_stub
  run "$SCRIPT" BIXB-1
  assert_success
  get_json | jq -re '.description' | grep -q "The body text"
}

# --- preflight ----------------------------------------------------------------
# Note: missing-dep / unauthed paths are exercised against require_cmd /
# require_auth directly in tests/common.bats; not re-tested per-script.
