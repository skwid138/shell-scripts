#!/usr/bin/env bats
bats_require_minimum_version 1.5.0
# Tests for personal/gitleaks-audit.sh (daily gitleaks history audit) and its
# launchd template.
#
# Every run is under `env -i` with HOME and TMPDIR redirected into the test
# temp dir, PATH replaced (GITLEAKS_AUDIT_BASE_PATH) by stubs + pinned real
# git/jq + system dirs, and /bin/bash (3.2 on macOS). Repositories are real
# temp git repos under $HOME/code. The gitleaks stub writes a JSON report
# chosen per repo (keyed by repo basename) and plants a SECRET MARKER in its
# stdout, stderr, and in the Secret/Match/Line fields of every finding, so
# tests can prove the marker never reaches the log, stdout/stderr, state,
# notification argv, or leftover temp files.
#
# macOS-only (launchd, BSD stat, /usr/bin/perl setpgrp). Skipped elsewhere.

setup() {
  load 'test_helper/bats-support/load'
  load 'test_helper/bats-assert/load'

  [[ "$(uname -s)" == "Darwin" ]] || skip "gitleaks-audit is macOS-only (launchd, BSD stat)"

  SCRIPT="$BATS_TEST_DIRNAME/../personal/gitleaks-audit.sh"
  T="$BATS_TEST_TMPDIR"
  FAKE_HOME="$T/home"
  CODE="$FAKE_HOME/code"
  STUBS="$T/stubs"
  FIX="$T/fix"
  CALLS="$T/calls.log"
  TMPD="$T/tmp"
  STATE="$FAKE_HOME/Library/Application Support/gitleaks-audit"
  LOGF="$FAKE_HOME/Library/Logs/gitleaks-audit.log"
  CONFIG="$FAKE_HOME/.config/gitleaks-audit/config"
  MARKER="SYNTHETIC-SECRET-MARKER-7f3a9c"
  mkdir -p "$CODE" "$STUBS" "$FIX" "$TMPD"
  : >"$CALLS"

  REAL_GIT="$(command -v git)"
  REAL_JQ="$(command -v jq || echo /usr/bin/jq)"
  ln -s "$REAL_GIT" "$STUBS/git"
  ln -s "$REAL_JQ" "$STUBS/jq"

  NOW=2000000000
  TIMEOUT=30
  GRACE=1
  write_stubs
}

teardown() {
  local f
  for f in "$FIX/gc.pid" "$FIX/leader.pid"; do
    [[ -s "$f" ]] && kill -KILL "$(cat "$f")" 2>/dev/null
  done
  return 0
}

# --- stubs ---------------------------------------------------------------------

write_stubs() {
  cat >"$STUBS/gitleaks" <<'EOF'
#!/bin/bash
printf 'gitleaks %s | pwd=%s | cfg=%s|%s\n' "$*" "$PWD" "${GITLEAKS_CONFIG-unset}" "${GITLEAKS_CONFIG_TOML-unset}" >>"$CALLS"
if [[ "${1-}" == "version" ]]; then
  cat "$FIX/version" 2>/dev/null || echo "8.30.1"
  exit 0
fi
rp=""
for a in "$@"; do
  case "$a" in --report-path=*) rp="${a#--report-path=}" ;; esac
done
repo="$(basename "$PWD")"
echo "$MARKER on stdout"
echo "$MARKER on stderr" >&2
if [[ -f "$FIX/mutate.$repo" ]]; then
  git update-ref refs/heads/midscan HEAD
fi
if [[ -f "$FIX/hang.$repo" ]]; then
  sh -c 'trap "" TERM; echo $$ >"$FIX/gc.pid"; exec sleep 300' </dev/null >/dev/null 2>&1 3>&- &
  echo $$ >"$FIX/leader.pid"
  trap 'echo got-term >"$FIX/leader.term"; exit 143' TERM
  sleep 40 &
  wait $!
fi
if [[ -f "$FIX/orphan.$repo" ]]; then
  sh -c 'trap "" TERM; echo $$ >"$FIX/gc.pid"; exec sleep 300' </dev/null >/dev/null 2>&1 3>&- &
  sleep 0.2
fi
if [[ -f "$FIX/json.$repo" ]]; then
  cp "$FIX/json.$repo" "$rp"
else
  echo '[]' >"$rp"
fi
exit "$(cat "$FIX/rc.$repo" 2>/dev/null || echo 0)"
EOF
  chmod +x "$STUBS/gitleaks"
  cat >"$STUBS/osascript" <<'EOF'
#!/bin/bash
printf 'osascript %s\n' "$*" >>"$CALLS"
exit "$(cat "$FIX/osascript_rc" 2>/dev/null || echo 0)"
EOF
  chmod +x "$STUBS/osascript"
  cat >"$STUBS/launchctl" <<'EOF'
#!/bin/bash
printf 'launchctl %s\n' "$*" >>"$CALLS"
case "${1-}" in
  print) exit "$(cat "$FIX/launchctl_print_rc" 2>/dev/null || echo 113)" ;;
  bootstrap) exit "$(cat "$FIX/launchctl_bootstrap_rc" 2>/dev/null || echo 0)" ;;
  bootout) exit "$(cat "$FIX/launchctl_bootout_rc" 2>/dev/null || echo 0)" ;;
esac
exit 0
EOF
  chmod +x "$STUBS/launchctl"
}

