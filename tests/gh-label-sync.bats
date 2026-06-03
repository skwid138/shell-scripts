#!/usr/bin/env bats
# CLI / behavior tests for agent/gh-label-sync.sh.
# Stubs `gh` and `yq` so no network calls happen.

setup() {
  load 'test_helper/bats-support/load'
  load 'test_helper/bats-assert/load'
  SCRIPT="$BATS_TEST_DIRNAME/../agent/gh-label-sync.sh"

  STUBDIR="$BATS_TEST_TMPDIR/bin"
  mkdir -p "$STUBDIR"
  export PATH="$STUBDIR:$PATH"
  export GH_STUB_CALLS="$BATS_TEST_TMPDIR/gh-calls.log"
  : >"$GH_STUB_CALLS"
  write_yq_stub
  write_gh_stub
  write_manifest
}

get_json() { printf '%s\n' "$output" | awk '/^\{/,/^\}$/'; }

assert_no_mutation() {
  if grep -q '^MUTATE ' "$GH_STUB_CALLS"; then
    printf 'unexpected mutation:\n' >&2
    cat "$GH_STUB_CALLS" >&2
    return 1
  fi
}

tmpdir_entry_count() {
  find "$BATS_TEST_TMPDIR" -mindepth 1 -maxdepth 1 -print | wc -l | tr -d ' '
}

write_manifest() {
  export GH_LABEL_SYNC_MANIFEST="$BATS_TEST_TMPDIR/github-labels.json"
  cat >"$GH_LABEL_SYNC_MANIFEST" <<'JSON'
{
  "axes": {
    "type": [
      {"name":"type/bug","color":"#d73a4a","description":"Something is not working as expected."},
      {"name":"type/feature","color":"#a2eeef","description":"New feature or capability request."},
      {"name":"type/docs","color":"#0075ca","description":"Documentation change or improvement."},
      {"name":"type/maintenance","color":"#fef2c0","description":"Chore, refactor, dependency, or repository maintenance."},
      {"name":"type/security","color":"#d73a4a","description":"Security vulnerability or hardening work."},
      {"name":"type/question","color":"#d4c5f9","description":"Question or discussion item needing an answer."}
    ],
    "status": [
      {"name":"status/needs-triage","color":"#ededed","description":"Needs initial review and classification."},
      {"name":"status/needs-info","color":"#d455d0","description":"Waiting for more information from the reporter."},
      {"name":"status/accepted","color":"#8fc951","description":"Accepted and ready to be worked."},
      {"name":"status/blocked","color":"#d73a4a","description":"Blocked by an external dependency or decision."},
      {"name":"status/in-progress","color":"#fbca04","description":"Work has started."}
    ],
    "priority": [
      {"name":"priority/critical","color":"#b60205","description":"Urgent; address as soon as possible."},
      {"name":"priority/high","color":"#d93f0b","description":"Important; prioritize soon."},
      {"name":"priority/normal","color":"#fbca04","description":"Normal priority."},
      {"name":"priority/backlog","color":"#c2e0c6","description":"Valid but not currently prioritized."}
    ],
    "effort": [
      {"name":"effort/small","color":"#91ca55","description":"Small, well-contained change."},
      {"name":"effort/medium","color":"#fef2c0","description":"Moderate implementation effort."},
      {"name":"effort/large","color":"#fbca04","description":"Large or uncertain implementation effort."}
    ],
    "community": [
      {"name":"community/good-first-issue","color":"#7057ff","description":"Good issue for a first-time contributor."},
      {"name":"community/help-wanted","color":"#008672","description":"Extra attention or outside contribution welcome."}
    ],
    "resolution": [
      {"name":"resolution/duplicate","color":"#cfd3d7","description":"Duplicate of another issue or pull request."},
      {"name":"resolution/declined","color":"#cfd3d7","description":"Declined or will not be implemented."}
    ]
  },
  "migrations": [
    {"old":"bug","new":"type/bug"},
    {"old":"documentation","new":"type/docs"},
    {"old":"enhancement","new":"type/feature"},
    {"old":"duplicate","new":"resolution/duplicate"},
    {"old":"wontfix","new":"resolution/declined"},
    {"old":"question","new":"type/question"},
    {"old":"good first issue","new":"community/good-first-issue"},
    {"old":"help wanted","new":"community/help-wanted"}
  ],
  "keep": ["dependencies", "github_actions", "javascript", "released"],
  "delete": ["invalid"]
}
JSON
}

