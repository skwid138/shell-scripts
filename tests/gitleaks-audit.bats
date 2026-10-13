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
  mkdir -p "$CODE" "$STUBS" "$FIX" "$TMPD" "$T/fixture-home"
  : >"$CALLS"

  # The real binary (type -P ignores the git() fixture wrapper below).
  REAL_GIT="$(type -P git)"
  [[ "$REAL_GIT" == /* ]] || skip "no git binary on PATH"
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
  touch "$FIX/b.go" 2>/dev/null
  for f in "$FIX/gc.pid" "$FIX/leader.pid"; do
    [[ -s "$f" ]] && kill -KILL "$(cat "$f")" 2>/dev/null
  done
  # Restore permissions/ACLs a failed assertion may have left behind.
  /bin/chmod -RN "$BATS_TEST_TMPDIR" 2>/dev/null
  /bin/chmod -R u+rwx "$BATS_TEST_TMPDIR" 2>/dev/null
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
[[ -x "$FIX/during.$repo" ]] && "$FIX/during.$repo"
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
rc="$(cat "$FIX/osascript_rc" 2>/dev/null || echo 0)"
# Test seam: runs after a (successful) delivery, e.g. to obstruct the state.
[[ "$rc" -eq 0 && -x "$FIX/after_notify" ]] && "$FIX/after_notify"
exit "$rc"
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

# run_audit_env [args...]: run_audit, passing through GITLEAKS_AUDIT_RECLAIM_WAIT,
# GITLEAKS_AUDIT_PERL and GITLEAKS_AUDIT_TEST_HOOK.
run_audit_env() {
  run --separate-stderr env -i HOME="$FAKE_HOME" TMPDIR="$TMPD" CALLS="$CALLS" FIX="$FIX" \
    MARKER="$MARKER" GITLEAKS_AUDIT_BASE_PATH="$STUBS:/usr/bin:/bin:/usr/sbin:/sbin" \
    GITLEAKS_AUDIT_NOW="$NOW" GITLEAKS_AUDIT_TIMEOUT="$TIMEOUT" GITLEAKS_AUDIT_KILL_GRACE="$GRACE" \
    GITLEAKS_AUDIT_RECLAIM_WAIT="${GITLEAKS_AUDIT_RECLAIM_WAIT:-10}" \
    GITLEAKS_AUDIT_PERL="${GITLEAKS_AUDIT_PERL:-/usr/bin/perl}" \
    GITLEAKS_AUDIT_TEST_HOOK="${GITLEAKS_AUDIT_TEST_HOOK:-}" \
    /bin/bash "$SCRIPT" "$@" </dev/null 3>&-
}

# run_audit [args...]: hermetic env, /bin/bash, no stdin. stderr separate.
run_audit() {
  run --separate-stderr env -i HOME="$FAKE_HOME" TMPDIR="$TMPD" CALLS="$CALLS" FIX="$FIX" \
    MARKER="$MARKER" GITLEAKS_CONFIG=/x/ambient.toml GITLEAKS_CONFIG_TOML='title="ambient"' \
    GITLEAKS_AUDIT_BASE_PATH="$STUBS:/usr/bin:/bin:/usr/sbin:/sbin" \
    GITLEAKS_AUDIT_NOW="$NOW" GITLEAKS_AUDIT_TIMEOUT="$TIMEOUT" GITLEAKS_AUDIT_KILL_GRACE="$GRACE" \
    /bin/bash "$SCRIPT" "$@" </dev/null 3>&-
}

# git: fixture git never sees the real HOME, global/system config, or the
# real global gitleaks config hook (commits also pass --no-verify).
git() {
  HOME="$T/fixture-home" GIT_CONFIG_GLOBAL=/dev/null GIT_CONFIG_NOSYSTEM=1 \
    GIT_AUTHOR_NAME=t GIT_AUTHOR_EMAIL=t@e GIT_COMMITTER_NAME=t GIT_COMMITTER_EMAIL=t@e \
    command git "$@"
}

# mkrepo <rel>: real git repo with one commit under ~/code.
mkrepo() {
  local d="$CODE/$1"
  mkdir -p "$d"
  git -C "$d" init -q -b main
  git -C "$d" commit -q --no-verify --allow-empty -m init
}

commit_in() { # <rel> [branch]
  git -C "$CODE/$1" commit -q --no-verify --allow-empty -m "c $RANDOM"
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

@test "gitleaks-audit: --help says dry runs read state but never write it" {
  # Dry runs read pending counts, last_full and snapshots to report what
  # --run would do; the help must not claim they never read state.
  run_audit --help
  assert_success
  refute_output --partial "never read"
  assert_output --partial "never write, merge, or clear it"
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
  git -C "$CODE/alpha" commit -q --no-verify -m f
  run_audit --run
  echo v2 >"$CODE/alpha/f"
  git -C "$CODE/alpha" stash -q
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
  git -C "$T/wt alpha" commit -q --no-verify --allow-empty -m detached
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
  [[ "$(/usr/bin/stat -f %Lp "$(PENDING)")" == "600" ]]
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

# --- lock: liveness across hostname changes, serialized reclamation ----------

# bg_audit <outfile-prefix> [VAR=val...] -- [args...]: start a hermetic audit
# in the background; sets BG_PID.
bg_audit() {
  local pfx="$1"
  shift
  local envs=()
  while [[ $# -gt 0 && "$1" != "--" ]]; do
    envs+=("$1")
    shift
  done
  shift
  env -i HOME="$FAKE_HOME" TMPDIR="$TMPD" CALLS="$CALLS" FIX="$FIX" MARKER="$MARKER" \
    GITLEAKS_AUDIT_BASE_PATH="$STUBS:/usr/bin:/bin:/usr/sbin:/sbin" GITLEAKS_AUDIT_NOW="$NOW" \
    GITLEAKS_AUDIT_KILL_GRACE=1 "${envs[@]}" \
    /bin/bash "$SCRIPT" "$@" </dev/null >"$pfx.out" 2>"$pfx.err" 3>&- &
  BG_PID=$!
}

wait_for() { # <command...>: poll up to ~10s
  local i
  for i in $(seq 1 100); do
    "$@" && return 0
    sleep 0.1
  done
  return 1
}
owner_pid_is() { [[ "$(sed -n 's/^pid=//p' "$(LOCKD)/owner" 2>/dev/null)" == "$1" ]]; }

# write_pause_hook <path> <phase> <name>: test hook that, on <phase>, touches
# $FIX/<name>.paused and waits for $FIX/<name>.go. Other phases pass through.
write_pause_hook() {
  cat >"$1" <<HOOK
#!/bin/bash
[[ "\$1" == "$2" ]] || exit 0
touch "$FIX/$3.paused"
while [[ ! -e "$FIX/$3.go" ]]; do sleep 0.05; done
HOOK
  chmod +x "$1"
}

stale_dead_lock() {
  sleep 0 &
  local dead=$!
  wait "$dead"
  mkdir -p "$(LOCKD)"
  printf 'pid=%s\nhost=%s\nstarted=1\n' "$dead" "$(/bin/hostname)" >"$(LOCKD)/owner"
}

@test "gitleaks-audit: a live owner pid recorded under a different hostname is busy however old the lock (never reclaimed)" {
  mkrepo alpha
  sleep 60 &
  local holder=$!
  mkdir -p "$(LOCKD)"
  printf 'pid=%s\nhost=%s\nstarted=%s\n' "$holder" "old-network-name.local" "$(($(/bin/date -u +%s) - 30 * 3600))" >"$(LOCKD)/owner"
  cp "$(LOCKD)/owner" "$T/owner.before"
  age_path "$(LOCKD)" 30
  run_audit --run
  kill "$holder" 2>/dev/null
  assert_failure 75
  refute_output --partial "reclaiming"
  cmp -s "$(LOCKD)/owner" "$T/owner.before"
  [[ "$(scans)" -eq 0 ]]
  # Held for more than a day: the long-busy notification still fires.
  run notifies
  assert_output --partial "lock held"
}

@test "gitleaks-audit: a dead owner pid under a different hostname is reclaimed" {
  mkrepo alpha
  sleep 0 &
  local dead=$!
  wait "$dead"
  mkdir -p "$(LOCKD)"
  printf 'pid=%s\nhost=other.local\nstarted=1\n' "$dead" >"$(LOCKD)/owner"
  run_audit --run
  assert_success
  assert_output --partial "reclaiming"
  [[ ! -e "$(LOCKD)" ]]
}

@test "gitleaks-audit: two stale-lock contenders: the earlier decider revalidates and cannot delete the winner's lock" {
  mkrepo alpha
  stale_dead_lock
  touch "$FIX/hang.alpha"
  write_pause_hook "$T/hook-b" reclaim-decided b
  # B judges the lock stale, then pauses before reclaiming.
  bg_audit "$T/b" GITLEAKS_AUDIT_TEST_HOOK="$T/hook-b" GITLEAKS_AUDIT_TIMEOUT=2 -- --run
  local b=$BG_PID
  wait_for test -e "$FIX/b.paused"
  # A reclaims, publishes its owner, and holds the lock while scanning.
  bg_audit "$T/a" GITLEAKS_AUDIT_TIMEOUT=60 -- --run
  local a=$BG_PID
  wait_for owner_pid_is "$a"
  wait_for test -s "$FIX/leader.pid"
  touch "$FIX/b.go"
  local brc=0
  wait "$b" || brc=$?
  # A's lock survives B, and B is busy.
  local survived=0
  owner_pid_is "$a" && kill -0 "$a" && survived=1
  kill -TERM "$a"
  wait "$a" || true
  [[ "$survived" -eq 1 ]]
  [[ "$brc" -eq 75 ]]
  ! grep -q 'reclaiming' "$T/b.out"
}

@test "gitleaks-audit: reclamation is serialized: a contender is busy while another holds the reclaim critical section" {
  mkrepo alpha
  stale_dead_lock
  write_pause_hook "$T/hook-b" reclaim-locked b
  bg_audit "$T/b" GITLEAKS_AUDIT_TEST_HOOK="$T/hook-b" -- --run
  local b=$BG_PID
  wait_for test -e "$FIX/b.paused"
  # A also judges the dead-pid lock stale but cannot enter the critical section.
  GITLEAKS_AUDIT_RECLAIM_WAIT=1 run_audit_env --run
  local arc=$status aout=$output
  [[ -d "$(LOCKD)" ]]
  touch "$FIX/b.go"
  local brc=0
  wait "$b" || brc=$?
  [[ "$arc" -eq 75 ]]
  [[ "$aout" == *"another run is reclaiming"* ]]
  [[ "$brc" -eq 0 ]]
  grep -q 'reclaiming' "$T/b.out"
  [[ ! -e "$(LOCKD)" ]]
}

@test "gitleaks-audit: a reclaimer killed inside the critical section does not wedge later runs" {
  mkrepo alpha
  stale_dead_lock
  write_pause_hook "$T/hook-b" reclaim-locked b
  bg_audit "$T/b" GITLEAKS_AUDIT_TEST_HOOK="$T/hook-b" -- --run
  local b=$BG_PID
  wait_for test -e "$FIX/b.paused"
  kill -KILL "$b"
  wait "$b" 2>/dev/null || true
  GITLEAKS_AUDIT_RECLAIM_WAIT=1 run_audit_env --run
  touch "$FIX/b.go"
  assert_success
  assert_output --partial "reclaiming"
}

# --- lock: infrastructure failures are errors (exit 1), not contention (75) ----

# hold_reclaim_mutex: hold an exclusive flock on the reclaim file from a test
# process (as a concurrent reclaimer would); sets HOLDER_PID.
hold_reclaim_mutex() {
  /usr/bin/perl -e 'use Fcntl qw(:flock); open(my $f, ">>", $ARGV[0]) or die; flock($f, LOCK_EX) or die; open(my $r, ">", $ARGV[1]) or die; close $r; sleep 30' \
    "$(LOCKD).reclaim" "$T/mutex.held" </dev/null >/dev/null 2>&1 3>&- &
  HOLDER_PID=$!
  wait_for test -e "$T/mutex.held"
}

@test "gitleaks-audit: an unwritable or uncreatable lock parent exits 1 with an error notification, not 75" {
  mkrepo alpha
  local caches="$FAKE_HOME/Library/Caches"
  mkdir -p "$caches"
  chmod 555 "$caches"
  run_audit --run
  chmod 755 "$caches"
  assert_failure 1
  assert_output --partial "ERROR: lock: cannot create $(LOCKD): $caches is not a writable directory"
  refute_output --partial "skipping run"
  [[ "$(scans)" -eq 0 ]]
  run notifies
  assert_output --partial "error"

  # A parent that cannot be created (a file is in the way) is the same error.
  rmdir "$caches"
  : >"$caches"
  : >"$CALLS"
  run_audit --run
  assert_failure 1
  assert_output --partial "ERROR: lock: cannot create $(LOCKD): $caches is not a writable directory"
  run notifies
  assert_output --partial "error"

  rm -f "$caches"
  run_audit --run
  assert_success
}

@test "gitleaks-audit: a non-directory in the way of the lock dir exits 1, not 75" {
  # The parent is writable, but mkdir of the lock dir fails and no lock dir
  # exists: nobody can ever hold this lock, so it is an error, not contention.
  mkrepo alpha
  mkdir -p "$FAKE_HOME/Library/Caches"
  : >"$(LOCKD)"
  run_audit --run
  assert_failure 1
  assert_output --partial "ERROR: lock: cannot create $(LOCKD): a non-directory is in the way"
  refute_output --partial "skipping run"
  [[ "$(scans)" -eq 0 ]]
  run notifies
  assert_output --partial "error"

  # A (dangling) symlink is never made by a contender either.
  rm -f "$(LOCKD)"
  ln -s "$T/nowhere" "$(LOCKD)"
  run_audit --run
  assert_failure 1
  assert_output --partial "ERROR: lock: cannot create $(LOCKD): a non-directory is in the way"
}

# fn_src <name>: the source of one top-level function of the script.
fn_src() { sed -n "/^$1() {/,/^}/p" "$SCRIPT"; }

# classify <lock-path> [perl]: lock_path_type's single line for one path.
classify_path() {
  fn_src lock_path_type >"$T/fn.sh"
  [[ -s "$T/fn.sh" ]] || return 1
  LOCK_DIR="$1" PERL="${2:-/usr/bin/perl}" PATH=/opt/homebrew/opt/coreutils/libexec/gnubin:/usr/bin:/bin \
    /bin/bash -c '. "$1"; lock_path_type' _ "$T/fn.sh"
}

# lstat_errno_perl <out> <ERRNO-name>: a perl wrapper whose lstat (only in
# the lock-path helper, matched by its code) fails with that errno; every
# other perl invocation runs the real /usr/bin/perl.
lstat_errno_perl() {
  mkdir -p "$T/perl5-$2"
  cat >"$T/perl5-$2/FailLstat.pm" <<EOF
package FailLstat;
use Errno ();
BEGIN { *CORE::GLOBAL::lstat = sub { \$! = Errno::$2(); return () }; }
1;
EOF
  cat >"$1" <<EOF
#!/bin/bash
case "\$*" in *lstat*) exec /usr/bin/perl -I"$T/perl5-$2" -MFailLstat "\$@" ;; esac
exec /usr/bin/perl "\$@"
EOF
  chmod +x "$1"
}

@test "gitleaks-audit: lock_path_type classifies the lock path with one lstat (absent/dir/other)" {
  local d="$T/cls" f got
  mkdir -p "$d/dir"
  : >"$d/file"
  ln -s "$d/dir" "$d/link-dir"
  ln -s "$d/nowhere" "$d/dangling"
  mkfifo "$d/fifo"
  for f in absent:absent dir:dir file:other link-dir:other dangling:other fifo:other; do
    got="$(classify_path "$d/${f%%:*}")"
    [[ "$got" == "${f#*:}" ]] || {
      echo "${f%%:*}: expected ${f#*:}, got '$got'" >&3
      false
    }
  done
}

@test "gitleaks-audit: lock_path_type: only ENOENT is absent; EACCES, ENOTDIR and EIO are errors" {
  local d="$T/cls" got
  mkdir -p "$d/sealed/inner"
  : >"$d/file"
  run classify_path "$d/no-such-lock"
  assert_output "absent"
  chmod 000 "$d/sealed"
  run classify_path "$d/sealed/inner"
  chmod 755 "$d/sealed"
  assert_output --regexp '^error Permission denied \(errno 13\)$'
  run classify_path "$d/file/lock"
  assert_output --regexp '^error Not a directory \(errno 20\)$'
  lstat_errno_perl "$T/eio-perl" EIO
  run classify_path "$d/no-such-lock" "$T/eio-perl"
  assert_output --regexp '^error Input/output error \(errno 5\)$'
  # The real errno decides, not a guess from the path: an injected ENOENT
  # is absent even though the path exists.
  lstat_errno_perl "$T/enoent-perl" ENOENT
  run classify_path "$d/file" "$T/enoent-perl"
  assert_output "absent"
}

@test "gitleaks-audit: lock_path_type: a missing, failing, silent or garbled lstat helper is an error" {
  local d="$T/cls"
  mkdir -p "$d"
  run classify_path "$d/x" "$T/no-such-perl"
  assert_output --regexp "^error lstat helper $T/no-such-perl failed \(exit 127\)$"
  printf '#!/bin/bash\nexit 3\n' >"$T/fail-perl"
  printf '#!/bin/bash\nexit 0\n' >"$T/silent-perl"
  printf '#!/bin/bash\necho directory\n' >"$T/garbled-perl"
  printf '#!/bin/bash\nprintf "dir\\nother\\n"\n' >"$T/twoline-perl"
  chmod +x "$T/fail-perl" "$T/silent-perl" "$T/garbled-perl" "$T/twoline-perl"
  run classify_path "$d/x" "$T/fail-perl"
  assert_output "error lstat helper $T/fail-perl failed (exit 3)"
  local p
  for p in silent garbled twoline; do
    run classify_path "$d/x" "$T/$p-perl"
    assert_output "error lstat helper $T/$p-perl gave unexpected output"
  done
}

@test "gitleaks-audit: an lstat error at the lock path (EACCES, ENOTDIR, EIO) is a lock infrastructure ERROR (exit 1, notified), never absent" {
  mkrepo alpha
  local e
  for e in EACCES ENOTDIR EIO; do
    lstat_errno_perl "$T/$e-perl" "$e"
    : >"$CALLS"
    GITLEAKS_AUDIT_PERL="$T/$e-perl" run_audit_env --run
    assert_failure 1
    assert_output --partial "ERROR: lock: cannot classify $(LOCKD):"
    refute_output --partial "skipping run"
    [[ "$(scans)" -eq 0 ]]
    [[ ! -e "$(LOCKD)" ]]
    grep -q "ERROR: lock: cannot classify" "$LOGF"
    run notifies
    assert_output --partial "error"
  done
  # Control: an injected ENOENT is absent, so the run proceeds normally.
  lstat_errno_perl "$T/ENOENT-perl" ENOENT
  GITLEAKS_AUDIT_PERL="$T/ENOENT-perl" run_audit_env --run
  assert_success
  [[ "$(scans)" -eq 1 ]]
}

@test "gitleaks-audit: a failing or garbled lstat helper at the lock path is a lock infrastructure ERROR (exit 1)" {
  mkrepo alpha
  cat >"$T/lstat-fails-perl" <<'EOF'
#!/bin/bash
case "$*" in *lstat*) exit 9 ;; esac
exec /usr/bin/perl "$@"
EOF
  cat >"$T/lstat-garbled-perl" <<'EOF'
#!/bin/bash
case "$*" in *lstat*) echo "Directory"; exit 0 ;; esac
exec /usr/bin/perl "$@"
EOF
  chmod +x "$T/lstat-fails-perl" "$T/lstat-garbled-perl"
  GITLEAKS_AUDIT_PERL="$T/lstat-fails-perl" run_audit_env --run
  assert_failure 1
  assert_output --partial "ERROR: lock: cannot classify $(LOCKD): lstat helper $T/lstat-fails-perl failed (exit 9)"
  [[ "$(scans)" -eq 0 ]]
  run notifies
  assert_output --partial "error"
  GITLEAKS_AUDIT_PERL="$T/lstat-garbled-perl" run_audit_env --run
  assert_failure 1
  assert_output --partial "ERROR: lock: cannot classify $(LOCKD): lstat helper $T/lstat-garbled-perl gave unexpected output"
  [[ "$(scans)" -eq 0 ]]
}

# take_lock_harness <hook>: source the real lock functions and call take_lock
# once against $(LOCKD); prints "rc=<n> held=<LOCK_HELD>".
take_lock_harness() {
  local fn
  : >"$T/tl.sh"
  for fn in test_hook lock_path_type lock_path_blocked write_lock_owner take_lock; do
    fn_src "$fn" >>"$T/tl.sh"
  done
  env -i LOCK_DIR="$(LOCKD)" PERL=/usr/bin/perl TEST_HOOK="$1" PATH=/usr/bin:/bin \
    /bin/bash -c '. "$1"; LOCK_MKDIR_TRIES=3 THIS_HOST=h LOCK_HELD=0 LOCK_ERR=""
      take_lock; rc=$?; echo "rc=$rc held=$LOCK_HELD"' _ "$T/tl.sh"
}

# release_after_failed_mkdir_hook <path>: a hook that, at the FIRST
# lock-classify following a failed mkdir, removes the lock dir (a holder
# releasing right after the classifier's single observation) and records it.
release_after_failed_mkdir_hook() {
  cat >"$1" <<HOOK
#!/bin/bash
echo "\$1" >>"$T/trace"
case "\$1" in
  lock-mkdir-failed) touch "$T/mkdir-failed" ;;
  lock-classify)
    if [[ -e "$T/mkdir-failed" && ! -e "$T/released" ]]; then
      rm -rf "$(LOCKD)" && touch "$T/released" && echo released >>"$T/trace"
    fi
    ;;
esac
exit 0
HOOK
  chmod +x "$1"
}

@test "gitleaks-audit: take_lock decides from the cached post-failed-mkdir classification (direct return)" {
  # The lock dir exists, so take_lock's mkdir fails and its classification
  # sees a directory. The hook then removes the dir. The cached decision is
  # "busy" (1, nothing held); a fresh stat would see it absent, retry the
  # mkdir and wrongly report it held.
  mkdir -p "$(LOCKD)"
  release_after_failed_mkdir_hook "$T/hook"
  run take_lock_harness "$T/hook"
  assert_output "rc=1 held=0"
  [[ -e "$T/released" ]]
  run cat "$T/trace"
  assert_output "$(printf '%s\n' lock-mkdir lock-mkdir-failed lock-classify released)"
}

@test "gitleaks-audit: a run reuses take_lock's cached classification (busy return reaches the inspection)" {
  # Runtime trace: a live holder's lock; after our failed mkdir the
  # classification sees the dir, then the holder releases (hook) and, at our
  # next mkdir, re-takes it. With the cached decision take_lock returns busy
  # at once, so the inspection sees the release and the retry meets the
  # re-taken lock ("re-taken by a concurrent run"). A re-stat inside
  # take_lock would instead loop on its own and end at "held by live pid".
  mkrepo alpha
  sleep 60 &
  local holder=$!
  mkdir -p "$(LOCKD)"
  printf 'pid=%s\nhost=h\nstarted=%s\n' "$holder" "$(/bin/date -u +%s)" >"$(LOCKD)/owner"
  cat >"$T/hook" <<HOOK
#!/bin/bash
echo "\$1" >>"$T/trace"
case "\$1" in
  lock-mkdir-failed) touch "$T/mkdir-failed" ;;
  lock-classify)
    if [[ -e "$T/mkdir-failed" && ! -e "$T/released" ]]; then
      rm -rf "$(LOCKD)" && touch "$T/released" && echo released >>"$T/trace"
    fi
    ;;
  lock-mkdir)
    if [[ -e "$T/released" && ! -e "$T/retaken" ]]; then
      mkdir "$(LOCKD)" && printf 'pid=%s\nhost=h\nstarted=1\n' "$holder" >"$(LOCKD)/owner" && touch "$T/retaken"
    fi
    ;;
esac
exit 0
HOOK
  chmod +x "$T/hook"
  GITLEAKS_AUDIT_TEST_HOOK="$T/hook" run_audit_env --run
  kill "$holder" 2>/dev/null
  assert_failure 75
  [[ -e "$T/released" && -e "$T/retaken" ]]
  assert_output --partial "was re-taken by a concurrent run; skipping run"
  refute_output --partial "held by live pid"
  refute_output --partial "ERROR"
  [[ "$(scans)" -eq 0 ]]
}

@test "gitleaks-audit: lock-path classification never re-observes the path (structural guard)" {
  # One observation only: a holder releasing between two stat calls (-e then
  # -d) would turn a normal release into "a non-directory is in the way".
  local fn
  run fn_src lock_path_type
  assert_output --partial 'lstat($ARGV[0])'
  [[ "$(grep -o 'lstat(' <<<"$output" | grep -c .)" -eq 1 ]]
  assert_output --partial '"$LOCK_DIR"'
  refute_output --partial '/usr/bin/stat'
  refute_output --regexp '(^|[^l])stat\('
  for fn in lock_path_blocked take_lock reclaim_lock; do
    run fn_src "$fn"
    [[ -n "$output" ]]
    refute_output --regexp '\[\[[^]]*-[edLhfp] +"\$LOCK_DIR"'
  done
}

@test "gitleaks-audit: the lock path is classified from one observation even if a holder releases right after it" {
  # A bare (fresh) lock dir exists. The lock-classify hook runs right after
  # the classifier's single observation and removes the dir once, as a
  # holder releasing would. The decision must follow that observation (a
  # directory: contention), so the run proceeds; a second stat after the
  # hook would see the path gone and misreport it.
  mkrepo alpha
  mkdir -p "$(LOCKD)"
  cat >"$T/hook-classify" <<HOOK
#!/bin/bash
[[ "\$1" == lock-classify && ! -e "$T/released" ]] || exit 0
rmdir "$(LOCKD)" && touch "$T/released"
HOOK
  chmod +x "$T/hook-classify"
  GITLEAKS_AUDIT_TEST_HOOK="$T/hook-classify" run_audit_env --run
  [[ -e "$T/released" ]]
  assert_success
  refute_output --partial "ERROR"
  [[ "$(scans)" -eq 1 ]]
}

@test "gitleaks-audit: a holder releasing between every failed mkdir and its check is contention (75), never an error" {
  # Deterministic interleaving via the test hook: before each mkdir another
  # run takes the lock; after our mkdir fails it releases it again, so every
  # post-failure check finds no lock. A lock path that is absent after a
  # failed mkdir must never by itself be an error.
  mkrepo alpha
  mkdir -p "$FAKE_HOME/Library/Caches"
  cat >"$T/hook-race" <<HOOK
#!/bin/bash
case "\$1" in
  lock-mkdir) mkdir "$(LOCKD)" && echo take >>"$T/race.log" ;;
  lock-mkdir-failed) rmdir "$(LOCKD)" && echo release >>"$T/race.log" ;;
esac
exit 0
HOOK
  chmod +x "$T/hook-race"
  GITLEAKS_AUDIT_TEST_HOOK="$T/hook-race" run_audit_env --run
  assert_failure 75
  refute_output --partial "ERROR"
  assert_output --partial "skipping run"
  [[ "$(grep -c release "$T/race.log")" -ge 2 ]]
  [[ "$(scans)" -eq 0 ]]
  run notifies
  assert_output ""
}

@test "gitleaks-audit: a missing or failing reclaim helper (perl) exits 1 and leaves the stale lock alone" {
  mkrepo alpha
  stale_dead_lock
  cp "$(LOCKD)/owner" "$T/owner.before"
  # Missing perl: an error, never contention. It is already needed for the
  # lock-path lstat, which runs before the reclaim mutex. (No notification
  # can be delivered either: the notifier also runs through perl's setpgrp.)
  GITLEAKS_AUDIT_PERL="$T/no-such-perl" run_audit_env --run
  assert_failure 1
  assert_output --partial "ERROR: lock: cannot classify $(LOCKD): lstat helper $T/no-such-perl failed"
  refute_output --partial "skipping run"
  grep -q "ERROR: lock: cannot classify" "$LOGF"
  cmp -s "$(LOCKD)/owner" "$T/owner.before"
  [[ "$(scans)" -eq 0 ]]

  # perl present but failing at the reclaim mutex: error with notification.
  cat >"$T/bad-perl" <<'EOF'
#!/bin/bash
case "$*" in *flock*) echo "perl: broken" >&2; exit 255 ;; esac
exec /usr/bin/perl "$@"
EOF
  chmod +x "$T/bad-perl"
  GITLEAKS_AUDIT_PERL="$T/bad-perl" run_audit_env --run
  assert_failure 1
  assert_output --partial "ERROR: lock: reclaim mutex helper $T/bad-perl failed (exit 255)"
  cmp -s "$(LOCKD)/owner" "$T/owner.before"
  [[ "$(scans)" -eq 0 ]]
  run notifies
  assert_output --partial "error"

  # With a working helper the same stale lock is reclaimed.
  run_audit_env --run
  assert_success
  assert_output --partial "reclaiming"
}

@test "gitleaks-audit: a reclaim flock failing with an errno other than EWOULDBLOCK exits 1, not 75" {
  # Inject a flock that fails with EIO into the real helper code (only the
  # flock invocation is wrapped). Retrying that until the timeout would turn
  # an infrastructure error into contention.
  mkrepo alpha
  stale_dead_lock
  cp "$(LOCKD)/owner" "$T/owner.before"
  mkdir -p "$T/perl5"
  cat >"$T/perl5/FailFlock.pm" <<'EOF'
package FailFlock;
use Errno ();
BEGIN { *CORE::GLOBAL::flock = sub { $! = Errno::EIO(); return 0 }; }
1;
EOF
  cat >"$T/eio-perl" <<EOF
#!/bin/bash
case "\$*" in *flock*) exec /usr/bin/perl -I"$T/perl5" -MFailFlock "\$@" ;; esac
exec /usr/bin/perl "\$@"
EOF
  chmod +x "$T/eio-perl"
  GITLEAKS_AUDIT_PERL="$T/eio-perl" GITLEAKS_AUDIT_RECLAIM_WAIT=1 run_audit_env --run
  assert_failure 1
  assert_output --partial "ERROR: lock: reclaim mutex flock on $(LOCKD).reclaim failed (exit 4"
  refute_output --partial "another run is reclaiming"
  cmp -s "$(LOCKD)/owner" "$T/owner.before"
  [[ "$(scans)" -eq 0 ]]
  run notifies
  assert_output --partial "error"
}

@test "gitleaks-audit: a stale lock that cannot be removed under the mutex exits 1, not 75" {
  mkrepo alpha
  stale_dead_lock
  : >"$(LOCKD)/unexpected-entry"
  run_audit --run
  assert_failure 1
  assert_output --partial "ERROR: lock: cannot remove stale lock $(LOCKD)"
  refute_output --partial "skipping run"
  [[ -e "$(LOCKD)/unexpected-entry" ]]
  [[ "$(scans)" -eq 0 ]]
  run notifies
  assert_output --partial "error"
}

@test "gitleaks-audit: an unopenable reclaim file exits 1, not 75" {
  mkrepo alpha
  stale_dead_lock
  mkdir -p "$(LOCKD).reclaim"
  run_audit --run
  assert_failure 1
  assert_output --partial "ERROR: lock: cannot open reclaim mutex file $(LOCKD).reclaim"
  [[ -d "$(LOCKD)" ]]
  run notifies
  assert_output --partial "error"
}

@test "gitleaks-audit: genuine contention (live holder, reclaim mutex held) stays 75 and is not an error" {
  mkrepo alpha
  sleep 60 &
  local holder=$!
  mkdir -p "$(LOCKD)"
  printf 'pid=%s\nhost=%s\nstarted=%s\n' "$holder" "$(/bin/hostname)" "$(/bin/date -u +%s)" >"$(LOCKD)/owner"
  run_audit --run
  kill "$holder" 2>/dev/null
  assert_failure 75
  assert_output --partial "skipping run"
  refute_output --partial "ERROR"

  rm -rf "$(LOCKD)"
  stale_dead_lock
  hold_reclaim_mutex
  GITLEAKS_AUDIT_RECLAIM_WAIT=1 run_audit_env --run
  kill "$HOLDER_PID" 2>/dev/null
  assert_failure 75
  assert_output --partial "another run is reclaiming"
  refute_output --partial "ERROR"
  [[ -d "$(LOCKD)" ]]
  run notifies
  assert_output ""
}

# --- dry runs never write state, even on fatal paths ---------------------------

state_listing() { find "$STATE" -print0 | xargs -0 /usr/bin/stat -f '%N %i %Fm %z' | LC_ALL=C sort; }

@test "gitleaks-audit: a dry run that fails fatally leaves pending-announce and the state dir untouched" {
  mkrepo alpha
  findings alpha 1
  echo 1 >"$FIX/osascript_rc"
  run_audit --run
  [[ -s "$STATE/pending-announce" ]]
  rm "$FIX/osascript_rc"
  local before h
  before="$(state_listing)"
  h="$(shasum "$STATE/pending-announce")"
  # Fatal 1: unreadable exclude config.
  mkdir -p "$(dirname "$CONFIG")"
  echo alpha >"$CONFIG"
  chmod 000 "$CONFIG"
  run_audit
  chmod 600 "$CONFIG"
  assert_failure 1
  [[ "$(state_listing)" == "$before" ]]
  [[ "$(shasum "$STATE/pending-announce")" == "$h" ]]
  # Fatal 2: missing required tool.
  rm "$CONFIG"
  mv "$STUBS/gitleaks" "$T/gitleaks.off"
  run_audit
  mv "$T/gitleaks.off" "$STUBS/gitleaks"
  assert_failure 1
  [[ "$(state_listing)" == "$before" ]]
  [[ "$(shasum "$STATE/pending-announce")" == "$h" ]]
}

# --- unparseable [extend] path ---------------------------------------------------

@test "gitleaks-audit: an [extend] path with escapes or a non-simple string warns and forces a rescan every run" {
  mkrepo alpha
  mkrepo beta
  mkrepo gamma
  mkrepo delta
  printf '[extend]\npath = "base\\u002etoml"\n' >"$CODE/alpha/.gitleaks.toml"
  printf "[extend]\npath = '''multi.toml'''\n" >"$CODE/gamma/.gitleaks.toml"
  printf '[extend]\npath = bare.toml\n' >"$CODE/delta/.gitleaks.toml"
  printf '[extend]\npath = "plain.toml"\n' >"$CODE/beta/.gitleaks.toml"
  grep -qF '\u002e' "$CODE/alpha/.gitleaks.toml"
  run_audit --run
  assert_success
  assert_output --partial "WARNING alpha"
  assert_output --partial "WARNING gamma"
  assert_output --partial "WARNING delta"
  refute_output --partial "WARNING beta"
  grep -q 'WARNING alpha' "$LOGF"
  : >"$CALLS"
  run_audit --run
  assert_success
  run scanned_repos
  assert_output "$(printf '%s\n' alpha delta gamma)"
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

# --- private, per-repo suppressions (lib/gitleaks-private.sh) -----------------

PBASE() { printf '%s' "$FAKE_HOME/.config/gitleaks-audit"; }
PSTORE() { printf '%s' "$(PBASE)/repos/$1"; }
MANIFEST() { printf '%s' "$(PBASE)/protected"; }
state_dir() { dirname "$(grep -lx "$1" "$STATE"/repos/*/path)"; }

PTOML='[extend]
useDefault = true

[[allowlists]]
targetRules = ['"'"'generic-api-key'"'"']
condition = "AND"
paths = ['"'"'^src/x\.json$'"'"']
regexTarget = "line"
regexes = ['"'"'^\n?[ \t]*"key": "[0-9a-f]{40}",?$'"'"']'

# pstore <rel> [toml] [ignore]: a valid (700/600) private store entry, plus
# an (empty) protected manifest unless one exists already.
pstore() {
  local d p
  d="$(PSTORE "$1")"
  /bin/chmod 755 "$FAKE_HOME"
  mkdir -p "$d"
  /bin/chmod 700 "$FAKE_HOME/.config" "$(PBASE)" "$(PBASE)/repos"
  p="$d"
  while [[ "$p" != "$(PBASE)/repos" ]]; do
    /bin/chmod 700 "$p"
    p="$(dirname "$p")"
  done
  if [[ -n "${2-}" ]]; then
    printf '%s\n' "$2" >"$d/gitleaks.toml"
    /bin/chmod 600 "$d/gitleaks.toml"
  fi
  if [[ -n "${3-}" ]]; then
    printf '%s\n' "$3" >"$d/gitleaksignore"
    /bin/chmod 600 "$d/gitleaksignore"
  fi
  [[ -e "$(MANIFEST)" ]] || manifest
}

# manifest [lines...]: (re)write the protected manifest.
manifest() {
  mkdir -p "$(PBASE)"
  /bin/chmod 700 "$FAKE_HOME/.config" "$(PBASE)"
  {
    echo "# <rel> <full fingerprint>"
    [[ $# -gt 0 ]] && printf '%s\n' "$@"
  } >"$(MANIFEST)"
  /bin/chmod 600 "$(MANIFEST)"
}

# fp <i> [tag]: the stub's fingerprint for finding i (see findings()).
fp() { printf '%040d:src/f%d.txt:rule-%s:%d' "$1" "$1" "${2:-a}" "$1"; }

# findings_only <repo> <i...>: stub returns rc 10 + exactly findings i...
findings_only() {
  local repo="$1" i sep=""
  shift
  {
    printf '['
    for i in "$@"; do
      printf '%s{"RuleID":"%s","File":"src/f%d.txt","Commit":"%040d","StartLine":%d,"Fingerprint":"%s","Secret":"%s","Match":"m","Line":"l","Description":"d"}' \
        "$sep" "$([[ $((i % 2)) -eq 0 ]] && echo generic-api-key || echo aws-access-token)" "$i" "$i" "$i" "$(fp "$i")" "$MARKER"
      sep=","
    done
    printf ']\n'
  } >"$FIX/json.$repo"
  if [[ $# -gt 0 ]]; then echo 10 >"$FIX/rc.$repo"; else echo 0 >"$FIX/rc.$repo"; fi
}

scan_argv() { grep "^gitleaks git .* | pwd=$CODE/$1 | " "$CALLS" | tail -n1; }

@test "gitleaks-audit: validated private files are passed to the scan as --config / --gitleaks-ignore-path (existing files only)" {
  mkrepo alpha
  mkrepo beta
  mkrepo gamma
  pstore alpha "$PTOML" "$(printf '%040d' 9):src/x.json:generic-api-key:3"
  pstore gamma "" "$(printf '%040d' 9):src/x.json:generic-api-key:3"
  run_audit --run
  assert_success
  run scan_argv alpha
  assert_output --regexp "^gitleaks git --redact=100 --no-banner --exit-code=10 --report-format=json --report-path=[^ ]+ --config $(PSTORE alpha)/gitleaks.toml --gitleaks-ignore-path $(PSTORE alpha)/gitleaksignore \. \| "
  run scan_argv gamma
  assert_output --regexp "^gitleaks git --redact=100 --no-banner --exit-code=10 --report-format=json --report-path=[^ ]+ --gitleaks-ignore-path $(PSTORE gamma)/gitleaksignore \. \| "
  run scan_argv beta
  assert_output --regexp "^gitleaks git --redact=100 --no-banner --exit-code=10 --report-format=json --report-path=[^ ]+ \. \| "
}

@test "gitleaks-audit: --help documents the private store, protected manifest, and flags" {
  run_audit --help
  assert_success
  assert_output --partial ".config/gitleaks-audit/repos/<rel>/gitleaks.toml"
  assert_output --partial "--gitleaks-ignore-path"
  assert_output --partial ".config/gitleaks-audit/protected"
  assert_output --partial "GITLEAKS_SUPPRESS_DIR"
}

@test "gitleaks-audit: a repo with an unsafe store is a repo ERROR: others are scanned, exit 1, no state written for it" {
  mkrepo alpha
  mkrepo beta
  pstore alpha "$PTOML"
  /bin/chmod g+w "$(PSTORE alpha)/gitleaks.toml"
  run_audit --run
  assert_failure 1
  assert_output --partial "ERROR alpha: private suppression store"
  assert_output --partial "writable"
  run scanned_repos
  assert_output "beta"
  run ! grep -qx alpha "$STATE"/repos/*/path
  run notifies
  assert_output --partial "error"
  assert_no_marker
}

@test "gitleaks-audit: store validation runs before the unchanged skip (a chmod-only change is caught)" {
  mkrepo alpha
  pstore alpha "$PTOML"
  run_audit --run
  assert_success
  run_audit
  assert_line --regexp '^ *skip +alpha +\(unchanged\)'
  local d p
  d="$(state_dir alpha)"
  cp "$d/snapshot" "$T/snap.before"
  # Parent-dir changes are not part of the snapshot: only validation that
  # runs before the unchanged check can catch them.
  for p in "$(PSTORE alpha)" "$FAKE_HOME/.config"; do
    /bin/chmod g+w "$p"
    : >"$CALLS"
    run_audit --run
    /bin/chmod g-w "$p"
    assert_failure 1
    assert_output --partial "ERROR alpha: private suppression store"
    refute_output --regexp 'skip +alpha'
    [[ "$(scans)" -eq 0 ]]
    cmp -s "$d/snapshot" "$T/snap.before"
  done
  /bin/chmod +a "group:everyone allow write" "$(PSTORE alpha)/gitleaks.toml" || skip "no ACL support"
  run_audit --run
  /bin/chmod -N "$(PSTORE alpha)/gitleaks.toml"
  assert_failure 1
  assert_output --partial "ACL"
  run_audit --run
  assert_success
  assert_line --regexp '^ *skip +alpha +\(unchanged\)'
  # The file's own mode too.
  /bin/chmod 640 "$(PSTORE alpha)/gitleaks.toml"
  /bin/chmod g+w "$(PSTORE alpha)/gitleaks.toml"
  : >"$CALLS"
  run_audit --run
  assert_failure 1
  assert_output --partial "ERROR alpha: private suppression store"
  [[ "$(scans)" -eq 0 ]]
  cmp -s "$d/snapshot" "$T/snap.before"
  # A mode change that is still valid is a snapshot change: rescanned.
  /bin/chmod 400 "$(PSTORE alpha)/gitleaks.toml"
  run_audit
  assert_line --regexp '^ *scan +alpha +\(private suppressions changed\)'
}

@test "gitleaks-audit: a repaired store is re-detected without any ref change" {
  mkrepo alpha
  run_audit --run
  assert_success
  pstore alpha "$PTOML"
  /bin/chmod o+w "$(PSTORE alpha)"
  run_audit --run
  assert_failure 1
  /bin/chmod 700 "$(PSTORE alpha)"
  run_audit
  assert_line --regexp '^ *scan +alpha +\(private suppressions changed\)'
  : >"$CALLS"
  run_audit --run
  assert_success
  run scanned_repos
  assert_output "alpha"
}

@test "gitleaks-audit: a store error during the weekly full pass keeps last_full; the repaired run completes it" {
  mkrepo alpha
  mkrepo beta
  run_audit --run
  grep -qx "last_full=$NOW" "$STATE/meta"
  pstore beta "$PTOML"
  /bin/chmod g+w "$(PSTORE beta)/gitleaks.toml"
  NOW=$((2000000000 + 7 * 86400))
  : >"$CALLS"
  run_audit --run
  assert_failure 1
  assert_output --partial "full pass incomplete"
  grep -qx "last_full=2000000000" "$STATE/meta"
  /bin/chmod 600 "$(PSTORE beta)/gitleaks.toml"
  : >"$CALLS"
  run_audit --run
  assert_success
  [[ "$(scans)" -eq 2 ]]
  grep -qx "last_full=$NOW" "$STATE/meta"
}

@test "gitleaks-audit: the protected manifest is required while repos/ exists (run ERROR, scans still run)" {
  mkrepo alpha
  pstore alpha "$PTOML"
  rm "$(MANIFEST)"
  run_audit --run
  assert_failure 1
  assert_output --partial "protected manifest"
  assert_output --partial "missing"
  run scanned_repos
  assert_output "alpha"
  run notifies
  assert_output --partial "error"
  # An invalid manifest is the same kind of error.
  manifest "alpha deadbeef:src/f1.txt:rule-a:1"
  run_audit --run
  assert_failure 1
  assert_output --partial "protected manifest"
  # Both absent: the feature is off and the run is clean.
  rm -rf "$(PBASE)"
  run_audit --run
  assert_success
}

@test "gitleaks-audit: a protected fingerprint missing from a scan is an ERROR and the snapshot is not advanced" {
  mkrepo alpha
  findings_only alpha 1 2
  pstore alpha "$PTOML"
  manifest "alpha $(fp 1)"
  run_audit --run
  assert_success
  local d
  d="$(state_dir alpha)"
  cp "$d/snapshot" "$T/snap.before"
  # The protected finding disappears (as if suppressed).
  commit_in alpha
  findings_only alpha 2
  run_audit --run
  assert_failure 1
  assert_output --partial "protected fingerprint $(fp 1)"
  cmp -s "$d/snapshot" "$T/snap.before"
  run_audit
  assert_line --regexp '^ *scan +alpha +'
  run_audit --report
  assert_output --partial "MISSING"
}

@test "gitleaks-audit: protected entries are checked every run, also for unchanged repos (against the accepted findings)" {
  mkrepo alpha
  findings_only alpha 1 2
  pstore alpha "$PTOML"
  manifest "alpha $(fp 1)"
  run_audit --run
  assert_success
  # The accepted findings lose the protected fingerprint without any input
  # change (e.g. state written by an older version): still an error daily.
  local d
  d="$(state_dir alpha)"
  grep -v "$(fp 1)" "$d/findings.tsv" >"$T/f" && cp "$T/f" "$d/findings.tsv"
  # Keep the state self-consistent (as an older or buggy writer could have
  # left it): only settled findings are trusted without a rescan.
  sed "s/^findings .*/findings $(shasum -a 256 <"$d/findings.tsv" | cut -d' ' -f1)/" "$d/provenance" >"$T/p" &&
    cp "$T/p" "$d/provenance"
  : >"$CALLS"
  run_audit --run
  assert_failure 1
  [[ "$(scans)" -eq 0 ]]
  assert_output --partial "protected fingerprint $(fp 1)"
  run_audit --run
  assert_failure 1
}

@test "gitleaks-audit: a protected manifest change on an unchanged repo is detected and checked" {
  mkrepo alpha
  findings_only alpha 1 2
  pstore alpha "$PTOML"
  run_audit --run
  assert_success
  manifest "alpha $(fp 1)"
  run_audit
  assert_line --regexp '^ *scan +alpha +\(private suppressions changed\)'
  run_audit --run
  assert_success
  manifest "alpha $(fp 1)" "alpha $(fp 7)"
  run_audit --run
  assert_failure 1
  assert_output --partial "protected fingerprint $(fp 7)"
}

@test "gitleaks-audit: a protected entry for an excluded, missing, or undiscovered repo is an ERROR" {
  mkrepo alpha
  mkrepo buzz
  pstore alpha "$PTOML"
  mkdir -p "$(dirname "$CONFIG")"
  echo buzz >"$CONFIG"
  manifest "buzz $(fp 1)" "ghost/repo $(fp 2)"
  run_audit --run
  assert_failure 1
  assert_output --partial "protected manifest lists buzz"
  assert_output --partial "protected manifest lists ghost/repo"
  run scanned_repos
  assert_output "alpha"
}

@test "gitleaks-audit: a repo .gitleaks.toml plus a private gitleaks.toml is a repo ERROR" {
  mkrepo alpha
  pstore alpha "$PTOML"
  echo 'title = "repo"' >"$CODE/alpha/.gitleaks.toml"
  run_audit --run
  assert_failure 1
  assert_output --partial "ERROR alpha: private suppression store"
  assert_output --partial ".gitleaks.toml"
  [[ "$(scans)" -eq 0 ]]
}

@test "gitleaks-audit: suppress then unsuppress: the findings come back as known, never NEW" {
  mkrepo alpha
  findings_only alpha 1 2 3
  run_audit --run
  assert_success
  # Suppressed via the private store: fewer findings, nothing new.
  pstore alpha "$PTOML"
  findings_only alpha 1
  : >"$CALLS"
  run_audit --run
  assert_success
  [[ "$(grep -c . "$(state_dir alpha)/findings.tsv")" -eq 1 ]]
  # Unsuppressed again: the same fingerprints return as known.
  rm -rf "$(PSTORE alpha)"
  findings_only alpha 1 2 3
  : >"$CALLS"
  run_audit --run
  assert_success
  [[ "$(scans)" -eq 1 ]]
  run notifies
  assert_output ""
  refute_output --partial "NEW"
}

@test "gitleaks-audit: provenance is published with the findings before the snapshot; a provenance write failure keeps the old snapshot" {
  mkrepo alpha
  findings_only alpha 1
  pstore alpha "$PTOML"
  run_audit --run
  assert_success
  local d
  d="$(state_dir alpha)"
  [[ -f "$d/provenance" ]]
  grep -q "^private gitleaks.toml $(shasum -a 256 <"$(PSTORE alpha)/gitleaks.toml" | cut -d' ' -f1)$" "$d/provenance"
  grep -q '^private gitleaksignore absent$' "$d/provenance"
  grep -q "^findings $(shasum -a 256 <"$d/findings.tsv" | cut -d' ' -f1)$" "$d/provenance"
  run_audit --report
  assert_line --regexp '^== alpha \(1 findings\)'
  refute_output --partial "unsettled"
  refute_output --partial "stale"
  cp "$d/snapshot" "$T/snap.before"
  # The store changes; publishing the provenance fails.
  printf '# edited\n' >>"$(PSTORE alpha)/gitleaks.toml"
  mkdir "$d/provenance.tmp"
  run_audit --run
  assert_failure 1
  assert_output --partial "state write failed"
  cmp -s "$d/snapshot" "$T/snap.before"
  rmdir "$d/provenance.tmp"
  : >"$CALLS"
  run_audit --run
  assert_success
  [[ "$(scans)" -eq 1 ]]
  run_audit --report
  refute_output --partial "unsettled"
  refute_output --partial "stale"
}

# crash_hook <phase>: a test hook that SIGKILLs the audit at <phase>.
# crash_hook <phase>: a test hook that, at <phase>, writes the sentinel
# $T/crashed.<phase> and SIGKILLs the audit (assert_crashed checks both).
crash_hook() {
  rm -f "$T/crashed.$1"
  cat >"$T/hook-crash" <<HOOK
#!/bin/bash
if [[ "\$1" == "$1" ]]; then
  : >"$T/crashed.$1"
  kill -KILL "\$PPID"
fi
exit 0
HOOK
  chmod +x "$T/hook-crash"
}
# assert_crashed <phase>: the last run died by SIGKILL at exactly <phase>.
assert_crashed() {
  [[ -e "$T/crashed.$1" && "$status" -eq 137 ]] || {
    echo "the run did not die at $1 (status $status)" >&3
    return 1
  }
}

@test "gitleaks-audit: a crash after findings.tsv is replaced, with UNCHANGED inputs, is rescanned (unsettled), not skipped" {
  mkrepo alpha
  findings_only alpha 1
  pstore alpha "$PTOML"
  run_audit --run
  assert_success
  local d
  d="$(state_dir alpha)"
  cp "$d/snapshot" "$T/snap.before"
  # Nothing about the inputs changes; a forced scan sees a new finding and
  # dies between replacing findings.tsv and the provenance.
  findings_only alpha 1 3
  crash_hook publish-findings
  GITLEAKS_AUDIT_TEST_HOOK="$T/hook-crash" run_audit_env --full
  assert_crashed publish-findings
  cmp -s "$d/snapshot" "$T/snap.before"
  [[ "$(grep -c . "$d/findings.tsv")" -eq 2 ]]
  run_audit --report
  assert_line --regexp '^== alpha \(2 findings\).*unsettled'
  run_audit
  assert_line --regexp '^ *scan +alpha +\(unsettled'
  # known was merged before the crash point, so the rescan finds nothing
  # new; the NEW announcement recorded before the merge is delivered (a run
  # that only retries a pending announcement exits 0).
  : >"$CALLS"
  run_audit --run
  assert_success
  [[ "$(scans)" -eq 1 ]]
  run notifies
  assert_output --partial "1 NEW finding(s) in 1 repo(s)"
  run_audit --report
  refute_output --partial "unsettled"
  run_audit --run
  assert_success
  assert_line --regexp '^ *skip +alpha +\(unchanged\)'
}

@test "gitleaks-audit: a crash between the provenance and the snapshot is unsettled and rescanned (HEAD, protected entries, or file mode changed)" {
  local variant d
  for variant in head protected mode; do
    rm -rf "$CODE/alpha" "$STATE" "$(PBASE)" "$FAKE_HOME/Library/Caches/gitleaks-audit.lock"
    mkrepo alpha
    findings_only alpha 1
    pstore alpha "$PTOML"
    run_audit --run
    assert_success
    d="$(state_dir alpha)"
    case "$variant" in
      head) commit_in alpha ;;
      protected) manifest "alpha $(fp 1)" ;;
      mode) /bin/chmod 400 "$(PSTORE alpha)/gitleaks.toml" ;;
    esac
    cp "$d/snapshot" "$T/snap.before"
    crash_hook publish-provenance
    GITLEAKS_AUDIT_TEST_HOOK="$T/hook-crash" run_audit_env --run
    assert_crashed publish-provenance
    cmp -s "$d/snapshot" "$T/snap.before"
    run_audit --report
    assert_line --regexp '^== alpha \(1 findings\).*unsettled'
    run_audit
    assert_line --regexp '^ *scan +alpha +\('
    : >"$CALLS"
    run_audit --run
    assert_success
    [[ "$(scans)" -eq 1 ]]
    run_audit --report
    refute_output --partial "unsettled"
  done
}

@test "gitleaks-audit: --report lists a repo whose store was removed after a scan used it (stale), even with 0 findings" {
  mkrepo alpha
  pstore alpha "$PTOML"
  run_audit --run
  assert_success
  rm -rf "$(PSTORE alpha)"
  run_audit --report
  assert_success
  assert_line --regexp '^== alpha \(0 findings\).*stale'
}

@test "gitleaks-audit: --report before any audit run lists private stores and protected entries as not yet scanned" {
  mkrepo alpha
  pstore alpha "$PTOML"
  manifest "alpha $(fp 1)"
  [[ ! -e "$STATE" ]]
  run_audit --report
  assert_success
  assert_line --regexp '^== alpha \(not scanned yet\).*private: gitleaks\.toml'
  assert_line --regexp "^  alpha +src/f1\.txt:1 rule-a \(00000000\) not scanned yet$"
  [[ ! -e "$STATE" ]]
}

@test "gitleaks-audit: a protected manifest edited during a scan keeps that scan's snapshot from advancing" {
  mkrepo alpha
  findings_only alpha 1
  pstore alpha "$PTOML"
  run_audit --run
  assert_success
  local d
  d="$(state_dir alpha)"
  commit_in alpha
  cp "$d/snapshot" "$T/snap.before"
  printf '#!/bin/bash\necho "# edited mid-scan" >>"%s"\n' "$(MANIFEST)" >"$FIX/during.alpha"
  chmod +x "$FIX/during.alpha"
  run_audit --run
  assert_success
  assert_output --partial "protected manifest changed during the scan"
  cmp -s "$d/snapshot" "$T/snap.before"
  rm "$FIX/during.alpha"
  : >"$CALLS"
  run_audit --run
  assert_success
  [[ "$(scans)" -eq 1 ]]
  ! cmp -s "$d/snapshot" "$T/snap.before"
}

@test "gitleaks-audit: a store that stops validating during the scan is a repo ERROR and nothing is published" {
  mkrepo alpha
  findings_only alpha 1
  pstore alpha "$PTOML"
  run_audit --run
  assert_success
  local d f
  d="$(state_dir alpha)"
  commit_in alpha
  findings_only alpha 1 3
  for f in snapshot findings.tsv provenance known; do cp "$d/$f" "$T/$f.before"; done
  # A parent dir turns group-writable mid-scan (not part of the snapshot).
  printf '#!/bin/bash\n/bin/chmod g+w "%s"\n' "$(PSTORE alpha)" >"$FIX/during.alpha"
  chmod +x "$FIX/during.alpha"
  run_audit --run
  assert_failure 1
  assert_output --partial "ERROR alpha: private suppression store changed during the scan"
  for f in snapshot findings.tsv provenance known; do cmp -s "$d/$f" "$T/$f.before"; done
  run notifies
  refute_output --partial "NEW"
}

@test "gitleaks-audit: protected rels are matched literally (no escape decoding)" {
  fn_src protected_fps >"$T/fn.sh"
  [[ -s "$T/fn.sh" ]]
  printf '%s\t%s\n' 'dir\name' "$(fp 1)" 'dir' "$(fp 2)" >"$T/prot"
  run env PROT_FILE="$T/prot" /bin/bash -c '. "$1"; protected_fps "$2"' _ "$T/fn.sh" 'dir\name'
  assert_output "$(fp 1)"
}

@test "gitleaks-audit: protected manifest rels with a backslash or control character are a run ERROR" {
  mkrepo alpha
  pstore alpha "$PTOML"
  local bad
  for bad in 'we\ird' "$(printf 'ta\tb')" "$(printf 'c\001r')"; do
    manifest "$bad $(fp 1)"
    run_audit --run
    assert_failure 1
    assert_output --partial "backslash or control character"
  done
}

@test "gitleaks-audit: --report lists every repo with a private store (0 findings too), marks stale stores, flags repo .gitleaksignore, lists protected" {
  mkrepo alpha
  mkrepo beta
  mkrepo gamma
  findings_only beta 1 2
  pstore alpha "$PTOML"
  manifest "beta $(fp 1)"
  echo "$(fp 2)" >"$CODE/beta/.gitleaksignore"
  run_audit --run
  assert_success
  run_audit --report
  assert_success
  assert_line --regexp '^== alpha \(0 findings\).*private: gitleaks\.toml'
  assert_line --regexp '^== beta \(2 findings\).*repo \.gitleaksignore'
  refute_output --regexp '== gamma'
  assert_output --partial "Protected"
  assert_line --regexp "^  beta +src/f1\.txt:1 rule-a \(00000000\) present$"
  refute_output --partial "stale"
  printf '# edited\n' >>"$(PSTORE alpha)/gitleaks.toml"
  run_audit --report
  assert_line --regexp '^== alpha \(0 findings\).*stale'
  assert_no_marker
}

@test "gitleaks-audit: a dry run reports a store error and writes nothing" {
  mkrepo alpha
  pstore alpha "$PTOML"
  /bin/chmod g+w "$(PSTORE alpha)/gitleaks.toml"
  run_audit
  assert_success
  assert_line --regexp '^ *error +alpha +\(private suppression store'
  [[ ! -e "$STATE" ]]
  [[ ! -e "$LOGF" ]]
}

# --- private suppressions with the real gitleaks binary (history) ---------------

use_real_gitleaks() {
  local real
  real="$(command -v gitleaks 2>/dev/null)" || skip "gitleaks not installed"
  [[ -n "$real" && "$real" != "$STUBS/gitleaks" ]] || skip "gitleaks not installed"
  rm -f "$STUBS/gitleaks"
  ln -s "$real" "$STUBS/gitleaks"
}

# rcommit <rel> <path> <content>: commit a file (no hooks).
rcommit() {
  mkdir -p "$(dirname "$CODE/$1/$2")"
  printf '%s\n' "$3" >"$CODE/$1/$2"
  git -C "$CODE/$1" add -- "$2"
  git -C "$CODE/$1" commit -q --no-verify -m "add $2"
}
findings_tsv() { cat "$(state_dir "$1")/findings.tsv"; }

@test "gitleaks-audit (real gitleaks): a full-SHA private fingerprint suppresses a history finding; a short SHA is rejected" {
  use_real_gitleaks
  mkrepo alpha
  local key
  key="AKIA$(LC_ALL=C tr -dc 'A-Z2-7' </dev/urandom | head -c 16)"
  rcommit alpha creds.txt "aws_access_key_id = $key"
  run_audit --run
  assert_success
  local f
  f="$(cut -f5 "$(state_dir alpha)/findings.tsv")"
  [[ "$f" =~ ^[0-9a-f]{40}:creds\.txt:aws-access-token:1$ ]]
  # Short SHA: a store error (gitleaks would silently not match it).
  pstore alpha "" "${f:0:12}${f:40}"
  run_audit --run
  assert_failure 1
  assert_output --partial "gitleaksignore"
  # Full SHA: suppressed.
  pstore alpha "" "$f"
  run_audit --run
  assert_success
  [[ ! -s "$(state_dir alpha)/findings.tsv" ]]
  ! grep -rqF "$key" "$STATE" "$LOGF"
}

@test "gitleaks-audit (real gitleaks): a short-SHA fingerprint does not suppress in gitleaks itself (why the grammar requires full SHAs)" {
  [[ -n "$(command -v gitleaks)" ]] || skip "gitleaks not installed"
  mkrepo alpha
  local key full
  key="AKIA$(LC_ALL=C tr -dc 'A-Z2-7' </dev/urandom | head -c 16)"
  rcommit alpha creds.txt "aws_access_key_id = $key"
  full="$(git -C "$CODE/alpha" rev-parse HEAD):creds.txt:aws-access-token:1"
  echo "${full:0:12}${full:40}" >"$T/short.ignore"
  echo "$full" >"$T/full.ignore"
  local gl
  gl="$(command -v gitleaks)"
  # Hermetic: no ambient GITLEAKS_CONFIG*, HOME, or PATH.
  run env -i HOME="$FAKE_HOME" PATH="$STUBS:/usr/bin:/bin" "$gl" git --no-banner --redact=100 --exit-code=10 \
    --gitleaks-ignore-path "$T/short.ignore" "$CODE/alpha"
  [[ "$status" -eq 10 ]]
  run env -i HOME="$FAKE_HOME" PATH="$STUBS:/usr/bin:/bin" "$gl" git --no-banner --redact=100 --exit-code=10 \
    --gitleaks-ignore-path "$T/full.ignore" "$CODE/alpha"
  [[ "$status" -eq 0 ]]
}

@test "gitleaks-audit (real gitleaks): content-shaped allowlists suppress in history, but a second credential on the line still fires (both shapes)" {
  use_real_gitleaks
  mkrepo alpha
  local h a toml
  # Fixed (derived at runtime): random hex can fall under the entropy threshold.
  h="$(printf 'plan-f-fixture-1' | shasum | cut -c1-40)"
  a="$(LC_ALL=C tr -dc 'A-Za-z0-9' </dev/urandom | head -c 32)"
  toml='[extend]
useDefault = true

[[allowlists]]
targetRules = ['"'"'generic-api-key'"'"']
condition = "AND"
paths = ['"'"'^tools/tokens\.json$'"'"']
regexTarget = "line"
regexes = ['"'"'^\n?[ \t]*"key": "[0-9a-f]{40}",?$'"'"']

[[allowlists]]
targetRules = ['"'"'generic-api-key'"'"']
condition = "AND"
paths = ['"'"'^src/schema/models\.py$'"'"']
regexTarget = "line"
regexes = ['"'"'^\n? +(?:[a-z0-9_]+: [A-Za-z\[\]]+ = field\(metadata=\{"data_key": "[A-Za-z0-9]+"\}\)|(?:default=None, )?metadata=\{"data_key": "[A-Za-z0-9]+"\})$'"'"']'
  rcommit alpha tools/tokens.json "{
        \"key\": \"$h\",
        \"name\": \"x\"
}"
  rcommit alpha src/schema/models.py "class M:
    clicks: int = field(metadata={\"data_key\": \"fixtureColumnKqzVw7d\"})
    other: int = field(
        default=None, metadata={\"data_key\": \"fixtureColumnPmxRt9d\"}
    )"
  # Control: both shapes are findings without the store.
  run_audit --run
  assert_success
  run findings_tsv alpha
  assert_output --partial "tools/tokens.json"
  assert_output --partial "src/schema/models.py"
  pstore alpha "$toml"
  run_audit --run
  assert_success
  [[ ! -s "$(state_dir alpha)/findings.tsv" ]]
  # Same-line second credentials (both shapes) still fire in history.
  rcommit alpha tools/tokens.json "{
        \"key\": \"$h\", \"api_key\": \"$a\",
}"
  rcommit alpha src/schema/models.py "class M:
    clicks: int = field(metadata={\"data_key\": \"fixtureColumnKqzVw7d\"}); api_key = \"$a\""
  run_audit --run
  assert_failure 10
  run findings_tsv alpha
  assert_output --partial "tools/tokens.json"
  assert_output --partial "src/schema/models.py"
  run ! grep -rqF "$a" "$STATE" "$LOGF"
  ! grep -rqF "$h" "$STATE" "$LOGF"
}

@test "gitleaks-audit: a NEW finding from an interrupted publication (unchanged inputs) is announced exactly once, whatever the crash point" {
  local phase n
  for phase in publish-start publish-pending publish-known publish-findings publish-provenance publish-snapshot; do
    rm -rf "$CODE/alpha" "$STATE" "$(PBASE)" "$FAKE_HOME/Library/Caches/gitleaks-audit.lock"
    mkrepo alpha
    findings_only alpha 1
    run_audit --run
    assert_success
    # Same inputs, one extra fingerprint; the forced scan dies mid-publication.
    findings_only alpha 1 3
    crash_hook "$phase"
    GITLEAKS_AUDIT_TEST_HOOK="$T/hook-crash" run_audit_env --full
    assert_crashed "$phase"
    : >"$CALLS"
    # First recovery run: the open publication forces a rescan. Before the
    # pending write the rescan itself finds the NEW fingerprint (exit 10);
    # afterwards it is already pending and only delivered (exit 0).
    run_audit --run
    assert_line --regexp '^ *scan +alpha +\(unsettled'
    if [[ "$phase" == publish-start ]]; then
      assert_failure 10
    else
      assert_success
    fi
    run notifies
    assert_output --partial "1 NEW finding(s) in 1 repo(s)"
    run_audit --run
    assert_success
    run_audit --full
    assert_success
    n="$(grep -c 'NEW' "$CALLS" || true)"
    if [[ "$n" -ne 1 ]] || ! grep -q '1 NEW finding(s) in 1 repo(s)' "$CALLS"; then
      echo "$phase: NEW announced $n times" >&3
      false
    fi
    grep -qx "$(fp 3)" "$(state_dir alpha)/known"
    [[ ! -e "$STATE/pending-announce" ]]
    run_audit
    assert_line --regexp '^ *skip +alpha +\(unchanged\)'
  done
}

@test "gitleaks-audit: pending announcements are per fingerprint (idempotent) and the legacy count format is still read" {
  mkrepo alpha
  findings_only alpha 1 2
  echo 1 >"$FIX/osascript_rc"
  run_audit --run
  assert_success
  run cat "$STATE/pending-announce"
  assert_line "baselined	alpha	$(fp 1)"
  assert_line "baselined	alpha	$(fp 2)"
  # A pending file in the older "<kind> <count> <rel>" form still counts.
  printf 'new\t3\tlegacy repo\n' >>"$STATE/pending-announce"
  rm "$FIX/osascript_rc"
  : >"$CALLS"
  run_audit --run
  assert_success
  run notifies
  assert_output --partial "3 NEW finding(s) in 1 repo(s)"
  assert_output --partial "2 existing findings in 1 repos baselined"
}

@test "gitleaks-audit: migration: state without provenance (older version, no store) is rescanned once, silently, then skipped" {
  mkrepo alpha
  findings_only alpha 1 2
  run_audit --run
  assert_success
  local d
  d="$(state_dir alpha)"
  rm -f "$d/provenance" "$d/publishing"
  : >"$CALLS"
  run_audit --run
  assert_success
  [[ "$(scans)" -eq 1 ]]
  run notifies
  assert_output ""
  [[ -f "$d/provenance" ]]
  : >"$CALLS"
  run_audit --run
  assert_success
  [[ "$(scans)" -eq 0 ]]
  run notifies
  assert_output ""
}

@test "gitleaks-audit: --report lists a private store directory that holds no files, before and after a scan" {
  mkrepo alpha
  pstore alpha
  run_audit --report
  assert_success
  assert_line --regexp '^== alpha \(not scanned yet\).*private store dir: no files'
  run_audit --run
  assert_success
  run_audit --report
  assert_line --regexp '^== alpha \(0 findings\).*private store dir: no files'
}

@test "gitleaks-audit: findings from inputs that moved and then reverted are not trusted (provenance snapshot identity forces a rescan)" {
  mkrepo alpha
  findings_only alpha 1
  run_audit --run
  assert_success
  local d
  d="$(state_dir alpha)"
  cp "$d/snapshot" "$T/snap.before"
  # Inputs move (a new ref), and move back while gitleaks is scanning: the
  # snapshot is held back at the old inputs, which are current again.
  git -C "$CODE/alpha" branch tmp
  findings_only alpha 1 3
  printf '#!/bin/bash\ngit update-ref -d refs/heads/tmp\n' >"$FIX/during.alpha"
  chmod +x "$FIX/during.alpha"
  run_audit --run
  assert_output --partial "snapshot not advanced"
  cmp -s "$d/snapshot" "$T/snap.before"
  rm "$FIX/during.alpha"
  # Inputs equal the stored snapshot, but the published findings came from
  # other inputs: rescan, never skip.
  run_audit
  assert_line --regexp '^ *scan +alpha +\(unsettled'
  run_audit --report
  assert_line --regexp '^== alpha .*unsettled'
}

# new_notifications: how many notifications so far announced NEW findings.
new_notifications() { grep -c '^osascript .*NEW' "$CALLS" || true; }

@test "gitleaks-audit: a known write failure after the NEW finding was recorded announces it exactly once" {
  mkrepo alpha
  findings_only alpha 1
  run_audit --run
  assert_success
  local d
  d="$(state_dir alpha)"
  commit_in alpha
  findings_only alpha 1 3
  mkdir "$d/known.tmp"
  : >"$CALLS"
  run_audit --run
  assert_failure 1
  assert_output --partial "state write failed"
  run notifies
  assert_output --partial "1 NEW finding(s) in 1 repo(s)"
  # Delivered but not yet in known: kept (marked delivered), never re-counted.
  [[ -s "$STATE/pending-announce" ]]
  [[ "$(/usr/bin/stat -f %Lp "$STATE/pending-announce")" == "600" ]]
  rmdir "$d/known.tmp"
  run_audit --run
  assert_success
  run_audit --run
  assert_success
  run_audit --full
  assert_success
  [[ "$(new_notifications)" -eq 1 ]]
  grep -qx "$(fp 3)" "$d/known"
  [[ ! -e "$STATE/pending-announce" ]]
}

@test "gitleaks-audit: a pending-announcement write failure announces nothing yet, and the NEW finding exactly once later" {
  mkrepo alpha
  findings_only alpha 1
  run_audit --run
  assert_success
  commit_in alpha
  findings_only alpha 1 3
  mkdir "$STATE/pending-announce.tmp"
  : >"$CALLS"
  run_audit --run
  assert_failure 1
  [[ "$(new_notifications)" -eq 0 ]]
  run ! grep -qx "$(fp 3)" "$(state_dir alpha)/known"
  rmdir "$STATE/pending-announce.tmp"
  run_audit --run
  assert_failure 10
  run_audit --run
  assert_success
  run_audit --full
  assert_success
  [[ "$(new_notifications)" -eq 1 ]]
}

@test "gitleaks-audit: a marker-removal failure is an incomplete publication: error, rescan, no repeated NEW" {
  mkrepo alpha
  findings_only alpha 1
  run_audit --run
  assert_success
  local d
  d="$(state_dir alpha)"
  commit_in alpha
  findings_only alpha 1 3
  cat >"$T/hook-lockdir" <<HOOK
#!/bin/bash
[[ "\$1" == publish-snapshot ]] && /bin/chmod 500 "$d"
exit 0
HOOK
  chmod +x "$T/hook-lockdir"
  : >"$CALLS"
  GITLEAKS_AUDIT_TEST_HOOK="$T/hook-lockdir" run_audit_env --run
  /bin/chmod 700 "$d"
  assert_failure 1
  assert_output --partial "publication incomplete"
  refute_output --partial "old snapshot kept"
  [[ -e "$d/publishing" ]]
  run_audit
  assert_line --regexp '^ *scan +alpha +\(unsettled'
  run_audit --run
  assert_success
  run_audit --run
  assert_success
  assert_line --regexp '^ *skip +alpha +\(unchanged\)'
  [[ "$(new_notifications)" -eq 1 ]]
}

@test "gitleaks-audit: a known write failure during the first (baseline) scan announces the baseline exactly once" {
  mkrepo alpha
  findings_only alpha 1 2
  local d
  d="$STATE/repos/$(printf '%s' alpha | shasum -a 256 | cut -c1-16)"
  mkdir -p "$d/known.tmp"
  /bin/chmod 700 "$FAKE_HOME/Library" "$FAKE_HOME/Library/Application Support" "$STATE" "$STATE/repos" "$d"
  run_audit --run
  assert_failure 1
  run notifies
  assert_output --partial "2 existing findings in 1 repos baselined"
  rmdir "$d/known.tmp"
  run_audit --run
  assert_success
  run_audit --full
  assert_success
  [[ "$(grep -c '^osascript .*baselined' "$CALLS")" -eq 1 ]]
  [[ "$(grep -c '^osascript .*NEW' "$CALLS" || true)" -eq 0 ]]
  [[ "$(grep -c . "$d/known")" -eq 2 ]]
  [[ ! -e "$STATE/pending-announce" ]]
}

@test "gitleaks-audit: a pending rewrite failure after delivery is an ERROR (exit 1); the announcement repeats at most once, then settles" {
  mkrepo alpha
  findings_only alpha 1
  run_audit --run
  assert_success
  commit_in alpha
  findings_only alpha 1 3
  # Delivery succeeds, then the pending temp path is obstructed.
  printf '#!/bin/bash\nmkdir -p "%s"\n' "$STATE/pending-announce.tmp" >"$FIX/after_notify"
  chmod +x "$FIX/after_notify"
  : >"$CALLS"
  run_audit --run
  assert_failure 1
  assert_output --partial "ERROR: notification delivered but $STATE/pending-announce could not be updated"
  grep -q 'ERROR: notification delivered but' "$LOGF"
  grep -q 'exit=1' "$STATE/last-run"
  [[ "$(new_notifications)" -eq 1 ]]
  rm -f "$FIX/after_notify"
  rmdir "$STATE/pending-announce.tmp"
  # Documented exception: repeated once, then settled.
  run_audit --run
  assert_success
  [[ "$(new_notifications)" -eq 2 ]]
  [[ ! -e "$STATE/pending-announce" ]]
  run_audit --run
  assert_success
  run_audit --full
  assert_success
  [[ "$(new_notifications)" -eq 2 ]]
}

@test "gitleaks-audit: delivered status and pruning are per repo when two repos share a fingerprint" {
  mkrepo alpha
  mkrepo beta
  findings_only alpha 1
  findings_only beta 1
  run_audit --run
  assert_success
  commit_in alpha
  commit_in beta
  findings_only alpha 1 3
  findings_only beta 1 3
  local da db
  da="$(state_dir alpha)"
  db="$(state_dir beta)"
  mkdir "$da/known.tmp"
  : >"$CALLS"
  run_audit --run
  assert_failure 1
  run notifies
  assert_output --partial "2 NEW finding(s) in 2 repo(s)"
  # beta's fingerprint reached beta's known: settled and dropped. alpha's
  # identical fingerprint did not reach alpha's known: kept as delivered.
  run cat "$STATE/pending-announce"
  assert_output "new.delivered	alpha	$(fp 3)"
  grep -qx "$(fp 3)" "$db/known"
  run ! grep -qx "$(fp 3)" "$da/known"
  rmdir "$da/known.tmp"
  run_audit --run
  assert_success
  run_audit --full
  assert_success
  [[ "$(new_notifications)" -eq 1 ]]
  grep -qx "$(fp 3)" "$da/known"
  [[ ! -e "$STATE/pending-announce" ]]
}

# --- delivered pending entries: --report listing and --prune-delivered -------

# mixed_pending: a pending file with every row form, in a fixed order:
# legacy count, undelivered new + baselined, and both delivered kinds (one
# delivered fingerprint is already in alpha's known).
mixed_pending() {
  mkdir -p "$STATE"
  chmod 700 "$STATE"
  {
    printf 'new\t3\tlegacy repo\n'
    printf 'baselined\tbeta\t%s\n' "$(fp 21)"
    printf 'baselined.delivered\talpha\t%s\n' "$(fp 1)"
    printf 'new\tbeta\t%s\n' "$(fp 22)"
    printf 'new.delivered\tgamma/sub\t%s\n' "$(fp 31 c)"
    printf 'baselined.delivered\tgamma/sub\t%s\n' "$(fp 32 c)"
  } >"$(PENDING)"
  chmod 600 "$(PENDING)"
}

# retained_rows: the rows --prune-delivered must keep, in their original order.
retained_rows() {
  printf 'new\t3\tlegacy repo\n'
  printf 'baselined\tbeta\t%s\n' "$(fp 21)"
  printf 'new\tbeta\t%s\n' "$(fp 22)"
}

@test "gitleaks-audit: --help documents --prune-delivered and its --dry-run" {
  run_audit --help
  assert_success
  assert_output --partial "--prune-delivered"
  assert_output --partial "--prune-delivered --dry-run"
  assert_output --partial "already in its repo's known stays"
  assert_output --partial "known (never re-announced)"
}

@test "gitleaks-audit: --dry-run without --prune-delivered is a usage error" {
  run_audit --dry-run
  assert_failure 2
  run_audit --run --dry-run
  assert_failure 2
}

@test "gitleaks-audit: --report lists delivered pending entries (rel, rule, file:line) with counts, marking those already in known" {
  mkrepo alpha
  findings_only alpha 1
  run_audit --run
  assert_success
  mixed_pending
  run_audit --report
  assert_success
  assert_output --partial "Delivered pending announcements: 3 (new 1, baselined 2; 1 already in known)"
  assert_line --regexp "^  alpha  rule-a  src/f1\.txt:1 \(00000000\) baselined \[already in known: dropped by the next --run\]$"
  assert_line --regexp "^  gamma/sub  rule-c  src/f31\.txt:31 \(00000000\) new$"
  assert_line --regexp "^  gamma/sub  rule-c  src/f32\.txt:32 \(00000000\) baselined$"
  assert_output --partial "--prune-delivered"
  # Undelivered rows are not listed as delivered.
  refute_output --partial "src/f21.txt:21"
  refute_output --partial "src/f22.txt:22"
  # --report never writes.
  run diff <(retained_rows) <(grep -v delivered "$(PENDING)")
  assert_success
}

@test "gitleaks-audit: --prune-delivered with no, empty, or delivered-only pending file exits 0 (no notification)" {
  mkrepo alpha
  run_audit --prune-delivered
  assert_success
  assert_output --partial "nothing to prune"
  [[ ! -e "$(PENDING)" ]]
  mkdir -p "$STATE"
  : >"$(PENDING)"
  run_audit --prune-delivered
  assert_success
  assert_output --partial "nothing to prune"
  printf 'new.delivered\talpha\t%s\nbaselined.delivered\tbeta\t%s\n' "$(fp 1)" "$(fp 2)" >"$(PENDING)"
  run_audit --prune-delivered
  assert_success
  assert_output --partial "removed 2 delivered entries (new 1, baselined 1); kept 0"
  [[ ! -e "$(PENDING)" ]]
  run notifies
  assert_output ""
  [[ ! -e "$(LOCKD)" ]]
  grep -q 'prune-delivered' "$LOGF"
}

@test "gitleaks-audit: --prune-delivered removes both delivered kinds regardless of known; retained rows are unchanged, mode 600, and still delivered by a later --run" {
  mkrepo alpha
  findings_only alpha 1
  run_audit --run
  assert_success
  mixed_pending
  : >"$CALLS"
  run_audit --prune-delivered
  assert_success
  assert_output --partial "removed 3 delivered entries (new 1, baselined 2); kept 3"
  run cat "$(PENDING)"
  assert_output "$(retained_rows)"
  [[ "$(/usr/bin/stat -f %Lp "$(PENDING)")" == "600" ]]
  run notifies
  assert_output ""
  # A later run announces exactly the retained rows: 3 legacy + 1 new in 2
  # repos, 1 baselined in 1 repo.
  run_audit --run
  assert_success
  run notifies
  assert_output --partial "4 NEW finding(s) in 2 repo(s)"
  assert_output --partial "1 existing findings in 1 repos baselined"
}

@test "gitleaks-audit: --prune-delivered --dry-run previews and writes nothing (no lock, log, state, or notification)" {
  mkrepo alpha
  findings_only alpha 1
  run_audit --run
  mixed_pending
  local before h
  before="$(state_listing)"
  h="$(shasum "$(PENDING)")"
  rm -f "$LOGF"
  : >"$CALLS"
  local hook="$T/hook-any"
  printf '#!/bin/bash\necho "$1" >>"%s"\n' "$T/hook.log" >"$hook"
  chmod +x "$hook"
  GITLEAKS_AUDIT_TEST_HOOK="$hook" run_audit_env --prune-delivered --dry-run
  assert_success
  assert_output --partial "would remove 3 delivered entries (new 1, baselined 2; 1 already in known); keep 3"
  assert_output --partial "gamma/sub  rule-c  src/f31.txt:31"
  [[ "$h" == "$(shasum "$(PENDING)")" ]]
  [[ "$before" == "$(state_listing)" ]]
  [[ ! -e "$LOGF" ]]
  [[ ! -e "$(LOCKD)" ]]
  [[ ! -e "$T/hook.log" ]]
  run notifies
  assert_output ""
}

@test "gitleaks-audit: --prune-delivered while another run holds the lock exits 75 and changes nothing" {
  mixed_pending
  local h
  h="$(shasum "$(PENDING)")"
  sleep 60 &
  local holder=$!
  mkdir -p "$(LOCKD)"
  printf 'pid=%s\nhost=h\nstarted=%s\n' "$holder" "$(($(/bin/date -u +%s) - 2 * 86400))" >"$(LOCKD)/owner"
  run_audit --prune-delivered
  kill "$holder" 2>/dev/null
  assert_failure 75
  [[ "$h" == "$(shasum "$(PENDING)")" ]]
  # Not even the long-held-lock note: prune never notifies.
  run notifies
  assert_output ""
}

@test "gitleaks-audit: --prune-delivered failures exit 1 (never 10), keep the pending file byte-identical, never notify" {
  mkrepo alpha
  mixed_pending
  cp -p "$(PENDING)" "$T/pending.orig"
  same() { cmp -s "$(PENDING)" "$T/pending.orig" && [[ "$(/usr/bin/stat -f %Lp "$(PENDING)")" == 600 ]]; }

  # Obstructed publication: the state dir does not take a new file.
  /bin/chmod 500 "$STATE"
  run_audit --prune-delivered
  /bin/chmod 700 "$STATE"
  assert_failure 1
  assert_output --partial "ERROR: prune-delivered:"
  same

  # Rename failure.
  cat >"$STUBS/mv" <<'STUB'
#!/bin/bash
case "${@: -1}" in */pending-announce) exit 1 ;; esac
exec /bin/mv "$@"
STUB
  chmod +x "$STUBS/mv"
  run_audit --prune-delivered
  assert_failure 1
  same
  rm "$STUBS/mv"

  # chmod failure on the new file.
  cat >"$STUBS/chmod" <<'STUB'
#!/bin/bash
case "${@: -1}" in */pending-announce.prune.*) exit 1 ;; esac
exec /bin/chmod "$@"
STUB
  chmod +x "$STUBS/chmod"
  run_audit --prune-delivered
  assert_failure 1
  same
  rm "$STUBS/chmod"
  [[ -z "$(find "$STATE" -name 'pending-announce.prune.*')" ]]

  # Read failure.
  chmod 000 "$(PENDING)"
  run_audit --prune-delivered
  chmod 600 "$(PENDING)"
  assert_failure 1
  same

  # Log failure (log file unwritable): nothing is touched.
  mkdir -p "$(dirname "$LOGF")"
  : >"$LOGF"
  chmod 000 "$LOGF"
  run_audit --prune-delivered
  chmod 600 "$LOGF"
  assert_failure 1
  same

  # Lock infrastructure error: exit 1, no notification.
  mkdir -p "$FAKE_HOME/Library/Caches"
  : >"$(LOCKD)"
  run_audit --prune-delivered
  rm -f "$(LOCKD)"
  assert_failure 1
  assert_output --partial "ERROR: lock: cannot create $(LOCKD)"
  same

  run notifies
  assert_output ""
  # And with the obstacles gone it works.
  run_audit --prune-delivered
  assert_success
}

@test "gitleaks-audit: retained entries are not re-announced by a forced scan after --prune-delivered" {
  mkrepo alpha
  findings_only alpha 1 2
  echo 1 >"$FIX/osascript_rc"
  run_audit --run
  assert_success
  # Undelivered baseline of alpha, plus a delivered entry of another repo.
  printf 'new.delivered\tgone\t%s\n' "$(fp 9)" >>"$(PENDING)"
  rm "$FIX/osascript_rc"
  run_audit --prune-delivered
  assert_success
  assert_output --partial "removed 1 delivered entries (new 1, baselined 0); kept 2"
  : >"$CALLS"
  run_audit --full
  assert_success
  run notifies
  assert_output --partial "2 existing findings in 1 repos baselined"
  refute_output --partial "NEW"
  : >"$CALLS"
  run_audit --full
  assert_success
  run notifies
  assert_output ""
}

@test "gitleaks-audit: a pruned delivered fingerprint that reappears is NEW when the repo's known exists" {
  mkrepo alpha
  findings_only alpha 1
  run_audit --run
  assert_success
  [[ -f "$(state_dir alpha)/known" ]]
  printf 'new.delivered\talpha\t%s\n' "$(fp 2)" >"$(PENDING)"
  run_audit --prune-delivered
  assert_success
  commit_in alpha
  findings_only alpha 1 2
  : >"$CALLS"
  run_audit --run
  assert_failure 10
  run notifies
  assert_output --partial "1 NEW finding(s) in 1 repo(s)"
}

@test "gitleaks-audit: a pruned delivered fingerprint that reappears is baselined when the repo has no known file" {
  mkrepo alpha
  mkdir -p "$STATE"
  chmod 700 "$STATE"
  printf 'baselined.delivered\talpha\t%s\n' "$(fp 1)" >"$(PENDING)"
  run_audit --prune-delivered
  assert_success
  [[ ! -e "$(PENDING)" ]]
  findings_only alpha 1
  : >"$CALLS"
  run_audit --run
  assert_success
  run notifies
  assert_output --partial "1 existing findings in 1 repos baselined"
  refute_output --partial "NEW"
}

@test "gitleaks-audit: --prune-delivered never touches another run's pending-announce.tmp (failing preview, pre-lock log failure, success)" {
  mkrepo alpha
  mixed_pending
  printf 'another run is writing this\n' >"$(PENDING).tmp"
  /bin/chmod 600 "$(PENDING).tmp"
  cp -p "$(PENDING).tmp" "$T/tmp.orig"
  untouched() { cmp -s "$(PENDING).tmp" "$T/tmp.orig"; }
  # A failing preview (unreadable pending file) writes and removes nothing.
  /bin/chmod 000 "$(PENDING)"
  run_audit --prune-delivered --dry-run
  /bin/chmod 600 "$(PENDING)"
  assert_failure 1
  untouched
  # A log failure before the lock is taken.
  mkdir -p "$(dirname "$LOGF")"
  : >"$LOGF"
  /bin/chmod 000 "$LOGF"
  run_audit --prune-delivered
  /bin/chmod 600 "$LOGF"
  assert_failure 1
  untouched
  # A successful prune uses its own temp file.
  run_audit --prune-delivered
  assert_success
  untouched
  [[ -z "$(find "$STATE" -name 'pending-announce.prune.*')" ]]
}

@test "gitleaks-audit: a pruned delivered fingerprint that is already in known stays known (not re-announced)" {
  mkrepo alpha
  findings_only alpha 1
  run_audit --run
  assert_success
  grep -qx "$(fp 1)" "$(state_dir alpha)/known"
  printf 'new.delivered\talpha\t%s\n' "$(fp 1)" >"$(PENDING)"
  run_audit --prune-delivered
  assert_success
  commit_in alpha
  : >"$CALLS"
  run_audit --run
  assert_success
  run notifies
  assert_output ""
}

@test "gitleaks-audit: --prune-delivered keeps an unterminated final retained row byte-for-byte" {
  mkdir -p "$STATE"
  chmod 700 "$STATE"
  printf 'new.delivered\talpha\t%s\nnew\tbeta\t%s\nbaselined.delivered\tgamma\t%s\nbaselined\tbeta\t%s' \
    "$(fp 1)" "$(fp 2)" "$(fp 3)" "$(fp 4)" >"$(PENDING)"
  printf 'new\tbeta\t%s\nbaselined\tbeta\t%s' "$(fp 2)" "$(fp 4)" >"$T/expected"
  run_audit --prune-delivered
  assert_success
  cmp "$(PENDING)" "$T/expected"
}

@test "gitleaks-audit: TERM between creating and renaming the prune temp file leaves no orphan, the pending file unchanged, the lock released" {
  mkrepo alpha
  mixed_pending
  cp -p "$(PENDING)" "$T/pending.orig"
  cat >"$T/hook" <<HOOK
#!/bin/bash
[[ "\$1" == prune-created ]] || exit 0
[[ -e "\$2" ]] && touch "$T/tmp.seen"
touch "$FIX/paused"
while [[ ! -e "$FIX/go" ]]; do sleep 0.05; done
HOOK
  chmod +x "$T/hook"
  bg_audit "$T/p" GITLEAKS_AUDIT_TEST_HOOK="$T/hook" -- --prune-delivered
  wait_for test -e "$FIX/paused"
  [[ -e "$T/tmp.seen" ]]
  kill -TERM "$BG_PID"
  touch "$FIX/go"
  local rc=0
  wait "$BG_PID" || rc=$?
  [[ $rc -ne 0 ]]
  [[ -z "$(find "$STATE" -name 'pending-announce.prune.*')" ]]
  cmp -s "$(PENDING)" "$T/pending.orig"
  [[ ! -e "$(LOCKD)" ]]
}

@test "gitleaks-audit: TERM while the prune temp file is being written (after its creation) leaves no orphan" {
  mkrepo alpha
  mixed_pending
  cp -p "$(PENDING)" "$T/pending.orig"
  cat >"$T/hook" <<HOOK
#!/bin/bash
[[ "\$1" == prune-writing ]] || exit 0
[[ -e "\$2" ]] && touch "$T/tmp.seen"
touch "$FIX/paused"
while [[ ! -e "$FIX/go" ]]; do sleep 0.05; done
HOOK
  chmod +x "$T/hook"
  bg_audit "$T/p" GITLEAKS_AUDIT_TEST_HOOK="$T/hook" -- --prune-delivered
  wait_for test -e "$FIX/paused"
  [[ -e "$T/tmp.seen" ]]
  kill -TERM "$BG_PID"
  touch "$FIX/go"
  local rc=0
  wait "$BG_PID" || rc=$?
  [[ $rc -ne 0 ]]
  [[ -z "$(find "$STATE" -name 'pending-announce.prune.*')" ]]
  cmp -s "$(PENDING)" "$T/pending.orig"
  [[ ! -e "$(LOCKD)" ]]
}

@test "gitleaks-audit: a pre-existing pending-announce.prune.<pid> is never written or removed" {
  mkrepo alpha
  mixed_pending
  cp -p "$(PENDING)" "$T/pending.orig"
  # Pause at the first lock step and plant a file with this run's own
  # temp name, as a leftover from an earlier run with the same pid would be.
  cat >"$T/hook" <<HOOK
#!/bin/bash
[[ "\$1" == lock-mkdir && ! -e "$FIX/paused" ]] || exit 0
touch "$FIX/paused"
while [[ ! -e "$FIX/go" ]]; do sleep 0.05; done
HOOK
  chmod +x "$T/hook"
  bg_audit "$T/p" GITLEAKS_AUDIT_TEST_HOOK="$T/hook" -- --prune-delivered
  wait_for test -e "$FIX/paused"
  printf 'not this run\n' >"$STATE/pending-announce.prune.$BG_PID"
  cp -p "$STATE/pending-announce.prune.$BG_PID" "$T/collision.orig"
  touch "$FIX/go"
  local rc=0
  wait "$BG_PID" || rc=$?
  [[ $rc -eq 1 ]]
  cmp -s "$STATE/pending-announce.prune.$BG_PID" "$T/collision.orig"
  cmp -s "$(PENDING)" "$T/pending.orig"
  [[ ! -e "$(LOCKD)" ]]
}