# run_audit [args...]: hermetic env, /bin/bash, no stdin. stderr separate.
run_audit() {
  run --separate-stderr env -i HOME="$FAKE_HOME" TMPDIR="$TMPD" CALLS="$CALLS" FIX="$FIX" \
    MARKER="$MARKER" GITLEAKS_CONFIG=/x/ambient.toml GITLEAKS_CONFIG_TOML='title="ambient"' \
    GITLEAKS_AUDIT_BASE_PATH="$STUBS:/usr/bin:/bin:/usr/sbin:/sbin" \
    GITLEAKS_AUDIT_NOW="$NOW" GITLEAKS_AUDIT_TIMEOUT="$TIMEOUT" GITLEAKS_AUDIT_KILL_GRACE="$GRACE" \
    /bin/bash "$SCRIPT" "$@" </dev/null 3>&-
}

# mkrepo <rel>: real git repo with one commit under ~/code.
mkrepo() {
  local d="$CODE/$1"
  mkdir -p "$d"
  git -C "$d" init -q -b main
  git -C "$d" -c user.name=t -c user.email=t@e commit -q --allow-empty -m init
}

commit_in() { # <rel> [branch]
  git -C "$CODE/$1" -c user.name=t -c user.email=t@e commit -q --allow-empty -m "c $RANDOM"
}

# findings <repo-basename> <n> [tag]: stub returns rc 10 + n findings.
findings() {
  local repo="$1" n="$2" tag="${3:-a}" i
  {
    printf '['
    for ((i = 1; i <= n; i++)); do
      [[ $i -gt 1 ]] && printf ','
      printf '{"RuleID":"%s","File":"src/f%d.txt","Commit":"%040d","StartLine":%d,"Fingerprint":"%040d:src/f%d.txt:%s:%d","Secret":"%s","Match":"key=%s","Line":"x %s","Description":"d"}' \
        "$([[ $((i % 2)) -eq 0 ]] && echo generic-api-key || echo aws-access-token)" "$i" "$i" "$i" "$i" "$i" "rule-$tag" "$i" "$MARKER" "$MARKER" "$MARKER"
    done
    printf ']\n'
  } >"$FIX/json.$repo"
  if [[ "$n" -gt 0 ]]; then echo 10 >"$FIX/rc.$repo"; else echo 0 >"$FIX/rc.$repo"; fi
}

scans() { grep -c '^gitleaks git ' "$CALLS" || true; }
scanned_repos() { sed -n 's/^gitleaks git .* | pwd=\([^|]*\) | .*/\1/p' "$CALLS" | sed "s#^$CODE/##" | sort; }
notifies() { grep '^osascript' "$CALLS" || true; }

# assert_no_marker: the marker is nowhere outside the stub's own fixtures.
assert_no_marker() {
  local where
  for where in "$output" "$stderr"; do
    if grep -qF "$MARKER" <<<"$where"; then
      echo "marker leaked into stdout/stderr" >&2
      return 1
    fi
  done
  if [[ -e "$LOGF" ]] && grep -qF "$MARKER" "$LOGF"; then
    echo "marker leaked into log" >&2
    return 1
  fi
  if [[ -e "$STATE" ]] && grep -rqF "$MARKER" "$STATE"; then
    echo "marker leaked into state" >&2
    return 1
  fi
  if grep '^osascript' "$CALLS" | grep -qF "$MARKER"; then
    echo "marker leaked into notify argv" >&2
    return 1
  fi
  if [[ -n "$(ls -A "$TMPD")" ]]; then
    echo "temp files left behind: $(ls -A "$TMPD")" >&2
    return 1
  fi
}

# --- help / modes -------------------------------------------------------------

@test "gitleaks-audit: --help exits 0 and documents every mode" {
  run_audit --help
  assert_success
  local m
  for m in --run --full --report --install --uninstall --status --no-notify; do
    assert_output --partial -- "$m"
  done
}

@test "gitleaks-audit: conflicting modes are a usage error" {
  run_audit --run --report
  assert_failure 2
}

@test "gitleaks-audit: default dry run lists repos and reasons, scans nothing, writes no state or log" {
  mkrepo alpha
  mkrepo "nested/beta"
  run_audit
  assert_success
  assert_output --partial "alpha"
  assert_output --partial "nested/beta"
  assert_output --partial "never scanned"
  [[ "$(scans)" -eq 0 ]]
  [[ ! -e "$STATE" ]]
  [[ ! -e "$LOGF" ]]
  run notifies
  assert_output ""
}

# --- run outcomes -------------------------------------------------------------

@test "gitleaks-audit: clean run exits 0, is quiet, scans each repo with the exact command from the repo dir" {
  mkrepo alpha
  mkrepo "space repo"
  run_audit --run
  assert_success
  run scanned_repos
  assert_output "$(printf '%s\n' alpha "space repo")"
  run grep '^gitleaks git ' "$CALLS"
  assert_line --regexp "^gitleaks git --redact=100 --no-banner --exit-code=10 --report-format=json --report-path=$TMPD/[^ ]+ \. \| pwd=$CODE/alpha \| cfg=unset\|unset$"
  run notifies
  assert_output ""
}

@test "gitleaks-audit: first run baselines existing findings, notifies once with --report hint, exits 0" {
  mkrepo alpha
  mkrepo beta
  mkrepo gamma
  findings alpha 3
  findings beta 2
  run_audit --run
  assert_success
  assert_no_marker
  run notifies
  assert_output --partial '5 existing findings in 2 repos baselined'
  assert_output --partial 'gitleaks-audit.sh --report'
  # Log summary lists repo and rule counts.
  grep -q 'alpha: .*aws-access-token=2' "$LOGF"
  grep -q 'alpha: .*generic-api-key=1' "$LOGF"
  grep -q 'beta: .*aws-access-token=1' "$LOGF"
}