write_yq_stub() {
  cat >"$STUBDIR/yq" <<'EOF'
#!/usr/bin/env bash
if [[ "$1" == "--version" ]]; then
  echo "yq (https://github.com/mikefarah/yq/) version v4.45.1"
  exit 0
fi
if [[ "$1" == "eval" && "$2" == "-o=json" ]]; then
  jq '.' "$3"
  exit $?
fi
echo "stub yq: unhandled: $*" >&2
exit 99
EOF
  chmod +x "$STUBDIR/yq"
}

write_gh_stub() {
  cat >"$STUBDIR/gh" <<'EOF'
#!/usr/bin/env bash
printf '%s\n' "$*" >>"$GH_STUB_CALLS"
case "$1" in
  auth)
    [[ "$2" == "status" ]] && exit 0
    ;;
  label)
    case "$2" in
      list)
        repo=""
        limit=""
        while [[ $# -gt 0 ]]; do
          case "$1" in
            -R) repo="$2"; shift 2 ;;
            --limit) limit="$2"; shift 2 ;;
            *) shift ;;
          esac
        done
        [[ "$limit" == "1000" ]] || { echo "missing --limit 1000" >&2; exit 98; }
        if [[ -n "${GH_FAIL_LIST_REPO:-}" && "$repo" == "$GH_FAIL_LIST_REPO" ]]; then
          echo "list failed for $repo" >&2
          exit 44
        fi
        if [[ -n "${GH_LABEL_LIST_STDERR:-}" ]]; then
          echo "$GH_LABEL_LIST_STDERR" >&2
        fi
        if [[ -n "${GH_LABEL_LIST_JSON_BY_REPO:-}" ]]; then
          jq -r --arg repo "$repo" '.[$repo]' "$GH_LABEL_LIST_JSON_BY_REPO"
        else
          printf '%s\n' "${GH_LABEL_LIST_JSON:-[]}"
        fi
        exit 0
        ;;
      create | edit | delete)
        printf 'MUTATE %s\n' "$*" >>"$GH_STUB_CALLS"
        if [[ "${GH_ALLOW_MUTATIONS:-0}" != "1" ]]; then
          echo "unexpected mutation: $*" >&2
          exit 66
        fi
        if [[ -n "${GH_FAIL_MUTATION_MATCH:-}" && "$*" == *"$GH_FAIL_MUTATION_MATCH"* ]]; then
          echo "forced mutation failure: $*" >&2
          exit 67
        fi
        exit 0
        ;;
    esac
    ;;
  api)
    if [[ "$*" == *"hasDiscussionsEnabled"* ]]; then
      if [[ -n "${GH_DISCUSSIONS_JSON:-}" ]]; then
        printf '%s\n' "$GH_DISCUSSIONS_JSON"
      else
        printf '%s\n' '{"data":{"repository":{"hasDiscussionsEnabled":false}}}'
      fi
      exit 0
    fi
    if [[ "$*" == *"label(name"* ]]; then
      if [[ -n "${GH_LABEL_COUNTS_JSON:-}" ]]; then
        printf '%s\n' "$GH_LABEL_COUNTS_JSON"
      else
        printf '%s\n' '{"data":{"repository":{"label":{"issues":{"totalCount":0},"pullRequests":{"totalCount":0}}}}}'
      fi
      exit 0
    fi
    ;;
esac
echo "stub gh: unhandled: $*" >&2
exit 99
EOF
  chmod +x "$STUBDIR/gh"
}

@test "gh-label-sync: --help exits 0 and prints usage" {
  run "$SCRIPT" --help
  assert_success
  assert_output --partial "Usage: gh-label-sync"
}

@test "gh-label-sync: --help produces no filesystem side effects" {
  export TMPDIR="$BATS_TEST_TMPDIR"
  before_count="$(tmpdir_entry_count)"

  run "$SCRIPT" --help

  assert_success
  after_count="$(tmpdir_entry_count)"
  [[ "$after_count" == "$before_count" ]]
}

