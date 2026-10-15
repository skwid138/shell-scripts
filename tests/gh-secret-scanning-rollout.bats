#!/usr/bin/env bats
bats_require_minimum_version 1.5.0
# Tests for personal/gh-secret-scanning-rollout.sh (enable secret scanning +
# push protection on an owner's PUBLIC repos where either is disabled).
#
# Every run is under `env -i` with HOME and TMPDIR inside the test temp dir, a
# fake `gh` (GH_ROLLOUT_GH) that keeps per-repo state in fixture files and can
# be told to fail specific requests (fault queues), and a fake sleep
# (GH_ROLLOUT_SLEEP) that only records how long the script asked to wait. No
# test touches real GitHub or the real ~/Library state.
#
# macOS-only (BSD ls/chmod -N for the private journal, ~/Library state).

setup() {
  load 'test_helper/bats-support/load'
  load 'test_helper/bats-assert/load'

  [[ "$(uname -s)" == "Darwin" ]] || skip "gh-secret-scanning-rollout is macOS-only (chmod -N, ~/Library state)"

  SCRIPT="$BATS_TEST_DIRNAME/../personal/gh-secret-scanning-rollout.sh"
  T="$BATS_TEST_TMPDIR"
  FAKE_HOME="$T/home"
  BIN="$T/bin"
  FIX="$T/fix"
  TMPD="$T/tmp"
  CALLS="$T/calls.log"
  OWNER="synth-owner"
  STATE="$FAKE_HOME/Library/Application Support/gh-security-rollout"
  mkdir -p "$FAKE_HOME" "$BIN" "$FIX/repo" "$FIX/fault" "$FIX/patches" "$TMPD"
  : >"$CALLS"
  : >"$FIX/list.jsonl"

  REAL_JQ="$(type -P jq)"
  [[ "$REAL_JQ" == /* ]] || skip "no jq on PATH"
  ln -s "$REAL_JQ" "$BIN/jq"
  HTTP_TIMEOUT=2
  write_fake_gh
  write_fake_sleep
}

teardown() {
  /bin/chmod -RN "$BATS_TEST_TMPDIR" 2>/dev/null
  /bin/chmod -R u+rwx "$BATS_TEST_TMPDIR" 2>/dev/null
  return 0
}

# --- fakes -----------------------------------------------------------------------

# The fake gh only speaks `gh api -i [-X M] [-H h] <path> [--input f]` and
# prints an HTTP status line, CRLF headers, a blank line and the body, exiting
# 1 on non-2xx like the real gh. State:
#   fix/list.jsonl        owned-repo list, served 2 per page with a Link header
#   fix/repo/<n>.json     the per-repo GET body (PATCH merges into it)
#   fix/fault/<key>       queue of one-shot faults, one per line; keys:
#                         USER, LIST.<page>, GET.<n>, PATCH.<n>
#   fix/patches/<n>.<k>.json  every PATCH body received
write_fake_gh() {
  cat >"$T/gh" <<EOF
#!/bin/bash
FIX="$FIX"
CALLS="$CALLS"
OWNER="$OWNER"
EOF
  cat >>"$T/gh" <<'EOF'
[[ "${1-}" == api ]] || exit 2
shift
method=GET input="" path=""
while [[ $# -gt 0 ]]; do
  case "$1" in
    -i | --include) shift ;;
    -X | --method) method="$2"; shift 2 ;;
    --input) input="$2"; shift 2 ;;
    -H | --header) shift 2 ;;
    -*) echo "fake gh: unexpected flag $1" >&2; exit 2 ;;
    *) path="$1"; shift ;;
  esac
done
printf '%s %s\n' "$method" "$path" >>"$CALLS"

hdrs=()
reply() { # <code> <reason> <body>
  local h
  printf 'HTTP/2.0 %s %s\n' "$1" "$2"
  printf 'X-Fake: 1\r\n'
  for h in ${hdrs[@]+"${hdrs[@]}"}; do printf '%s\r\n' "$h"; done
  printf '\r\n%s' "$3"
  case "$1" in
    2??) exit 0 ;;
    *) printf 'gh: %s (HTTP %s)\n' "$2" "$1" >&2; exit 1 ;;
  esac
}

pop() {
  local f="$FIX/fault/$1"
  [[ -s "$f" ]] || return 1
  head -n1 "$f"
  tail -n +2 "$f" >"$f.tmp" && mv "$f.tmp" "$f"
}

fault() {
  case "$1" in
    "429 retry-after="*) hdrs+=("Retry-After: ${1#429 retry-after=}"); reply 429 "Too Many Requests" '{"message":"slow down"}' ;;
    "403 retry-after="*) hdrs+=("Retry-After: ${1#403 retry-after=}"); reply 403 Forbidden '{"message":"You have exceeded a secondary rate limit"}' ;;
    "403 reset=+"*)
      hdrs+=("X-RateLimit-Remaining: 0" "X-RateLimit-Reset: $(($(date +%s) + ${1#403 reset=+}))")
      reply 403 Forbidden '{"message":"API rate limit exceeded"}'
      ;;
    "403 secondary") hdrs+=("X-RateLimit-Remaining: 4000"); reply 403 Forbidden '{"message":"You have exceeded a secondary rate limit. Please wait a few minutes before you try again."}' ;;
    "429 bare") reply 429 "Too Many Requests" '{"message":"too many requests"}' ;;
    "403 plain") hdrs+=("X-RateLimit-Remaining: 4000"); reply 403 Forbidden '{"message":"Resource not accessible by personal access token"}' ;;
    422) reply 422 "Unprocessable Entity" '{"message":"Validation Failed"}' ;;
    404) reply 404 "Not Found" '{"message":"Not Found"}' ;;
    502) reply 502 "Bad Gateway" '{"message":"Server Error"}' ;;
    timeout) exec /bin/sleep 30 ;;
    *) echo "fake gh: unknown fault $1" >&2; exit 3 ;;
  esac
}

apply_patch() {
  jq --slurpfile p "$input" '.security_and_analysis = ((.security_and_analysis // {}) * $p[0].security_and_analysis)' "$st" >"$st.tmp" &&
    mv "$st.tmp" "$st"
}

case "$path" in
  user)
    f="$(pop USER)" && fault "$f"
    reply 200 OK "{\"login\":\"$OWNER\"}"
    ;;
  "user/repos?affiliation=owner&per_page=100&page="*)
    page="${path##*page=}"
    f="$(pop "LIST.$page")" && fault "$f"
    total="$(grep -c . "$FIX/list.jsonl")"
    start=$(((page - 1) * 2 + 1))
    body="$(tail -n +"$start" "$FIX/list.jsonl" | head -n 2 | jq -s -c .)"
    if [[ $((start + 1)) -lt "$total" ]]; then
      hdrs+=("Link: <https://api.github.com/${path%page=*}page=$((page + 1))>; rel=\"next\"")
    fi
    reply 200 OK "$body"
    ;;
  "repos/$OWNER/"*)
    name="${path#repos/"$OWNER"/}"
    st="$FIX/repo/$name.json"
    [[ -f "$st" ]] || reply 404 "Not Found" '{"message":"Not Found"}'
    if [[ "$method" == GET ]]; then
      if f="$(pop "GET.$name")"; then
        case "$f" in
          pass) ;;
          enable-now)
            jq '.security_and_analysis.secret_scanning.status = "enabled" | .security_and_analysis.secret_scanning_push_protection.status = "enabled"' "$st" >"$st.tmp" && mv "$st.tmp" "$st"
            ;;
          *) fault "$f" ;;
        esac
      fi
      reply 200 OK "$(cat "$st")"
    elif [[ "$method" == PATCH ]]; then
      k=1
      while [[ -e "$FIX/patches/$name.$k.json" ]]; do k=$((k + 1)); done
      cp "$input" "$FIX/patches/$name.$k.json"
      f="$(pop "PATCH.$name")"
      case "$f" in
        "") apply_patch; reply 200 OK "$(cat "$st")" ;;
        noop-200) reply 200 OK "$(cat "$st")" ;;
        502-applied) apply_patch; reply 502 "Bad Gateway" '{"message":"Server Error"}' ;;
        timeout-applied) apply_patch; exec /bin/sleep 30 ;;
        clobber)
          apply_patch
          jq '.security_and_analysis.dependabot_security_updates.status = "enabled"' "$st" >"$st.tmp" && mv "$st.tmp" "$st"
          reply 200 OK "$(cat "$st")"
          ;;
        add-key)
          apply_patch
          jq '.security_and_analysis.secret_scanning_validity_checks = {status: "disabled"}' "$st" >"$st.tmp" && mv "$st.tmp" "$st"
          reply 200 OK "$(cat "$st")"
          ;;
        *) fault "$f" ;;
      esac
    fi
    reply 405 "Method Not Allowed" '{}'
    ;;
esac
echo "fake gh: unexpected path $path" >&2
exit 2
EOF
  chmod +x "$T/gh"
}

write_fake_sleep() {
  cat >"$T/sleep" <<EOF
#!/bin/bash
printf 'sleep %s\n' "\$*" >>"$CALLS"
EOF
  chmod +x "$T/sleep"
}

# gh_repo <name> <id> <public|private> <ss> <pp> [archived] [fork] [owner]
#   ss/pp: enabled | disabled | missing (key absent) | null
#   ss = sanull: security_and_analysis is null; ss = samissing: key absent.
gh_repo() {
  local name="$1" id="$2" vis="$3" ss="$4" pp="$5" arch="${6:-false}" fork="${7:-false}" own="${8:-$OWNER}" priv=false sa
  [[ "$vis" == private ]] && priv=true
  jq -n -c --arg n "$name" --argjson id "$id" --arg v "$vis" --argjson p "$priv" --argjson f "$fork" \
    --argjson a "$arch" --arg o "$own" \
    '{name: $n, id: $id, visibility: $v, private: $p, fork: $f, archived: $a, owner: {login: $o}}' >>"$FIX/list.jsonl"
  [[ "$own" == "$OWNER" ]] || return 0
  sa="$(jq -n -c --arg ss "$ss" --arg pp "$pp" '
    def f(s): if s == "null" then null else {status: s} end;
    {secret_scanning_non_provider_patterns: {status: "disabled"}, dependabot_security_updates: {status: "disabled"}}
    + (if $ss == "missing" then {} else {secret_scanning: f($ss)} end)
    + (if $pp == "missing" then {} else {secret_scanning_push_protection: f($pp)} end)')"
  case "$ss" in
    sanull) sa=null ;;
    samissing) sa="" ;;
  esac
  jq -n --arg n "$name" --argjson id "$id" --arg v "$vis" --argjson p "$priv" --argjson f "$fork" \
    --argjson a "$arch" --arg o "$own" --arg sa "$sa" \
    '{name: $n, id: $id, visibility: $v, private: $p, fork: $f, archived: $a, owner: {login: $o}}
     + (if $sa == "" then {} else {security_and_analysis: ($sa | fromjson)} end)' >"$FIX/repo/$name.json"
}

# fault <key> <line...>: queue one-shot faults.
fault() {
  local key="$1"
  shift
  printf '%s\n' "$@" >>"$FIX/fault/$key"
}

run_rollout() {
  run --separate-stderr env -i HOME="$FAKE_HOME" TMPDIR="$TMPD" PATH="$BIN:/usr/bin:/bin:/usr/sbin:/sbin" \
    GH_ROLLOUT_GH="$T/gh" GH_ROLLOUT_SLEEP="$T/sleep" GH_ROLLOUT_HTTP_TIMEOUT="$HTTP_TIMEOUT" \
    /bin/bash "$SCRIPT" "$@" </dev/null
}

patch_count() { grep -c "^PATCH repos/$OWNER/$1\$" "$CALLS" || true; }
all_patches() { grep -c '^PATCH ' "$CALLS" || true; }
state_of() { jq -r ".security_and_analysis.$2.status" "$FIX/repo/$1.json"; }
journal() { find "$STATE" -maxdepth 1 -type f -name 'secret-scanning-*.tsv' | LC_ALL=C sort | tail -n1; }
# jlast <repo> <column>: that column of the repo's last journal row.
jlast() { awk -F'\t' -v n="$1" -v c="$2" '!/^#/ && $1 == n { v = $c } END { print v }' "$(journal)"; }
sleeps() { grep '^sleep ' "$CALLS" | cut -d' ' -f2; }

# ===================================================================================

@test "gh-secret-scanning-rollout: --help exits 0 and documents modes, journal and rollback" {
  run /bin/bash "$SCRIPT" --help
  assert_success
  assert_output --partial "Usage: gh-secret-scanning-rollout"
  assert_output --partial "--apply"
  assert_output --partial "--only"
  assert_output --partial "--resume"
  assert_output --partial "dry-run"
  assert_output --partial "Rollback"
}

@test "gh-secret-scanning-rollout: usage errors exit 2" {
  run_rollout --bogus
  assert_failure 2
  run_rollout --only
  assert_failure 2
  run_rollout --only 'bad name!'
  assert_failure 2
  run_rollout --apply --resume "$T/nope.tsv"
  assert_failure 2
  run_rollout --resume "$T/nope.tsv"
  assert_failure 2
  [[ "$(all_patches)" -eq 0 ]]
}

@test "gh-secret-scanning-rollout: dry-run selects only public non-archived repos with a disabled field and writes nothing" {
  gh_repo alpha 101 public disabled disabled
  gh_repo beta 102 public enabled enabled
  gh_repo priv 103 private disabled disabled
  gh_repo old 104 public disabled disabled true
  gh_repo half 105 public enabled disabled
  run_rollout
  assert_success
  [[ "$output" == *"target"*"alpha"* ]]
  [[ "$output" == *"target"*"half"* ]]
  [[ "$output" == *"skipped-enabled"*"beta"* ]]
  [[ "$output" == *"skipped-private"*"priv"* ]]
  [[ "$output" == *"skipped-archived"*"old"* ]]
  [[ "$output" == *"Selected: 2"* ]]
  run ! grep -E "target.*(priv|old|beta)" <<<"$output"
  grep -q '^GET user$' "$CALLS"
  # A private repo is never even requested individually.
  run ! grep -q "repos/$OWNER/priv" "$CALLS"
  [[ "$(all_patches)" -eq 0 ]]
  run ! grep -qv '^GET \|^sleep ' "$CALLS"
  [[ ! -e "$STATE" ]]
}

@test "gh-secret-scanning-rollout: a private repo is never written, even when named with --only" {
  gh_repo priv 103 private disabled disabled
  gh_repo pub 104 public disabled disabled
  # The list says public but the fresh GET says private: still never written.
  jq '.visibility = "private" | .private = true' "$FIX/repo/pub.json" >"$T/x" && mv "$T/x" "$FIX/repo/pub.json"
  run_rollout --apply --only priv,pub
  [[ "$(all_patches)" -eq 0 ]]
  [[ "$output" == *"skipped-private"*"priv"* ]]
  [[ "$output" == *"skipped-private"*"pub"* ]]
  [[ "$(state_of priv secret_scanning)" == disabled ]]
}

@test "gh-secret-scanning-rollout: --apply enables both fields with secret_scanning first and verifies" {
  gh_repo alpha 101 public disabled disabled
  run_rollout --apply
  assert_success
  [[ "$(patch_count alpha)" -eq 1 ]]
  run jq -c '.security_and_analysis | keys_unsorted' "$FIX/patches/alpha.1.json"
  assert_output '["secret_scanning","secret_scanning_push_protection"]'
  run jq -c . "$FIX/patches/alpha.1.json"
  assert_output '{"security_and_analysis":{"secret_scanning":{"status":"enabled"},"secret_scanning_push_protection":{"status":"enabled"}}}'
  [[ "$(state_of alpha secret_scanning)" == enabled ]]
  [[ "$(jlast alpha 6)" == verified ]]
  # Refresh GET before the write and verification GET after it.
  run grep -n 'alpha$' "$CALLS"
  [[ "${lines[0]}" == *"GET repos/$OWNER/alpha" ]]
  [[ "${lines[1]}" == *"GET repos/$OWNER/alpha" ]]
  [[ "${lines[2]}" == *"PATCH repos/$OWNER/alpha" ]]
  [[ "${lines[3]}" == *"GET repos/$OWNER/alpha" ]]
}

@test "gh-secret-scanning-rollout: an already-enabled field is never rewritten" {
  gh_repo half 105 public enabled disabled
  gh_repo other 106 public disabled enabled
  run_rollout --apply
  assert_success
  run jq -c . "$FIX/patches/half.1.json"
  assert_output '{"security_and_analysis":{"secret_scanning_push_protection":{"status":"enabled"}}}'
  run jq -c . "$FIX/patches/other.1.json"
  assert_output '{"security_and_analysis":{"secret_scanning":{"status":"enabled"}}}'
  [[ "$(jlast half 6)" == verified && "$(jlast other 6)" == verified ]]
}

@test "gh-secret-scanning-rollout: a missing or null field is unknown (an error), never treated as disabled" {
  gh_repo nopp 101 public disabled missing
  gh_repo nullpp 102 public disabled null
  gh_repo nosa 103 public samissing x
  gh_repo nullsa 104 public sanull x
  gh_repo nullss 105 public null disabled
  gh_repo ok 106 public enabled enabled
  run_rollout --apply
  assert_failure 1
  [[ "$(all_patches)" -eq 0 ]]
  for n in nopp nullpp nosa nullsa nullss; do
    grep -qE "^error	$n	" <<<"$output" || {
      echo "no error row for $n" >&2
      return 1
    }
  done
  run_rollout
  assert_failure 1
  [[ "$output" == *"Selected: 0"* ]]
}

@test "gh-secret-scanning-rollout: a permanent 4xx on PATCH is not retried" {
  gh_repo alpha 101 public disabled disabled
  gh_repo beta 102 public disabled disabled
  fault PATCH.alpha 422
  fault PATCH.beta "403 plain"
  run_rollout --apply
  assert_failure 1
  [[ "$(patch_count alpha)" -eq 1 ]]
  [[ "$(patch_count beta)" -eq 1 ]]
  [[ "$(jlast alpha 6)" == failed && "$(jlast beta 6)" == failed ]]
  [[ "$(jlast alpha 10)" == 422 && "$(jlast beta 10)" == 403 ]]
}

@test "gh-secret-scanning-rollout: 429 Retry-After is honoured before the PATCH is retried" {
  gh_repo alpha 101 public disabled disabled
  fault PATCH.alpha "429 retry-after=7"
  run_rollout --apply
  assert_success
  [[ "$(patch_count alpha)" -eq 2 ]]
  sleeps | grep -qx 7
  [[ "$(jlast alpha 6)" == verified ]]
  # Refresh GET between the rate-limited PATCH and its retry.
  run grep -A2 "^PATCH repos/$OWNER/alpha" "$CALLS"
  [[ "${lines[1]}" == "sleep 7" && "${lines[2]}" == "GET repos/$OWNER/alpha" ]]
}

@test "gh-secret-scanning-rollout: primary 403 waits for x-ratelimit-reset; secondary 403/429 without headers waits >= 60s" {
  gh_repo alpha 101 public disabled disabled
  gh_repo beta 102 public disabled disabled
  gh_repo gamma 103 public disabled disabled
  gh_repo delta 104 public disabled disabled
  fault PATCH.alpha "403 reset=+30"
  fault PATCH.beta "403 secondary"
  fault PATCH.gamma "429 bare"
  fault PATCH.delta "403 retry-after=9"
  run_rollout --apply
  assert_success
  local s
  s="$(sleeps | awk '$1 >= 25 && $1 <= 35' | head -n1)"
  [[ -n "$s" ]]
  [[ "$(sleeps | awk '$1 >= 60' | wc -l | tr -d ' ')" -ge 2 ]]
  sleeps | grep -qx 9
  for n in alpha beta gamma delta; do [[ "$(patch_count "$n")" -eq 2 ]]; done
}

@test "gh-secret-scanning-rollout: rate-limit retries are bounded" {
  gh_repo alpha 101 public disabled disabled
  fault PATCH.alpha "429 retry-after=1" "429 retry-after=1" "429 retry-after=1" "429 retry-after=1" "429 retry-after=1" "429 retry-after=1" "429 retry-after=1" "429 retry-after=1"
  run_rollout --apply
  assert_failure 1
  [[ "$(patch_count alpha)" -eq 5 ]]
  [[ "$(jlast alpha 6)" == failed ]]
}

@test "gh-secret-scanning-rollout: a rate-limited GET is retried after Retry-After" {
  gh_repo alpha 101 public disabled disabled
  fault LIST.1 "429 retry-after=4"
  fault GET.alpha "403 retry-after=5"
  run_rollout
  assert_success
  sleeps | grep -qx 4
  sleeps | grep -qx 5
  [[ "$output" == *"target"*"alpha"* ]]
}

@test "gh-secret-scanning-rollout: success is never declared without a verifying GET" {
  gh_repo alpha 101 public disabled disabled
  gh_repo beta 102 public disabled disabled
  fault PATCH.alpha noop-200
  fault PATCH.beta clobber
  run_rollout --apply
  assert_failure 1
  [[ "$(jlast alpha 6)" == failed ]]
  [[ "$(jlast alpha 7)" == disabled ]]
  [[ "$(jlast beta 6)" == failed ]]
  [[ "$(jlast beta 11)" == *"other"* ]]
}

@test "gh-secret-scanning-rollout: verification fails when an unrelated security_and_analysis key appears after the PATCH" {
  gh_repo alpha 101 public disabled disabled
  fault PATCH.alpha add-key
  run_rollout --apply
  assert_failure 1
  [[ "$(patch_count alpha)" -eq 1 ]]
  [[ "$(jlast alpha 7)" == enabled && "$(jlast alpha 8)" == enabled ]]
  [[ "$(jlast alpha 6)" == failed ]]
  [[ "$(jlast alpha 11)" == *"other security_and_analysis fields changed"* ]]
}

@test "gh-secret-scanning-rollout: a second run over completed state makes zero writes" {
  gh_repo alpha 101 public disabled disabled
  gh_repo beta 102 public enabled disabled
  run_rollout --apply
  assert_success
  [[ "$(all_patches)" -eq 2 ]]
  : >"$CALLS"
  run_rollout --apply
  assert_success
  [[ "$(all_patches)" -eq 0 ]]
  [[ "$output" == *"Selected: 0"* ]]
}

@test "gh-secret-scanning-rollout: pagination is followed; a failed page is incomplete and blocks every write" {
  gh_repo a1 101 public disabled disabled
  gh_repo a2 102 public enabled enabled
  gh_repo a3 103 public disabled disabled
  gh_repo a4 104 public enabled enabled
  gh_repo a5 105 public disabled disabled
  run_rollout
  assert_success
  [[ "$output" == *"target"*"a5"* ]]
  [[ "$output" == *"Selected: 3"* ]]
  grep -q 'page=3$' "$CALLS"

  : >"$CALLS"
  fault LIST.2 404
  run_rollout --apply
  assert_failure 1
  [[ "$output$stderr" == *"incomplete"* ]]
  [[ "$(all_patches)" -eq 0 ]]

  fault LIST.3 422
  run_rollout
  assert_failure 1
  [[ "$output$stderr" == *"incomplete"* ]]
}

@test "gh-secret-scanning-rollout: a failed per-repo GET is an error and the inventory is incomplete" {
  gh_repo alpha 101 public disabled disabled
  gh_repo beta 102 public disabled disabled
  fault GET.beta 404
  run_rollout
  assert_failure 1
  [[ "$output$stderr" == *"incomplete"* ]]
  grep -qE "^error	beta	" <<<"$output"
}

@test "gh-secret-scanning-rollout: owner filter and dedupe by id" {
  gh_repo alpha 101 public disabled disabled
  gh_repo theirs 201 public disabled disabled false false someone-else
  # The same repo listed twice (e.g. a page boundary shift).
  head -n1 "$FIX/list.jsonl" >>"$FIX/list.jsonl"
  run_rollout --apply
  assert_success
  [[ "$(patch_count alpha)" -eq 1 ]]
  run ! grep -q 'theirs' "$CALLS"
}

@test "gh-secret-scanning-rollout: a 5xx or timeout on PATCH is reconciled by GET before any retry" {
  gh_repo applied 101 public disabled disabled
  gh_repo notapplied 102 public disabled disabled
  gh_repo slow 103 public disabled disabled
  fault PATCH.applied 502-applied
  fault PATCH.notapplied 502
  fault PATCH.slow timeout-applied
  run_rollout --apply
  assert_success
  [[ "$(patch_count applied)" -eq 1 ]]
  [[ "$(patch_count slow)" -eq 1 ]]
  [[ "$(patch_count notapplied)" -eq 2 ]]
  run grep -A3 "^PATCH repos/$OWNER/notapplied" "$CALLS"
  [[ "${lines[*]}" == *"GET repos/$OWNER/notapplied"*"PATCH repos/$OWNER/notapplied"* ]]
  for n in applied notapplied slow; do [[ "$(jlast "$n" 6)" == verified ]]; done
}

@test "gh-secret-scanning-rollout: state is refreshed immediately before the write" {
  gh_repo alpha 101 public disabled disabled
  fault GET.alpha pass enable-now
  run_rollout --apply
  assert_success
  [[ "$(all_patches)" -eq 0 ]]
  [[ "$(jlast alpha 6)" == already-enabled ]]
}

@test "gh-secret-scanning-rollout: mutations are spaced by at least 1s" {
  gh_repo alpha 101 public disabled disabled
  gh_repo beta 102 public disabled disabled
  run_rollout --apply
  assert_success
  run sed -n "/^PATCH repos\/$OWNER\/alpha/,/^PATCH repos\/$OWNER\/beta/p" "$CALLS"
  [[ "${lines[*]}" == *"sleep 1"* ]]
}

@test "gh-secret-scanning-rollout: --only scopes the run; an unknown name is an error" {
  gh_repo alpha 101 public disabled disabled
  gh_repo beta 102 public disabled disabled
  run_rollout --apply --only beta
  assert_success
  [[ "$(patch_count alpha)" -eq 0 && "$(patch_count beta)" -eq 1 ]]
  run ! grep -q "repos/$OWNER/alpha" "$CALLS"
  run_rollout --apply --only alpha,nosuch
  assert_failure 1
  grep -qE "^error	nosuch	" <<<"$output"
  [[ "$(patch_count alpha)" -eq 1 ]]
}

@test "gh-secret-scanning-rollout: the journal is private and records before and after states" {
  gh_repo alpha 101 public enabled disabled
  run_rollout --apply
  assert_success
  local j
  j="$(journal)"
  [[ -n "$j" ]]
  [[ "$output$stderr" == *"$j"* ]]
  run /bin/ls -led "$STATE"
  [[ "$output" == drwx------" "* ]]
  run /bin/ls -le "$j"
  [[ "$output" == -rw-------" "* ]]
  [[ "$(head -n1 "$j")" == "# repo"*"repo_id"*"ss_before"*"pp_before"*"action"*"result"*"ss_after"*"pp_after"*"utc"* ]]
  [[ "$(jlast alpha 2)" == 101 ]]
  [[ "$(jlast alpha 3)" == enabled && "$(jlast alpha 4)" == disabled ]]
  [[ "$(jlast alpha 5)" == patch:push_protection ]]
  [[ "$(jlast alpha 7)" == enabled && "$(jlast alpha 8)" == enabled ]]
  [[ "$(jlast alpha 9)" =~ ^20[0-9]{2}-[0-9]{2}-[0-9]{2}T ]]
}

@test "gh-secret-scanning-rollout: --resume appends, skips repos done in the journal and retries failed ones" {
  gh_repo alpha 101 public disabled disabled
  gh_repo beta 102 public disabled disabled
  fault PATCH.beta 422
  run_rollout --apply
  assert_failure 1
  local j rows
  j="$(journal)"
  rows="$(grep -vc '^#' "$j")"
  # alpha rolled back by hand: a resume must respect that.
  jq '.security_and_analysis.secret_scanning.status = "disabled" | .security_and_analysis.secret_scanning_push_protection.status = "disabled"' \
    "$FIX/repo/alpha.json" >"$T/x" && mv "$T/x" "$FIX/repo/alpha.json"
  : >"$CALLS"
  run_rollout --apply --resume "$j"
  assert_success
  [[ "$(patch_count alpha)" -eq 0 ]]
  [[ "$(patch_count beta)" -eq 1 ]]
  [[ "$(jlast beta 6)" == verified ]]
  [[ "$(grep -vc '^#' "$j")" -gt "$rows" ]]
  [[ "$(find "$STATE" -name 'secret-scanning-*.tsv' | wc -l | tr -d ' ')" -eq 1 ]]
}

@test "gh-secret-scanning-rollout: --resume reconciles a pending or failed repo that is now enabled, without a PATCH" {
  gh_repo alpha 101 public disabled disabled
  gh_repo beta 102 public disabled disabled
  # The PATCH is accepted but not visible within the verify window: failed.
  fault PATCH.alpha noop-200
  fault PATCH.beta noop-200
  run_rollout --apply
  assert_failure 1
  local j tmp
  j="$(journal)"
  [[ "$(jlast alpha 6)" == failed && "$(jlast beta 6)" == failed ]]
  # beta: the run died between its pending row and the outcome.
  tmp="$T/j.tmp"
  awk -F'\t' '!($1 == "beta" && $6 == "failed")' "$j" >"$tmp" && cat "$tmp" >"$j"
  [[ "$(jlast beta 6)" == pending ]]
  # GitHub has since applied both.
  for n in alpha beta; do
    jq '.security_and_analysis.secret_scanning.status = "enabled" | .security_and_analysis.secret_scanning_push_protection.status = "enabled"' \
      "$FIX/repo/$n.json" >"$T/x" && mv "$T/x" "$FIX/repo/$n.json"
  done
  : >"$CALLS"
  run_rollout --apply --resume "$j"
  assert_success
  [[ "$(all_patches)" -eq 0 ]]
  for n in alpha beta; do
    [[ "$(jlast "$n" 6)" == verified ]]
    [[ "$(jlast "$n" 3)" == disabled && "$(jlast "$n" 4)" == disabled ]]
    [[ "$(jlast "$n" 5)" == none ]]
    [[ "$(jlast "$n" 7)" == enabled && "$(jlast "$n" 8)" == enabled ]]
    [[ "$(jlast "$n" 11)" == *"reconciled on resume"* ]]
  done
  [[ "$output" == *"Verified: 2;"* ]]
  # Settled: a further resume writes nothing and appends nothing for them.
  local rows
  rows="$(grep -vc '^#' "$j")"
  : >"$CALLS"
  run_rollout --apply --resume "$j"
  assert_success
  [[ "$(all_patches)" -eq 0 ]]
  [[ "$(grep -vc '^#' "$j")" -eq "$rows" ]]
}

@test "gh-secret-scanning-rollout: --resume reconciliation never applies to a repo that is still disabled" {
  gh_repo alpha 101 public disabled disabled
  fault PATCH.alpha noop-200
  run_rollout --apply
  assert_failure 1
  local j
  j="$(journal)"
  : >"$CALLS"
  run_rollout --apply --resume "$j"
  assert_success
  [[ "$(patch_count alpha)" -eq 1 ]]
  [[ "$(jlast alpha 6)" == verified ]]
  [[ "$(jlast alpha 11)" != *"reconciled on resume"* ]]
}

@test "gh-secret-scanning-rollout: a done-in-journal row still counts as completed on every later resume" {
  gh_repo alpha 101 public disabled disabled
  run_rollout --apply
  assert_success
  local j
  j="$(journal)"
  # Completed, then rolled back by hand.
  jq '.security_and_analysis.secret_scanning.status = "disabled" | .security_and_analysis.secret_scanning_push_protection.status = "disabled"' \
    "$FIX/repo/alpha.json" >"$T/x" && mv "$T/x" "$FIX/repo/alpha.json"
  : >"$CALLS"
  run_rollout --apply --resume "$j"
  assert_success
  [[ "$(all_patches)" -eq 0 ]]
  [[ "$(jlast alpha 6)" == done-in-journal ]]
  : >"$CALLS"
  run_rollout --apply --resume "$j"
  assert_success
  [[ "$(all_patches)" -eq 0 ]]
  [[ "$(jlast alpha 6)" == done-in-journal ]]
  [[ "$(state_of alpha secret_scanning)" == disabled ]]
}

@test "gh-secret-scanning-rollout: --resume refuses a journal that is not private or not a journal" {
  mkdir -p "$STATE"
  printf 'not a journal\n' >"$STATE/secret-scanning-00bad.tsv"
  chmod 600 "$STATE/secret-scanning-00bad.tsv"
  run_rollout --apply --resume "$STATE/secret-scanning-00bad.tsv"
  assert_failure 2
  gh_repo alpha 101 public disabled disabled
  run_rollout --apply
  local j
  j="$(journal)"
  chmod 644 "$j"
  run_rollout --apply --resume "$j"
  assert_failure 2
}