@test "gitleaks-audit: unchanged repos are skipped on the next run, which is quiet and exits 0" {
  mkrepo alpha
  findings alpha 2
  run_audit --run
  : >"$CALLS"
  run_audit --run
  assert_success
  assert_line --regexp '^ *skip +alpha +\(unchanged\)'
  [[ "$(scans)" -eq 0 ]]
  run notifies
  assert_output ""
}

@test "gitleaks-audit: rc 10 with only known findings is cached: rescan is quiet and exits 0" {
  mkrepo alpha
  findings alpha 2
  run_audit --run
  commit_in alpha
  : >"$CALLS"
  run_audit --run
  assert_success
  [[ "$(scans)" -eq 1 ]]
  run notifies
  assert_output ""
}

@test "gitleaks-audit: a new fingerprint exits 10 and notifies (without the secret)" {
  mkrepo alpha
  findings alpha 2
  run_audit --run
  commit_in alpha
  findings alpha 3
  : >"$CALLS"
  run_audit --run
  assert_failure 10
  assert_no_marker
  run notifies
  assert_output --partial "1 NEW"
  # Known now: a further unchanged rerun is quiet.
  : >"$CALLS"
  run_audit --run
  assert_success
}

@test "gitleaks-audit: a repo first seen after the baseline is baselined, not reported as new" {
  mkrepo alpha
  run_audit --run
  mkrepo late
  findings late 2
  : >"$CALLS"
  run_audit --run
  assert_success
  run notifies
  assert_output --partial "2 existing findings in 1 repos baselined"
}

@test "gitleaks-audit: gitleaks error rc is a repo error: exit 1, notify, snapshot not advanced" {
  mkrepo alpha
  mkrepo beta
  run_audit --run
  assert_success
  commit_in alpha
  echo 1 >"$FIX/rc.alpha"
  run_audit --run
  assert_failure 1
  assert_no_marker
  run notifies
  assert_output --partial "error"
  run_audit
  assert_line --regexp '^ *scan +alpha +\(HEAD moved, refs changed\)'
  assert_line --regexp '^ *skip +beta +\(unchanged\)'
}

@test "gitleaks-audit: rc 0 with a non-empty report, or rc 10 with an empty one, is an error" {
  mkrepo alpha
  findings alpha 2
  echo 0 >"$FIX/rc.alpha"
  run_audit --run
  assert_failure 1
  mkrepo beta
  echo '[]' >"$FIX/json.beta"
  echo 10 >"$FIX/rc.beta"
  run_audit --run
  assert_failure 1
}

@test "gitleaks-audit: malformed JSON is an error and never advances the snapshot" {
  mkrepo alpha
  printf '[{"RuleID":"x","Secret":"%s"' "$MARKER" >"$FIX/json.alpha"
  echo 10 >"$FIX/rc.alpha"
  run_audit --run
  assert_failure 1
  assert_no_marker
  [[ ! -e "$STATE/repos" ]] || ! grep -rqs . "$STATE/repos"/*/snapshot
  # Finding missing required fields is also malformed.
  printf '[{"RuleID":"x","File":"f","Commit":"c","StartLine":"1","Fingerprint":"p","Secret":"%s"}]' "$MARKER" >"$FIX/json.alpha"
  run_audit --run
  assert_failure 1
  assert_no_marker
  run_audit
  assert_line --regexp '^ *scan +alpha +.*never scanned'
  # Unparseable report with rc 0 must not pass as "clean".
  printf 'garbage %s' "$MARKER" >"$FIX/json.alpha"
  echo 0 >"$FIX/rc.alpha"
  run_audit --run
  assert_failure 1
  assert_no_marker
}

@test "gitleaks-audit: a state-write failure is an error and keeps the old snapshot" {
  mkrepo alpha
  run_audit --run
  assert_success
  local d
  d="$(dirname "$(grep -lx alpha "$STATE"/repos/*/path)")"
  cp "$d/snapshot" "$T/snap.before"
  commit_in alpha
  chmod 500 "$d"
  run_audit --run
  chmod 700 "$d"
  assert_failure 1
  cmp -s "$d/snapshot" "$T/snap.before"
  run_audit
  assert_line --regexp '^ *scan +alpha +.*HEAD moved'
}

# --- change detection ---------------------------------------------------------

@test "gitleaks-audit: a changed non-HEAD branch triggers a rescan of only that repo" {
  mkrepo alpha
  mkrepo beta
  run_audit --run
  git -C "$CODE/alpha" branch side
  git -C "$CODE/alpha" checkout -q side
  commit_in alpha
  git -C "$CODE/alpha" checkout -q main
  run_audit
  assert_line --regexp '^ *scan +alpha +.*refs changed'
  : >"$CALLS"
  run_audit --run
  assert_success
  run scanned_repos
  assert_output "alpha"
}

@test "gitleaks-audit: a stash change triggers a rescan" {
  mkrepo alpha
  echo v1 >"$CODE/alpha/f"
  git -C "$CODE/alpha" add f
  git -C "$CODE/alpha" -c user.name=t -c user.email=t@e commit -q -m f
  run_audit --run
  echo v2 >"$CODE/alpha/f"
  git -C "$CODE/alpha" -c user.name=t -c user.email=t@e stash -q
  : >"$CALLS"
  run_audit --run
  run scanned_repos
  assert_output "alpha"
}