@test "gh-label-sync: owner guardrail rejects malformed and non-skwid138 slugs before gh calls" {
  bad_slugs=(
    "https://github.com/skwid138/repo"
    "skwid138/repo.git"
    "skwid138/repo/"
    "skwid138/repo/issues"
    "skwid138/bad repo"
    ""
    "wpromote/polaris-web"
  )

  for slug in "${bad_slugs[@]}"; do
    : >"$GH_STUB_CALLS"
    run "$SCRIPT" "$slug"
    assert_failure 2
    [[ ! -s "$GH_STUB_CALLS" ]]
  done
}

@test "gh-label-sync: dry-run plans convergence without mutating GitHub" {
  export GH_LABEL_LIST_JSON='[
    {"name":"invalid","color":"ededed","description":"old invalid"},
    {"name":"bug","color":"d73a4a","description":"legacy bug"},
    {"name":"type/feature","color":"ffffff","description":"wrong"},
    {"name":"duplicate","color":"cfd3d7","description":"legacy duplicate"},
    {"name":"resolution/duplicate","color":"000000","description":"wrong"},
    {"name":"random","color":"123456","description":"untouched"},
    {"name":"dependencies","color":"0366d6","description":"tooling"}
  ]'

  run "$SCRIPT" skwid138/demo
  assert_success
  assert_no_mutation
  get_json | jq -e '
    .version == 1 and
    (.repos[0].actions[] | select(.label == "invalid" and .action == "would-delete")) and
    (.repos[0].actions[] | select(.action == "rename" and .from == "bug" and .to == "type/bug" and .applied == false)) and
    (.repos[0].actions[] | select(.action == "collision" and .from == "duplicate" and .to == "resolution/duplicate")) and
    (.repos[0].actions[] | select(.label == "type/feature" and .action == "edit" and .applied == false)) and
    (.repos[0].actions[] | select(.label == "status/needs-triage" and .action == "create" and .applied == false)) and
    ([.repos[0].actions[] | select(.label == "random")] | length == 0)
  ' >/dev/null
}

@test "gh-label-sync: --apply mutates only after validation and marks applied actions" {
  export GH_ALLOW_MUTATIONS=1
  export GH_LABEL_LIST_JSON='[
    {"name":"invalid","color":"ededed","description":"old invalid"},
    {"name":"bug","color":"d73a4a","description":"legacy bug"},
    {"name":"type/feature","color":"ffffff","description":"wrong"}
  ]'

  run "$SCRIPT" --apply skwid138/demo
  assert_success
  grep -q '^MUTATE label delete invalid -R skwid138/demo --yes$' "$GH_STUB_CALLS"
  grep -q '^MUTATE label edit bug -R skwid138/demo --name type/bug --color d73a4a' "$GH_STUB_CALLS"
  grep -q '^MUTATE label edit type/feature -R skwid138/demo --name type/feature --color a2eeef' "$GH_STUB_CALLS"
  grep -q '^MUTATE label create status/needs-triage -R skwid138/demo --color ededed' "$GH_STUB_CALLS"
  get_json | jq -e '
    (.repos[0].actions[] | select(.label == "invalid" and .action == "delete" and .applied == true)) and
    (.repos[0].actions[] | select(.action == "rename" and .to == "type/bug" and .applied == true)) and
    (.repos[0].actions[] | select(.label == "type/feature" and .action == "edit" and .applied == true))
  ' >/dev/null
}

@test "gh-label-sync: already-converged partial state is idempotent and color comparison is normalized" {
  export GH_LABEL_LIST_JSON='[
    {"name":"type/bug","color":"D73A4A","description":"Something is not working as expected."},
    {"name":"type/feature","color":"a2eeef","description":"New feature or capability request."}
  ]'

  run "$SCRIPT" skwid138/demo
  assert_success
  assert_no_mutation
  get_json | jq -e '
    (.repos[0].actions[] | select(.label == "type/bug" and .action == "skip" and .reason == "desired label already correct")) and
    ([.repos[0].actions[] | select(.label == "type/bug" and .action == "edit")] | length == 0)
  ' >/dev/null
}