@test "gitleaks-audit: .gitleaks.toml / .gitleaksignore changes and gitleaks version changes trigger rescans" {
  mkrepo alpha
  mkrepo beta
  run_audit --run
  echo 'title = "x"' >"$CODE/alpha/.gitleaks.toml"
  run_audit
  assert_line --regexp '^ *scan +alpha +.*gitleaks config changed'
  : >"$CALLS"
  run_audit --run
  run scanned_repos
  assert_output "alpha"

  # Editing an existing config (not just adding one) is detected by content.
  echo 'title = "y"' >"$CODE/alpha/.gitleaks.toml"
  : >"$CALLS"
  run_audit --run
  run scanned_repos
  assert_output "alpha"

  echo 'abc:def:ghi:1' >"$CODE/beta/.gitleaksignore"
  : >"$CALLS"
  run_audit --run
  run scanned_repos
  assert_output "beta"

  echo "8.31.0" >"$FIX/version"
  : >"$CALLS"
  run_audit --run
  run scanned_repos
  assert_output "$(printf '%s\n' alpha beta)"
}

@test "gitleaks-audit: a commit on a detached HEAD in a linked worktree triggers a rescan" {
  mkrepo alpha
  git -C "$CODE/alpha" worktree add -q --detach "$T/wt alpha"
  run_audit --run
  assert_success
  run_audit
  assert_line --regexp '^ *skip +alpha +\(unchanged\)'
  # No ref and no main-worktree HEAD moves: only the linked worktree's HEAD.
  git -C "$T/wt alpha" -c user.name=t -c user.email=t@e commit -q --allow-empty -m detached
  run_audit
  assert_line --regexp '^ *scan +alpha +\(worktree HEADs changed\)'
  : >"$CALLS"
  run_audit --run
  run scanned_repos
  assert_output "alpha"
}

@test "gitleaks-audit: files referenced by [extend] path (chained, absolute or repo-relative) are part of the fingerprint" {
  mkrepo alpha
  local cfg="$FAKE_HOME/.config/gitleaks"
  mkdir -p "$cfg"
  printf '[extend]\npath = "%s/base.toml" # shared\n' "$cfg" >"$CODE/alpha/.gitleaks.toml"
  printf 'title = "base"\n[extend]\npath = \x27%s/root.toml\x27\n' "$cfg" >"$cfg/base.toml"
  printf 'title = "root"\n' >"$cfg/root.toml"
  run_audit --run
  run_audit
  assert_line --regexp '^ *skip +alpha +\(unchanged\)'
  # Second level of the chain changes.
  echo '# edited' >>"$cfg/root.toml"
  run_audit
  assert_line --regexp '^ *scan +alpha +\(gitleaks config changed\)'
  : >"$CALLS"
  run_audit --run
  run scanned_repos
  assert_output "alpha"
  # Repo-relative extend target that is missing, then created.
  printf 'extend.path = "shared/x.toml"\n' >"$CODE/alpha/.gitleaks.toml"
  run_audit --run
  run_audit
  assert_line --regexp '^ *skip +alpha +\(unchanged\)'
  mkdir -p "$CODE/alpha/shared"
  printf 'title = "x"\n' >"$CODE/alpha/shared/x.toml"
  run_audit
  assert_line --regexp '^ *scan +alpha +\(gitleaks config changed\)'
}

@test "gitleaks-audit: a self-extending .gitleaks.toml is bounded by the depth limit" {
  mkrepo alpha
  printf '[extend]\npath = ".gitleaks.toml"\n' >"$CODE/alpha/.gitleaks.toml"
  # Bounded: an unbounded extend walk would hang instead of failing.
  run --separate-stderr /usr/bin/perl -e 'alarm 60; exec @ARGV or die' env -i HOME="$FAKE_HOME" TMPDIR="$TMPD" \
    CALLS="$CALLS" FIX="$FIX" MARKER="$MARKER" GITLEAKS_AUDIT_BASE_PATH="$STUBS:/usr/bin:/bin:/usr/sbin:/sbin" \
    GITLEAKS_AUDIT_NOW="$NOW" /bin/bash "$SCRIPT" --run </dev/null 3>&-
  assert_success
  grep -q '^extend 6 depth-limit$' "$STATE"/repos/*/snapshot
  run_audit
  assert_line --regexp '^ *skip +alpha +\(unchanged\)'
}

@test "gitleaks-audit: a ref change during the scan keeps the old snapshot so the next run rescans" {
  mkrepo alpha
  run_audit --run
  assert_success
  local snap
  snap="$(dirname "$(grep -lx alpha "$STATE"/repos/*/path)")/snapshot"
  cp "$snap" "$T/snap.before"
  commit_in alpha
  touch "$FIX/mutate.alpha"
  run_audit --run
  assert_success
  assert_output --partial "snapshot not advanced"
  cmp -s "$snap" "$T/snap.before"
  rm "$FIX/mutate.alpha"
  run_audit
  assert_line --regexp '^ *scan +alpha +'
  : >"$CALLS"
  run_audit --run
  run scanned_repos
  assert_output "alpha"
  : >"$CALLS"
  run_audit --run
  [[ "$(scans)" -eq 0 ]]
}

@test "gitleaks-audit: --full scans unchanged repos too" {
  mkrepo alpha
  run_audit --run
  : >"$CALLS"
  run_audit --full
  assert_success
  run scanned_repos
  assert_output "alpha"
}

@test "gitleaks-audit: weekly force rescans everything; a partial failure does not update last_full" {
  mkrepo alpha
  mkrepo beta
  run_audit --run
  grep -qx "last_full=$NOW" "$STATE/meta"
  # 6 days later: no force.
  NOW=$((2000000000 + 6 * 86400))
  : >"$CALLS"
  run_audit --run
  [[ "$(scans)" -eq 0 ]]
  # 7 days later: forced; beta fails -> last_full stays.
  NOW=$((2000000000 + 7 * 86400))
  echo 1 >"$FIX/rc.beta"
  : >"$CALLS"
  run_audit --run
  assert_failure 1
  [[ "$(scans)" -eq 2 ]]
  grep -qx "last_full=2000000000" "$STATE/meta"
  # Next run is still forced (both repos), succeeds, and advances last_full.
  rm "$FIX/rc.beta"
  : >"$CALLS"
  run_audit --run
  assert_success
  [[ "$(scans)" -eq 2 ]]
  grep -qx "last_full=$NOW" "$STATE/meta"
}

# --- process-group watchdog ---------------------------------------------------

proc_dead() { # <pid>: true once gone (polls up to 3s)
  local i
  for i in 1 2 3 4 5 6 7 8 9 10 11 12 13 14 15; do
    kill -0 "$1" 2>/dev/null || return 0
    sleep 0.2
  done
  return 1
}

@test "gitleaks-audit: a hung scan is killed as a whole process group (TERM-ignoring grandchild too)" {
  mkrepo alpha
  mkrepo beta
  touch "$FIX/hang.alpha"
  TIMEOUT=2
  local start=$SECONDS
  run_audit --run
  assert_failure 1
  [[ $((SECONDS - start)) -lt 20 ]]
  proc_dead "$(cat "$FIX/leader.pid")"
  proc_dead "$(cat "$FIX/gc.pid")"
  # Graceful first: the leader saw TERM before the group was KILLed.
  [[ -f "$FIX/leader.term" ]]
  grep -q 'alpha.*timeout' "$LOGF"
  run scanned_repos
  assert_output "$(printf '%s\n' alpha beta)"
  assert_no_marker
}

@test "gitleaks-audit: descendants left behind by an exiting group leader are reaped" {
  mkrepo alpha
  touch "$FIX/orphan.alpha"
  run_audit --run
  assert_success
  proc_dead "$(cat "$FIX/gc.pid")"
}

@test "gitleaks-audit: TERM to the audit kills the scan group, removes temp files, releases the lock" {
  mkrepo alpha
  touch "$FIX/hang.alpha"
  env -i HOME="$FAKE_HOME" TMPDIR="$TMPD" CALLS="$CALLS" FIX="$FIX" MARKER="$MARKER" \
    GITLEAKS_AUDIT_BASE_PATH="$STUBS:/usr/bin:/bin:/usr/sbin:/sbin" GITLEAKS_AUDIT_NOW="$NOW" \
    GITLEAKS_AUDIT_TIMEOUT=60 GITLEAKS_AUDIT_KILL_GRACE=1 \
    /bin/bash "$SCRIPT" --run </dev/null >"$T/bg.out" 2>"$T/bg.err" 3>&- &
  local apid=$! i
  for i in $(seq 1 50); do
    [[ -s "$FIX/gc.pid" && -s "$FIX/leader.pid" ]] && break
    sleep 0.1
  done
  [[ -s "$FIX/gc.pid" ]]
  kill -TERM "$apid"
  local rc=0
  wait "$apid" || rc=$?
  [[ "$rc" -eq 143 ]]
  proc_dead "$(cat "$FIX/leader.pid")"
  proc_dead "$(cat "$FIX/gc.pid")"
  [[ -z "$(ls -A "$TMPD")" ]]
  [[ ! -e "$FAKE_HOME/Library/Caches/gitleaks-audit.lock" ]]
  ! grep -qF "$MARKER" "$T/bg.out" "$T/bg.err" "$LOGF"
}

# --- discovery / excludes -----------------------------------------------------

@test "gitleaks-audit: discovery depth is <= 3 below ~/code and skips node_modules" {
  mkrepo d1
  mkrepo a/d2
  mkrepo a/b/d3
  mkrepo a/b/c/d4
  mkrepo d1/node_modules/pkg
  run_audit --run
  run scanned_repos
  assert_output "$(printf '%s\n' a/b/d3 a/d2 d1)"
}

@test "gitleaks-audit: linked worktrees are skipped (covered by their main repo)" {
  mkrepo alpha
  git -C "$CODE/alpha" worktree add -q "$CODE/alpha-wt" -b wt
  run_audit
  assert_line --regexp '^ *skip +alpha-wt +.*worktree'
  run_audit --run
  run scanned_repos
  assert_output "alpha"
}

@test "gitleaks-audit: excludes in the private config are honored (comments, ./ and trailing / tolerated)" {
  mkrepo buzz
  mkrepo buzz/whisper.cpp
  mkrepo keep
  mkdir -p "$(dirname "$CONFIG")"
  printf '%s\n' "# excludes" "buzz/" "./buzz/whisper.cpp" "" >"$CONFIG"
  run_audit --run
  assert_success
  run scanned_repos
  assert_output "keep"
  run_audit
  assert_line --regexp '^ *excluded +buzz( |$)'
  assert_line --regexp '^ *excluded +buzz/whisper.cpp( |$)'
}