@test "gh-label-sync: discussions-enabled repos block delete even with zero issue and PR associations" {
  export GH_LABEL_LIST_JSON='[{"name":"invalid","color":"ededed","description":"old invalid"}]'
  export GH_DISCUSSIONS_JSON='{"data":{"repository":{"hasDiscussionsEnabled":true}}}'

  run "$SCRIPT" skwid138/demo
  assert_success
  assert_no_mutation
  get_json | jq -e '.repos[0].actions[] | select(.label == "invalid" and .action == "delete-blocked")' >/dev/null
}

@test "gh-label-sync: requests up to 1000 labels so repos with more than default 30 are not truncated" {
  GH_LABEL_LIST_JSON="$(jq -n '[range(0;31) | {name:("other-" + tostring), color:"123456", description:""}]')"
  export GH_LABEL_LIST_JSON

  run "$SCRIPT" skwid138/many-labels
  assert_success
  grep -q 'label list -R skwid138/many-labels --json name,color,description --limit 1000' "$GH_STUB_CALLS"
}

@test "gh-label-sync: per-repo upstream failures are reported and later repos still run" {
  by_repo="$BATS_TEST_TMPDIR/by-repo.json"
  jq -n '{"skwid138/good": [], "skwid138/bad": []}' >"$by_repo"
  export GH_LABEL_LIST_JSON_BY_REPO="$by_repo"
  export GH_FAIL_LIST_REPO="skwid138/bad"

  run "$SCRIPT" skwid138/bad skwid138/good
  assert_failure 5
  get_json | jq -e '
    (.repos | length == 2) and
    (.repos[0].repo == "skwid138/bad") and (.repos[0].errors | length == 1) and
    (.repos[1].repo == "skwid138/good") and (.repos[1].errors | length == 0)
  ' >/dev/null
}

@test "gh-label-sync: successful label inventory ignores stderr warnings" {
  export GH_LABEL_LIST_STDERR="warning: preview field"
  export GH_LABEL_LIST_JSON='[]'

  run "$SCRIPT" skwid138/demo

  assert_success
  get_json | jq -e '
    (.repos[0].errors | length == 0) and
    (.repos[0].actions[] | select(.label == "type/bug" and .action == "create"))
  ' >/dev/null
}

@test "gh-label-sync: manifest migration targets must be desired labels" {
  export GH_LABEL_SYNC_MANIFEST="$BATS_TEST_TMPDIR/bad-migration-target.json"
  cat >"$GH_LABEL_SYNC_MANIFEST" <<'JSON'
{
  "axes": {
    "type": [
      {"name":"type/bug","color":"#d73a4a","description":"Something is not working as expected."}
    ]
  },
  "migrations": [
    {"old":"bug","new":"type/not-defined"}
  ],
  "keep": [],
  "delete": []
}
JSON

  run "$SCRIPT" skwid138/demo

  assert_failure 2
  assert_output --partial "manifest migration target 'type/not-defined' is not a defined desired label"
  assert_no_mutation
}

@test "gh-label-sync: manifest keep and delete entries must be strings" {
  export GH_LABEL_SYNC_MANIFEST="$BATS_TEST_TMPDIR/bad-keep-delete.json"
  cat >"$GH_LABEL_SYNC_MANIFEST" <<'JSON'
{
  "axes": {},
  "migrations": [],
  "keep": [123],
  "delete": []
}
JSON

  run "$SCRIPT" skwid138/demo

  assert_failure 2
  assert_output --partial "manifest keep and delete entries must be strings"
  assert_no_mutation
}

@test "gh-label-sync: non-array label inventory reports repo error and skips planning" {
  export GH_LABEL_LIST_JSON='{}'

  run "$SCRIPT" skwid138/demo

  assert_failure 5
  assert_no_mutation
  get_json | jq -e '
    (.repos[0].errors[] == "gh label list returned unexpected non-array output") and
    (.repos[0].actions | length == 0)
  ' >/dev/null
}

@test "gh-label-sync: GraphQL errors on discussions query block delete" {
  export GH_LABEL_SYNC_MANIFEST="$BATS_TEST_TMPDIR/delete-only.json"
  cat >"$GH_LABEL_SYNC_MANIFEST" <<'JSON'
{
  "axes": {},
  "migrations": [],
  "keep": [],
  "delete": ["invalid"]
}
JSON
  export GH_LABEL_LIST_JSON='[{"name":"invalid","color":"ededed","description":"old invalid"}]'
  export GH_DISCUSSIONS_JSON='{"data":{"repository":{"hasDiscussionsEnabled":false}},"errors":[{"message":"x"}]}'

  run "$SCRIPT" --apply skwid138/demo

  assert_success
  assert_no_mutation
  get_json | jq -e '
    .repos[0].actions[] |
    select(.label == "invalid" and .action == "delete-blocked" and (.reason | contains("GraphQL returned errors")))
  ' >/dev/null
}