@test "gitleaks-audit: an unreadable exclude config is an error and nothing is scanned" {
  mkrepo alpha
  mkdir -p "$(dirname "$CONFIG")"
  echo alpha >"$CONFIG"
  chmod 000 "$CONFIG"
  run_audit --run
  chmod 600 "$CONFIG"
  assert_failure 1
  [[ "$(scans)" -eq 0 ]]
  run notifies
  assert_output --partial "error"
}

@test "gitleaks-audit: discovery failures are errors, never a clean zero-repo run" {
  # No ~/code at all.
  rm -rf "$CODE"
  run_audit --run
  assert_failure 1
  # ~/code with no repos.
  mkdir -p "$CODE/empty"
  run_audit --run
  assert_failure 1
  # find error on an unreadable subtree: other repos still scanned, run is an error.
  mkrepo alpha
  mkdir -p "$CODE/locked/inner"
  chmod 000 "$CODE/locked"
  : >"$CALLS"
  run_audit --run
  chmod 755 "$CODE/locked"
  assert_failure 1
  run scanned_repos
  assert_output "alpha"
  ! grep -q '^last_full=' "$STATE/meta" 2>/dev/null
}

# --- secrecy / permissions / environment ---------------------------------------

@test "gitleaks-audit: the secret marker never appears anywhere across success and failure paths" {
  mkrepo alpha
  mkrepo beta
  mkrepo gamma
  findings alpha 2
  echo 2 >"$FIX/rc.beta"
  printf 'not json %s' "$MARKER" >"$FIX/json.gamma"
  echo 10 >"$FIX/rc.gamma"
  run_audit --run
  assert_failure 1
  assert_no_marker
  run_audit --report
  assert_success
  assert_no_marker
  run_audit --status
  assert_no_marker
}

@test "gitleaks-audit: state dir is 700, state and log files 600" {
  mkrepo alpha
  findings alpha 1
  run_audit --run
  [[ "$(/usr/bin/stat -f %Lp "$STATE")" == "700" ]]
  local f bad=""
  while IFS= read -r f; do
    [[ "$(/usr/bin/stat -f %Lp "$f")" == "600" ]] || bad="$bad $f"
  done < <(find "$STATE" -type f)
  while IFS= read -r f; do
    [[ "$(/usr/bin/stat -f %Lp "$f")" == "700" ]] || bad="$bad $f"
  done < <(find "$STATE" -type d)
  [[ -z "$bad" ]] || {
    echo "bad perms:$bad" >&2
    return 1
  }
  [[ "$(/usr/bin/stat -f %Lp "$LOGF")" == "600" ]]
}

@test "gitleaks-audit: an existing state dir with loose perms is tightened to 700" {
  mkdir -p "$STATE"
  chmod 755 "$STATE"
  mkrepo alpha
  run_audit --run
  [[ "$(/usr/bin/stat -f %Lp "$STATE")" == "700" ]]
}

@test "gitleaks-audit: runs under /bin/bash 3.2 with an empty environment" {
  [[ "$(/bin/bash -c 'echo ${BASH_VERSINFO[0]}')" == "3" ]] || skip "/bin/bash is not 3.x"
  mkrepo alpha
  run_audit --run
  assert_success
  grep -q 'bash 3\.2' "$LOGF"
}

@test "gitleaks-audit: a live lock holder makes the run exit 75 and scan nothing" {
  mkrepo alpha
  sleep 60 &
  local holder=$!
  mkdir -p "$FAKE_HOME/Library/Caches/gitleaks-audit.lock"
  printf 'pid=%s\nhost=%s\nstarted=1\n' "$holder" "$(/bin/hostname)" >"$FAKE_HOME/Library/Caches/gitleaks-audit.lock/owner"
  run_audit --run
  kill "$holder" 2>/dev/null
  assert_failure 75
  [[ "$(scans)" -eq 0 ]]
}

LOCKD() { printf '%s' "$FAKE_HOME/Library/Caches/gitleaks-audit.lock"; }
# age_path <path> <hours>: set mtime N hours in the past (real clock).
age_path() { touch -t "$(/bin/date -v-"$2"H +%Y%m%d%H%M.%S)" "$1"; }

@test "gitleaks-audit: failing to publish lock owner metadata releases the lock and exits 1 with an error notification" {
  mkrepo alpha
  cat >"$STUBS/mv" <<'EOF'
#!/bin/bash
case "${@: -1}" in */gitleaks-audit.lock/owner) exit 1 ;; esac
exec /bin/mv "$@"
EOF
  chmod +x "$STUBS/mv"
  run_audit --run
  assert_failure 1
  [[ ! -e "$(LOCKD)" ]]
  [[ "$(scans)" -eq 0 ]]
  run notifies
  assert_output --partial "error"
  # The next run (mv healthy again) is not blocked by a leftover lock.
  rm "$STUBS/mv"
  run_audit --run
  assert_success
}

@test "gitleaks-audit: a crash mid-publish (only owner.tmp.* left) blocks while fresh, is reclaimed once stale" {
  mkrepo alpha
  mkdir -p "$(LOCKD)"
  printf 'pid=1
' >"$(LOCKD)/owner.tmp.4242"
  run_audit --run
  assert_failure 75
  [[ "$(scans)" -eq 0 ]]
  [[ -e "$(LOCKD)/owner.tmp.4242" ]]
  age_path "$(LOCKD)" 7
  run_audit --run
  assert_success
  assert_output --partial "reclaiming"
  [[ "$(scans)" -eq 1 ]]
  [[ ! -e "$(LOCKD)" ]]
}