@test "gh-label-sync: non-object GraphQL discussions response blocks delete" {
  export GH_LABEL_SYNC_MANIFEST="$BATS_TEST_TMPDIR/delete-only.json"
  cat >"$GH_LABEL_SYNC_MANIFEST" <<'JSON'
{
  "axes": {},
  "migrations": [],
  "keep": [],
  "delete": ["invalid"]
}
JSON
  export GH_LABEL_LIST_JSON='[{"name":"invalid","color":"ededed","description":"old invalid"}]'
  export GH_DISCUSSIONS_JSON='[]'

  run "$SCRIPT" --apply skwid138/demo

  assert_success
  assert_no_mutation
  get_json | jq -e '
    .repos[0].actions[] |
    select(.label == "invalid" and .action == "delete-blocked" and (.reason | contains("GraphQL returned errors")))
  ' >/dev/null
}

@test "gh-label-sync: GraphQL errors on association counts query block delete" {
  export GH_LABEL_SYNC_MANIFEST="$BATS_TEST_TMPDIR/delete-only.json"
  cat >"$GH_LABEL_SYNC_MANIFEST" <<'JSON'
{
  "axes": {},
  "migrations": [],
  "keep": [],
  "delete": ["invalid"]
}
JSON
  export GH_LABEL_LIST_JSON='[{"name":"invalid","color":"ededed","description":"old invalid"}]'
  export GH_LABEL_COUNTS_JSON='{"data":{"repository":{"label":{"issues":{"totalCount":0},"pullRequests":{"totalCount":0}}}},"errors":[{"message":"x"}]}'

  run "$SCRIPT" --apply skwid138/demo

  assert_success
  assert_no_mutation
  get_json | jq -e '
    .repos[0].actions[] |
    select(.label == "invalid" and .action == "delete-blocked" and (.reason | contains("GraphQL returned errors")))
  ' >/dev/null
}

@test "gh-label-sync: apply mutation failure is captured and remaining actions continue" {
  export GH_ALLOW_MUTATIONS=1
  export GH_FAIL_MUTATION_MATCH="type/feature"
  export GH_LABEL_LIST_JSON='[
    {"name":"type/feature","color":"ffffff","description":"wrong"}
  ]'

  run "$SCRIPT" --apply skwid138/demo
  assert_failure 5
  grep -q '^MUTATE label edit type/feature' "$GH_STUB_CALLS"
  grep -q '^MUTATE label create status/needs-triage' "$GH_STUB_CALLS"
  get_json | jq -e '
    (.repos[0].errors | length == 1) and
    (.repos[0].actions[] | select(.label == "type/feature" and .action == "edit" and .applied == false)) and
    (.repos[0].actions[] | select(.label == "status/needs-triage" and .action == "create" and .applied == true))
  ' >/dev/null
}

@test "gh-label-sync: discussions disabled but nonzero associations block delete" {
  export GH_LABEL_SYNC_MANIFEST="$BATS_TEST_TMPDIR/delete-only.json"
  cat >"$GH_LABEL_SYNC_MANIFEST" <<'JSON'
{
  "axes": {},
  "migrations": [],
  "keep": [],
  "delete": ["invalid"]
}
JSON
  export GH_LABEL_LIST_JSON='[{"name":"invalid","color":"ededed","description":"old invalid"}]'
  export GH_LABEL_COUNTS_JSON='{"data":{"repository":{"label":{"issues":{"totalCount":3},"pullRequests":{"totalCount":0}}}}}'

  run "$SCRIPT" --apply skwid138/demo

  assert_success
  assert_no_mutation
  get_json | jq -e '
    .repos[0].actions[] |
    select(.label == "invalid" and .action == "delete-blocked" and (.reason | contains("nonzero or unknown associations")))
  ' >/dev/null
}