@test "gitleaks-audit: an ambiguous lock (empty, or unparseable owner) is 75 while fresh and reclaimed when older than 6h" {
  mkrepo alpha
  mkdir -p "$(LOCKD)"
  run_audit --run
  assert_failure 75
  age_path "$(LOCKD)" 7
  run_audit --run
  assert_success
  assert_output --partial "reclaiming"

  mkdir -p "$(LOCKD)"
  printf 'garbage\n' >"$(LOCKD)/owner"
  age_path "$(LOCKD)" 5
  run_audit --run
  assert_failure 75
  age_path "$(LOCKD)" 7
  run_audit --run
  assert_success
  [[ ! -e "$(LOCKD)" ]]
}

@test "gitleaks-audit: a dead-pid lock with leftover owner.tmp.* is reclaimed" {
  mkrepo alpha
  sleep 0 &
  local dead=$!
  wait "$dead"
  mkdir -p "$(LOCKD)"
  printf 'pid=%s\nhost=%s\nstarted=1\n' "$dead" "$(/bin/hostname)" >"$(LOCKD)/owner"
  printf 'x\n' >"$(LOCKD)/owner.tmp.777"
  run_audit --run
  assert_success
  assert_output --partial "reclaiming"
  [[ ! -e "$(LOCKD)" ]]
}

@test "gitleaks-audit: a live lock held for more than a day notifies; a fresh one does not" {
  mkrepo alpha
  sleep 60 &
  local holder=$!
  mkdir -p "$(LOCKD)"
  printf 'pid=%s\nhost=%s\nstarted=%s\n' "$holder" "$(/bin/hostname)" "$(($(/bin/date -u +%s) - 3600))" >"$(LOCKD)/owner"
  run_audit --run
  assert_failure 75
  run notifies
  assert_output ""
  printf 'pid=%s\nhost=%s\nstarted=%s\n' "$holder" "$(/bin/hostname)" "$(($(/bin/date -u +%s) - 2 * 86400))" >"$(LOCKD)/owner"
  run_audit --run
  kill "$holder" 2>/dev/null
  assert_failure 75
  run notifies
  assert_output --partial "lock held"
  [[ "$(scans)" -eq 0 ]]
}

PENDING() { printf '%s' "$STATE/pending-announce"; }

@test "gitleaks-audit: a baseline announcement that fails to notify stays pending and is retried by the next (unchanged) run" {
  mkrepo alpha
  findings alpha 2
  echo 1 >"$FIX/osascript_rc"
  run_audit --run
  assert_success
  assert_no_marker
  [[ -s "$(PENDING)" ]]
  grep -q 'pending' "$LOGF"
  run cat "$(PENDING)"
  assert_output --partial "baselined"
  assert_output --partial "alpha"
  # Next run: nothing changed, osascript healthy -> retried, then cleared.
  rm "$FIX/osascript_rc"
  : >"$CALLS"
  run_audit --run
  assert_success
  [[ "$(scans)" -eq 0 ]]
  assert_output --partial "pending"
  run notifies
  assert_output --partial "2 existing findings in 1 repos baselined"
  [[ ! -e "$(PENDING)" ]]
  # And then it is quiet.
  : >"$CALLS"
  run_audit --run
  run notifies
  assert_output ""
}

@test "gitleaks-audit: a missing osascript or --no-notify keeps the announcement pending" {
  mkrepo alpha
  findings alpha 1
  # A notifier that is not on PATH (the real /usr/bin/osascript would be).
  run --separate-stderr env -i HOME="$FAKE_HOME" TMPDIR="$TMPD" CALLS="$CALLS" FIX="$FIX" MARKER="$MARKER" \
    GITLEAKS_AUDIT_BASE_PATH="$STUBS:/usr/bin:/bin:/usr/sbin:/sbin" GITLEAKS_AUDIT_NOW="$NOW" \
    GITLEAKS_AUDIT_NOTIFIER=no-such-notifier /bin/bash "$SCRIPT" --run </dev/null 3>&-
  assert_success
  [[ -s "$(PENDING)" ]]
  run notifies
  assert_output ""
  run_audit --run --no-notify
  [[ -s "$(PENDING)" ]]
  run notifies
  assert_output ""
  : >"$CALLS"
  run_audit --run
  run notifies
  assert_output --partial "1 existing findings in 1 repos baselined"
  [[ ! -e "$(PENDING)" ]]
}

@test "gitleaks-audit: a successful notification leaves nothing pending" {
  mkrepo alpha
  findings alpha 1
  run_audit --run
  run notifies
  assert_output --partial "baselined"
  [[ ! -e "$(PENDING)" ]]
}

@test "gitleaks-audit: undelivered NEW findings stay pending; the retry run exits 0 but still announces them" {
  mkrepo alpha
  findings alpha 1
  run_audit --run
  commit_in alpha
  findings alpha 2
  echo 1 >"$FIX/osascript_rc"
  run_audit --run
  assert_failure 10
  run cat "$(PENDING)"
  assert_output --partial "new"
  rm "$FIX/osascript_rc"
  : >"$CALLS"
  run_audit --run
  assert_success
  run notifies
  assert_output --partial "1 NEW"
  [[ ! -e "$(PENDING)" ]]
}

@test "gitleaks-audit: --no-notify suppresses notifications" {
  mkrepo alpha
  findings alpha 1
  run_audit --run --no-notify
  assert_success
  run notifies
  assert_output ""
}

@test "gitleaks-audit: missing gitleaks is an error" {
  mkrepo alpha
  rm "$STUBS/gitleaks"
  run_audit --run
  assert_failure 1
}

@test "gitleaks-audit: log above the cap is rotated to .1" {
  mkrepo alpha
  mkdir -p "$(dirname "$LOGF")"
  head -c 1100000 /dev/zero | tr '\0' 'x' >"$LOGF"
  run_audit --run
  assert_success
  [[ -f "$LOGF.1" ]]
  [[ "$(/usr/bin/stat -f %z "$LOGF")" -lt 1048576 ]]
}

# --- report / status ----------------------------------------------------------

@test "gitleaks-audit: --report groups repo -> rule -> file:line (commit short) and gives rotation guidance" {
  mkrepo alpha
  mkrepo "space repo"
  findings alpha 3
  findings "space repo" 1
  run_audit --run
  run_audit --report
  assert_success
  assert_no_marker
  assert_line --regexp '^== alpha \(3 findings\)'
  assert_line --regexp '^  aws-access-token \(2\)'
  assert_line --regexp '^    src/f1\.txt:1 \(00000000\)'
  assert_line --regexp '^    src/f3\.txt:3 \(00000000\)'
  assert_line --regexp '^  generic-api-key \(1\)'
  assert_line --regexp '^== space repo \(1 findings\)'
  assert_output --partial "otate"
}

@test "gitleaks-audit: --report with no state says so and exits 0" {
  run_audit --report
  assert_success
  assert_output --partial "no audit state"
}

@test "gitleaks-audit: --status reports loaded/not loaded and the plist path" {
  run_audit --status
  assert_success
  assert_line "agent: not loaded (gui/$(id -u)/com.skwid138.gitleaks-audit)"
  assert_output --partial "Library/LaunchAgents/com.skwid138.gitleaks-audit.plist"
  echo 0 >"$FIX/launchctl_print_rc"
  run_audit --status
  assert_success
  assert_line "agent: loaded (gui/$(id -u)/com.skwid138.gitleaks-audit)"
}

# --- install / uninstall --------------------------------------------------------

PLIST() { printf '%s' "$FAKE_HOME/Library/LaunchAgents/com.skwid138.gitleaks-audit.plist"; }
plist_get() { /usr/bin/plutil -extract "$1" "${2:-json}" -o - "$(PLIST)"; }

@test "gitleaks-audit: --install renders a lint-clean plist (11:00 daily, --run, RunAtLoad false) and bootstraps it" {
  run_audit --install
  assert_success
  /usr/bin/plutil -lint "$(PLIST)"
  local script_abs
  script_abs="$(cd "$BATS_TEST_DIRNAME/../personal" && pwd)/gitleaks-audit.sh"
  run plist_get ProgramArguments
  assert_output "[\"\/bin\/bash\",\"${script_abs//\//\\/}\",\"--run\"]"
  run plist_get Label raw
  assert_output "com.skwid138.gitleaks-audit"
  run plist_get StartCalendarInterval
  assert_output '{"Hour":11,"Minute":0}'
  run plist_get RunAtLoad raw
  assert_output "false"
  # The scan runs in its own process group, which launchd's job-group kill
  # does not reach: give the TERM trap time to reap it (GRACE 5s) before
  # launchd escalates to SIGKILL (default ExitTimeOut is 5s).
  run plist_get ExitTimeOut raw
  assert_output "30"
  run plist_get EnvironmentVariables.PATH raw
  assert_output --regexp '(^|:)/opt/homebrew/bin(:|$)'
  assert_output --regexp '(^|:)/usr/bin(:|$)'
  run plist_get EnvironmentVariables.HOME raw
  assert_output "$FAKE_HOME"
  local uid
  uid="$(id -u)"
  run grep '^launchctl' "$CALLS"
  assert_output "$(printf '%s\n' \
    "launchctl print gui/$uid/com.skwid138.gitleaks-audit" \
    "launchctl enable gui/$uid/com.skwid138.gitleaks-audit" \
    "launchctl bootstrap gui/$uid $(PLIST)")"
  run grep -c 'kickstart' "$CALLS"
  assert_output "0"
}

@test "gitleaks-audit: --install XML-escapes HOME and removes the plist when bootstrap fails" {
  FAKE_HOME="$T/h&o<me x"
  mkdir -p "$FAKE_HOME"
  run_audit --install
  assert_success
  /usr/bin/plutil -lint "$(PLIST)"
  run plist_get EnvironmentVariables.HOME raw
  assert_output "$FAKE_HOME"
  echo 5 >"$FIX/launchctl_bootstrap_rc"
  run_audit --install
  assert_failure 1
  [[ ! -e "$(PLIST)" ]]
}

@test "gitleaks-audit: --uninstall boots out a loaded agent and removes the plist" {
  mkdir -p "$(dirname "$(PLIST)")"
  echo '<plist/>' >"$(PLIST)"
  echo 0 >"$FIX/launchctl_print_rc"
  run_audit --uninstall
  assert_success
  [[ ! -e "$(PLIST)" ]]
  grep -q '^launchctl bootout gui/[0-9]*/com.skwid138.gitleaks-audit$' "$CALLS"
}

@test "gitleaks-audit: refuses to run as root" {
  cat >"$STUBS/id" <<'EOF'
#!/bin/bash
if [[ "${1-}" == "-u" ]]; then echo 0; else /usr/bin/id "$@"; fi
EOF
  chmod +x "$STUBS/id"
  run_audit --install
  assert_failure 1
  [[ "$stderr" == *"refusing to run as root"* ]]
  run grep -c '^launchctl' "$CALLS"
  assert_output "0"
}
