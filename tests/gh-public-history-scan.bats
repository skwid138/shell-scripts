#!/usr/bin/env bats
bats_require_minimum_version 1.5.0
# Tests for personal/gh-public-history-scan.sh (local gitleaks history scan of
# an owner's public GitHub repos whose secret scanning is disabled).
#
# Every run is under `env -i` with HOME and TMPDIR inside the test temp dir,
# PATH replaced (GH_SCAN_BASE_PATH) by stubs + the real git/jq + system dirs,
# a fake `gh` (GH_SCAN_GH) answering from fixture files, and clone URLs
# pointed at local file:// (or a local 401 HTTP server) fixture repos via the
# test-only GH_SCAN_CLONE_BASE + GH_SCAN_TEST_INSECURE_URLS seam. No test
# touches real GitHub or the real ~/Library state. Secrets are synthetic and
# generated at runtime.
#
# gitleaks is either a stub (canned report / rc / stderr, keyed by repo id)
# or the real binary behind a wrapper that answers `version` with the pin.
#
# macOS-only (BSD ls/chmod -N, ~/Library state, /usr/bin/perl setpgrp).

setup() {
  load 'test_helper/bats-support/load'
  load 'test_helper/bats-assert/load'

  [[ "$(uname -s)" == "Darwin" ]] || skip "gh-public-history-scan is macOS-only (BSD ls/chmod -N, ~/Library state)"

  SCRIPT="$BATS_TEST_DIRNAME/../personal/gh-public-history-scan.sh"
  T="$BATS_TEST_TMPDIR"
  FAKE_HOME="$T/home"
  BIN="$T/bin"
  FIX="$T/fix"
  SRC="$T/src"
  TMPD="$T/tmp"
  CALLS="$T/calls.log"
  OWNER="synth-owner"
  STATE="$FAKE_HOME/Library/Application Support/gh-security-rollout"
  MARKER="SYNTHETIC-SECRET-MARKER-5b1e7d"
  mkdir -p "$FAKE_HOME" "$BIN" "$FIX/gh" "$SRC/$OWNER" "$TMPD"
  : >"$CALLS"
  : >"$FIX/gh/list.jsonl"

  # Fixture building only (the script itself never inherits these).
  export GIT_CONFIG_GLOBAL=/dev/null GIT_CONFIG_NOSYSTEM=1
  export GIT_AUTHOR_NAME=synth GIT_AUTHOR_EMAIL=synth@example.invalid
  export GIT_COMMITTER_NAME=synth GIT_COMMITTER_EMAIL=synth@example.invalid

  REAL_GIT="$(type -P git)"
  [[ "$REAL_GIT" == /* ]] || skip "no git binary on PATH"
  REAL_JQ="$(type -P jq)"
  [[ "$REAL_JQ" == /* ]] || skip "no jq on PATH"
  ln -s "$REAL_GIT" "$BIN/git"
  ln -s "$REAL_JQ" "$BIN/jq"
  REAL_GITLEAKS="$(type -P gitleaks || true)"

  KEY="$(new_key)"
  TIMEOUT=60
  EXTRA_ENV=()
  CLONE_BASE="file://$SRC"
  write_fake_gh
  use_stub_gitleaks
}

teardown() {
  local f
  for f in "$FIX/child.pid" "$FIX/srv.pid"; do
    [[ -s "$f" ]] && kill -KILL "$(cat "$f")" 2>/dev/null
  done
  /bin/chmod -RN "$BATS_TEST_TMPDIR" 2>/dev/null
  /bin/chmod -R u+rwx "$BATS_TEST_TMPDIR" 2>/dev/null
  return 0
}

new_key() { printf 'AKIA%s' "$(LC_ALL=C tr -dc 'A-Z2-7' </dev/urandom | head -c 16)"; }

# --- fakes -----------------------------------------------------------------------

# The fake gh: `api --paginate user/repos...` prints list.jsonl as TWO pages
# (concatenated arrays) and exits with gh/pages.rc; `api repos/<o>/<n>`
# prints gh/repo.<n>.json (404 when absent) and exits with gh/repo.<n>.rc;
# `api user --jq .login` prints the owner.
write_fake_gh() {
  cat >"$T/gh" <<EOF
#!/bin/bash
printf 'gh %s\n' "\$*" >>"$CALLS"
[[ "\${1-}" == api ]] || exit 2
shift
if [[ "\${1-}" == --paginate ]]; then
  [[ "\${2-}" == 'user/repos?affiliation=owner&per_page=100' ]] || { echo "unexpected: \$2" >&2; exit 2; }
  n=\$(grep -c . "$FIX/gh/list.jsonl")
  h=\$(( (n + 1) / 2 ))
  head -n "\$h" "$FIX/gh/list.jsonl" | jq -s -c .
  tail -n +"\$((h + 1))" "$FIX/gh/list.jsonl" | jq -s -c .
  exit "\$(cat "$FIX/gh/pages.rc" 2>/dev/null || echo 0)"
fi
case "\${1-}" in
  user) echo "$OWNER"; exit 0 ;;
  repos/*)
    name="\${1##*/}"
    f="$FIX/gh/repo.\$name.json"
    [[ -f "\$f" ]] || { echo "gh: Not Found (HTTP 404)" >&2; exit 1; }
    cat "\$f"
    exit "\$(cat "$FIX/gh/repo.\$name.rc" 2>/dev/null || echo 0)"
    ;;
esac
exit 2
EOF
  chmod +x "$T/gh"
}

# gh_repo <name> <id> <public|private> <fork true|false> <enabled|disabled|missing|null|ssnull>
gh_repo() {
  local name="$1" id="$2" vis="$3" fork="$4" ss="$5" priv=false sa
  [[ "$vis" == private ]] && priv=true
  jq -n -c --arg n "$name" --argjson id "$id" --arg v "$vis" --argjson p "$priv" --argjson f "$fork" --arg o "$OWNER" \
    '{name: $n, id: $id, visibility: $v, private: $p, fork: $f, owner: {login: $o}}' >>"$FIX/gh/list.jsonl"
  case "$ss" in
    enabled | disabled) sa="{\"secret_scanning\": {\"status\": \"$ss\"}, \"secret_scanning_push_protection\": {\"status\": \"$ss\"}}" ;;
    null) sa=null ;;
    ssnull) sa='{"secret_scanning": null}' ;;
    missing) sa="" ;;
  esac
  if [[ -n "$sa" ]]; then
    jq -n --arg n "$name" --argjson id "$id" --arg v "$vis" --argjson p "$priv" --argjson f "$fork" --argjson sa "$sa" \
      '{name: $n, id: $id, visibility: $v, private: $p, fork: $f, security_and_analysis: $sa}' >"$FIX/gh/repo.$name.json"
  else
    jq -n --arg n "$name" --argjson id "$id" --arg v "$vis" --argjson p "$priv" --argjson f "$fork" \
      '{name: $n, id: $id, visibility: $v, private: $p, fork: $f}' >"$FIX/gh/repo.$name.json"
  fi
}

# Stub gitleaks (paths baked in: the script runs it under env -i). Behaviour
# is keyed by the repo id parsed from the scan target (.../r-<id>/...) and
# the mode (git | dir): gl.<id>.<mode>.{json,rc,stderr,hang}. Every dir scan
# appends the sorted file listing of its scan root to dir.list.
use_stub_gitleaks() {
  rm -f "$BIN/gitleaks"
  cat >"$BIN/gitleaks" <<EOF
#!/bin/bash
FIX="$FIX"
printf 'gitleaks %s\n' "\$*" >>"\$FIX/gl.calls"
if [[ "\${1-}" == version ]]; then
  cat "\$FIX/gl.version" 2>/dev/null || echo 8.30.1
  exit 0
fi
mode="\$1" target="\$2" rp=""
prev=""
for a in "\$@"; do
  [[ "\$prev" == --report-path ]] && rp="\$a"
  prev="\$a"
done
id="\$(printf '%s' "\$target" | sed -n 's|.*/r-\([0-9]*\)/.*|\1|p')"
k="\$FIX/gl.\$id.\$mode"
echo "$MARKER on stdout"
echo "$MARKER on stderr" >&2
[[ "\$mode" == dir ]] && (cd "\$target" && find . \\( -type f -o -type l \\) | LC_ALL=C sort | tr '\n' ' '; echo) >>"\$FIX/dir.list"
[[ -f "\$k.stderr" ]] && cat "\$k.stderr" >&2
if [[ -f "\$k.hang" ]]; then
  d="\$(dirname "\$target")"
  sh -c 'trap "" TERM; echo \$\$ >"\$1/child.pid"; while :; do [ -d "\$2" ] || { echo violation >"\$1/violation"; exit 0; }; sleep 0.05; done' sh "\$FIX" "\$d" </dev/null >/dev/null 2>&1 &
  sleep 300 &
  wait \$!
fi
if [[ -f "\$k.json" ]]; then cp "\$k.json" "\$rp"; else echo '[]' >"\$rp"; fi
exit "\$(cat "\$k.rc" 2>/dev/null || echo 0)"
EOF
  chmod +x "$BIN/gitleaks"
}

# The real gitleaks behind a wrapper that logs its argv. Only when the
# installed binary is NOT the pinned 8.30.1 (CI's macOS runners install the
# current brew bottle) does the wrapper also answer `version` with the pin, so
# these detection tests still run; the version gate itself is covered by the
# stub test "refuses any gitleaks other than 8.30.1".
use_real_gitleaks() {
  [[ "$REAL_GITLEAKS" == /* ]] || skip "real gitleaks not installed"
  local real_version fake_version=""
  real_version="$("$REAL_GITLEAKS" version 2>/dev/null | tr -d '[:space:]')"
  [[ "${real_version#v}" == 8.30.1 ]] || fake_version='if [[ "${1-}" == version ]]; then echo 8.30.1; exit 0; fi'
  rm -f "$BIN/gitleaks"
  cat >"$BIN/gitleaks" <<EOF
#!/bin/bash
printf 'gitleaks %s\n' "\$*" >>"$FIX/gl.calls"
$fake_version
exec "$REAL_GITLEAKS" "\$@"
EOF
  chmod +x "$BIN/gitleaks"
}

# --- fixture repos -----------------------------------------------------------------

# src_repo <name>: a fresh repo with one commit; prints its path.
src_repo() {
  local d="$SRC/$OWNER/$1.git"
  git init -q -b main "$d"
  echo "readme" >"$d/README"
  git -C "$d" add README
  git -C "$d" commit -q -m init
  printf '%s' "$d"
}

# diverge <dir>: side branch adds side.txt, main adds main.txt (main checked out).
diverge() {
  git -C "$1" checkout -q -b side
  echo side >"$1/side.txt"
  git -C "$1" add side.txt
  git -C "$1" commit -q -m side
  git -C "$1" checkout -q main
  echo main >"$1/main.txt"
  git -C "$1" add main.txt
  git -C "$1" commit -q -m main
}

# evil_merge <dir> <file> [branch]: merge side into main and add <file> with
# the synthetic key ONLY in the merge resolution. Prints the merge sha.
evil_merge() {
  local d="$1" f="$2" b="${3:-side}"
  git -C "$d" merge -q --no-ff --no-commit "$b" >/dev/null 2>&1
  mkdir -p "$(dirname "$d/$f")"
  printf 'aws_key = "%s"\n' "$KEY" >"$d/$f"
  git -C "$d" add -- "$f"
  git -C "$d" commit -q -m merge
  git -C "$d" rev-parse HEAD
}

# plumb_merge <dir> <tree-filter-cmd>: merge side into main with a tree built
# from the clean merge tree piped through <tree-filter-cmd> (ls-tree lines
# in, mktree lines out). Prints the merge sha.
plumb_merge() {
  local d="$1" filter="$2" t0 t m
  git -C "$d" merge -q --no-ff --no-commit side >/dev/null 2>&1
  t0="$(git -C "$d" write-tree)"
  git -C "$d" merge --abort
  t="$(git -C "$d" ls-tree "$t0" | eval "$filter" | git -C "$d" mktree)"
  m="$(git -C "$d" commit-tree "$t" -p main -p side -m merge)"
  git -C "$d" update-ref refs/heads/main "$m"
  printf '%s' "$m"
}

# --- runner and accessors --------------------------------------------------------

run_scan() {
  run --separate-stderr env -i HOME="$FAKE_HOME" TMPDIR="$TMPD" \
    GH_SCAN_GH="$T/gh" GH_SCAN_BASE_PATH="$BIN:/usr/bin:/bin:/usr/sbin:/sbin" \
    GH_SCAN_CLONE_BASE="$CLONE_BASE" GH_SCAN_TEST_INSECURE_URLS=1 \
    GH_SCAN_TIMEOUT="$TIMEOUT" GH_SCAN_KILL_GRACE=1 \
    ${EXTRA_ENV[@]+"${EXTRA_ENV[@]}"} \
    /bin/bash "$SCRIPT" "$@" </dev/null
}

scan_dir() { find "$STATE" -maxdepth 1 -type d -name 'scan-*' | LC_ALL=C sort | tail -n1; }
# mfield <repo> <column-number>: a manifest field.
mfield() { awk -F'\t' -v n="$1" -v c="$2" '!/^#/ && $1 == n { print $c }' "$(scan_dir)/manifest.tsv"; }
# frows <repo>: findings rows of a repo.
frows() { awk -F'\t' -v n="$1" '!/^#/ && $1 == n' "$(scan_dir)/findings.tsv"; }
calls_for() { grep -c "/r-$1/" "$FIX/gl.calls" 2>/dev/null || true; }

# assert_no_secret <haystack-name> <text>: fails without echoing the secret.
assert_no_secret() {
  if [[ "$2" == *"$KEY"* || "$2" == *"$MARKER"* ]]; then
    echo "synthetic secret/marker leaked into $1" >&2
    return 1
  fi
}

# assert_no_secret_on_disk: nothing under HOME or TMPDIR (the script's
# state and temp) contains the key or the stub marker.
assert_no_secret_on_disk() {
  if grep -rlF -e "$KEY" -e "$MARKER" "$FAKE_HOME" "$TMPD" >/dev/null 2>&1; then
    echo "synthetic secret/marker found on disk under HOME or TMPDIR" >&2
    return 1
  fi
}

# ===================================================================================

@test "gh-public-history-scan: --help exits 0 and documents the merge pass and the git-wait blind spot" {
  run /bin/bash "$SCRIPT" --help
  assert_success
  assert_output --partial "Usage: gh-public-history-scan"
  assert_output --partial "merge-touched-file"
  assert_output --partial "debug level"
  assert_output --partial "scope.txt"
  assert_output --partial "--log"
}

@test "gh-public-history-scan: refuses a non-https clone base without the test switch" {
  run env -i HOME="$FAKE_HOME" TMPDIR="$TMPD" GH_SCAN_GH="$T/gh" GH_SCAN_BASE_PATH="$BIN:/usr/bin:/bin:/usr/sbin:/sbin" \
    GH_SCAN_CLONE_BASE="http://127.0.0.1:9" /bin/bash "$SCRIPT" --owner "$OWNER" --dry-run
  assert_failure 2
  assert_output --partial "https"
}

@test "gh-public-history-scan: refuses any gitleaks other than 8.30.1 and scans nothing" {
  echo "8.31.0" >"$FIX/gl.version"
  gh_repo alpha 101 public false disabled
  src_repo alpha >/dev/null
  run_scan --owner "$OWNER"
  assert_failure 3
  [[ "$stderr" == *"8.30.1"* ]]
  run ! grep -q '^gitleaks git' "$FIX/gl.calls"
  [[ ! -d "$STATE" ]]
}

@test "gh-public-history-scan: --dry-run lists targets, uses gh api user for the owner, and writes no state" {
  gh_repo alpha 101 public false disabled
  gh_repo beta 102 public true enabled
  gh_repo gamma 103 private false missing
  run_scan --dry-run
  assert_success
  [[ "$output" == *"target"*"alpha"* ]]
  [[ "$output" == *"skipped-enabled"*"beta"* ]]
  [[ "$output" == *"skipped-private"*"gamma"* ]]
  grep -q '^gh api user' "$CALLS"
  # A private repo needs no per-repo GET.
  run ! grep -q 'repos/synth-owner/gamma' "$CALLS"
  [[ ! -d "$STATE" ]]
  run ! grep -q '^gitleaks git' "$FIX/gl.calls"
}

@test "gh-public-history-scan: inventory - public disabled are targets; missing/null/failed status is an error, never skipped" {
  gh_repo alpha 101 public false disabled
  gh_repo enab 102 public false enabled
  gh_repo priv 103 private false null
  gh_repo nosa 104 public false missing
  gh_repo nullsa 105 public false null
  gh_repo ssnull 106 public false ssnull
  gh_repo failed 107 public false disabled
  echo 1 >"$FIX/gh/repo.failed.rc"
  src_repo alpha >/dev/null
  run_scan --owner "$OWNER"
  assert_failure 1
  [[ "$(mfield alpha 4)" == clean ]]
  [[ "$(mfield alpha 2)" == 101 ]]
  [[ "$(mfield nosa 4)" == error && "$(mfield nosa 12)" == *missing* ]]
  [[ "$(mfield nullsa 4)" == error && "$(mfield nullsa 12)" == *null* ]]
  [[ "$(mfield ssnull 4)" == error && "$(mfield ssnull 12)" == *null* ]]
  [[ "$(mfield failed 4)" == error && "$(mfield failed 12)" == *request-failed* ]]
  [[ -z "$(mfield enab 4)" && -z "$(mfield priv 4)" ]]
  local sd
  sd="$(scan_dir)"
  grep -qx 'complete=false' "$sd/inventory.meta"
  grep -qx 'get_failed=1' "$sd/inventory.meta"
  awk -F'\t' '$1 == "enab" && $6 == "skipped-enabled"' "$sd/inventory.tsv" | grep -q .
  awk -F'\t' '$1 == "priv" && $6 == "skipped-private"' "$sd/inventory.tsv" | grep -q .
  [[ "$output" == *"INCOMPLETE"* ]]
}

@test "gh-public-history-scan: a pagination failure marks the inventory incomplete even when every repo is listed" {
  gh_repo alpha 101 public false disabled
  gh_repo beta 102 public false disabled
  src_repo alpha >/dev/null
  src_repo beta >/dev/null
  echo 1 >"$FIX/gh/pages.rc"
  run_scan --owner "$OWNER"
  assert_failure 1
  [[ "$(mfield alpha 4)" == clean && "$(mfield beta 4)" == clean ]]
  grep -qx 'complete=false' "$(scan_dir)/inventory.meta"
  grep -qx 'pagination=failed' "$(scan_dir)/inventory.meta"
  [[ "$output" == *"INCOMPLETE"* ]]
}

@test "gh-public-history-scan: --only and --repos limit targets; an unknown name is an error row" {
  gh_repo alpha 101 public false disabled
  gh_repo beta 102 public false disabled
  src_repo alpha >/dev/null
  run_scan --owner "$OWNER" --only alpha,ghost
  assert_failure 1
  [[ "$(mfield alpha 4)" == clean ]]
  [[ "$(mfield ghost 4)" == error ]]
  [[ -z "$(mfield beta 4)" ]]
  run ! grep -q 'repos/synth-owner/beta' "$CALLS"
  rm -rf "$STATE"
  printf '# pilot\nbeta\n\n' >"$T/list.txt"
  src_repo beta >/dev/null
  run_scan --owner "$OWNER" --repos "$T/list.txt"
  assert_success
  [[ "$(mfield beta 4)" == clean && -z "$(mfield alpha 4)" ]]
}

@test "gh-public-history-scan (real gitleaks): clean repo row carries identity and ref hash; private 700/600 output without ACLs" {
  use_real_gitleaks
  gh_repo alpha 101 public true disabled
  src_repo alpha >/dev/null
  run_scan --owner "$OWNER"
  assert_success
  [[ "$(mfield alpha 2)" == 101 && "$(mfield alpha 3)" == true && "$(mfield alpha 4)" == clean && "$(mfield alpha 5)" == 0 ]]
  [[ "$(mfield alpha 6)" =~ ^[0-9a-f]{64}$ ]]
  local sd f
  sd="$(scan_dir)"
  for f in "$STATE" "$sd"; do
    [[ "$(/bin/ls -led "$f" | cut -c1-11)" == "drwx------ " ]]
  done
  for f in "$sd"/*; do
    [[ "$(/bin/ls -le "$f" | cut -c1-11)" == "-rw------- " ]]
  done
  [[ -z "$(frows alpha)" ]]
  # The work dir (mirror) is gone.
  [[ -z "$(find "$TMPD" -mindepth 1 -maxdepth 1 -name 'gh-public-history-scan.*')" ]]
}

@test "gh-public-history-scan (real gitleaks): history finding is metadata only; the secret is in no output, log, or leftover file" {
  use_real_gitleaks
  gh_repo alpha 101 public false disabled
  local d c
  d="$(src_repo alpha)"
  printf 'aws_key = "%s"\n' "$KEY" >"$d/conf.txt"
  git -C "$d" add conf.txt
  git -C "$d" commit -q -m conf
  c="$(git -C "$d" rev-parse HEAD)"
  run_scan --owner "$OWNER"
  assert_failure 10
  [[ "$(mfield alpha 4)" == findings && "$(mfield alpha 5)" == 1 ]]
  local row
  row="$(frows alpha)"
  [[ "$row" == "alpha"$'\t'"101"$'\t'"history"$'\t'"$c"$'\t'"conf.txt"$'\t'"aws-access-token"$'\t'"1"$'\t'"$c:conf.txt:aws-access-token:1" ]]
  assert_no_secret stdout "$output"
  assert_no_secret stderr "$stderr"
  assert_no_secret_on_disk
}

@test "gh-public-history-scan: an empty repo is status empty and is not scanned" {
  gh_repo hollow 201 public false disabled
  git init -q -b main "$SRC/$OWNER/hollow.git"
  run_scan --owner "$OWNER"
  assert_success
  [[ "$(mfield hollow 4)" == empty && "$(mfield hollow 5)" == 0 ]]
  run ! grep -q '^gitleaks git' "$FIX/gl.calls"
}

@test "gh-public-history-scan: a clone failure is an error, never empty" {
  gh_repo gone 202 public false disabled
  run_scan --owner "$OWNER"
  assert_failure 1
  [[ "$(mfield gone 4)" == error && "$(mfield gone 12)" == *clone* ]]
}

@test "gh-public-history-scan: gitleaks exit 0 with an ERR diagnostic is an error, not clean" {
  gh_repo alpha 101 public false disabled
  src_repo alpha >/dev/null
  echo "1:02PM ERR [git] fatal: synthetic failure" >"$FIX/gl.101.git.stderr"
  run_scan --owner "$OWNER"
  assert_failure 1
  [[ "$(mfield alpha 4)" == error && "$(mfield alpha 12)" == *ERR* ]]
  assert_no_secret stdout "$output"
  assert_no_secret stderr "$stderr"
}

@test "gh-public-history-scan: malformed JSON, missing fields, and exit/count mismatches are errors" {
  local f='{"RuleID":"r","File":"f","StartLine":1,"Commit":"c","Fingerprint":"c:f:r:1","Secret":"REDACTED"}'
  gh_repo mal 11 public false disabled
  gh_repo nofield 12 public false disabled
  gh_repo zerofind 13 public false disabled
  gh_repo tenempty 14 public false disabled
  gh_repo rcone 15 public false disabled
  gh_repo notarray 16 public false disabled
  for r in mal nofield zerofind tenempty rcone notarray; do src_repo "$r" >/dev/null; done
  echo '[{"RuleID":' >"$FIX/gl.11.git.json"
  echo '[{"RuleID":"r","File":"f","Commit":"c","Fingerprint":"x"}]' >"$FIX/gl.12.git.json"
  echo 10 >"$FIX/gl.12.git.rc"
  echo "[$f]" >"$FIX/gl.13.git.json"
  echo 10 >"$FIX/gl.14.git.rc"
  echo 1 >"$FIX/gl.15.git.rc"
  echo "$f" >"$FIX/gl.16.git.json"
  echo 10 >"$FIX/gl.16.git.rc"
  run_scan --owner "$OWNER"
  assert_failure 1
  [[ "$(mfield mal 4)" == error && "$(mfield mal 12)" == *JSON* ]]
  [[ "$(mfield nofield 4)" == error && "$(mfield nofield 12)" == *JSON* ]]
  [[ "$(mfield zerofind 4)" == error && "$(mfield zerofind 12)" == *inconsistent* ]]
  [[ "$(mfield tenempty 4)" == error && "$(mfield tenempty 12)" == *inconsistent* ]]
  [[ "$(mfield rcone 4)" == error && "$(mfield rcone 12)" == *"exited 1"* ]]
  [[ "$(mfield notarray 4)" == error && "$(mfield notarray 12)" == *JSON* ]]
  [[ -z "$(awk '!/^#/' "$(scan_dir)/findings.tsv")" ]]
}

@test "gh-public-history-scan: an empty report or more than one JSON document is an error, never clean" {
  gh_repo blank 21 public false disabled
  gh_repo twodocs 22 public false disabled
  gh_repo onedoc 23 public false disabled
  for r in blank twodocs onedoc; do src_repo "$r" >/dev/null; done
  : >"$FIX/gl.21.git.json"
  printf '[]\n[]\n' >"$FIX/gl.22.git.json"
  printf '[]\n' >"$FIX/gl.23.git.json"
  run_scan --owner "$OWNER"
  assert_failure 1
  [[ "$(mfield blank 4)" == error && "$(mfield blank 12)" == *JSON* ]]
  [[ "$(mfield twodocs 4)" == error && "$(mfield twodocs 12)" == *JSON* ]]
  [[ "$(mfield onedoc 4)" == clean ]]
}

@test "gh-public-history-scan: the merge pass also rejects an empty report or several JSON documents" {
  gh_repo blankm 24 public false disabled
  gh_repo twom 25 public false disabled
  local r d
  for r in blankm twom; do
    d="$(src_repo "$r")"
    diverge "$d"
    evil_merge "$d" evil.txt >/dev/null
  done
  : >"$FIX/gl.24.dir.json"
  printf '[]\n[]\n' >"$FIX/gl.25.dir.json"
  run_scan --owner "$OWNER"
  assert_failure 1
  [[ "$(mfield blankm 4)" == error && "$(mfield blankm 12)" == "merge pass"*JSON* ]]
  [[ "$(mfield twom 4)" == error && "$(mfield twom 12)" == "merge pass"*JSON* ]]
}

@test "gh-public-history-scan: a timed-out scan with a TERM-ignoring child is status timeout; the child dies before the work dir is removed" {
  TIMEOUT=2
  gh_repo slow 301 public false disabled
  gh_repo next 302 public false disabled
  src_repo slow >/dev/null
  src_repo next >/dev/null
  : >"$FIX/gl.301.git.hang"
  run_scan --owner "$OWNER"
  assert_failure 1
  [[ "$(mfield slow 4)" == timeout ]]
  [[ "$(mfield next 4)" == clean ]]
  [[ -s "$FIX/child.pid" ]]
  run ! kill -0 "$(cat "$FIX/child.pid")" 2>/dev/null
  [[ ! -e "$FIX/violation" ]]
}

@test "gh-public-history-scan: a process group that cannot be confirmed empty keeps the work dir and stops the run" {
  gh_repo alpha 101 public false disabled
  gh_repo beta 102 public false disabled
  src_repo alpha >/dev/null
  src_repo beta >/dev/null
  printf '#!/bin/sh\nexit 0\n' >"$T/probe"
  chmod +x "$T/probe"
  EXTRA_ENV=(GH_SCAN_GROUP_PROBE="$T/probe")
  run_scan --owner "$OWNER"
  assert_failure 1
  [[ "$(mfield alpha 4)" == error ]]
  [[ "$(mfield beta 4)" == not-attempted ]]
  [[ -n "$(find "$TMPD" -mindepth 1 -maxdepth 1 -name 'gh-public-history-scan.*')" ]]
}

@test "gh-public-history-scan: a failed findings publication never marks the repo complete" {
  gh_repo alpha 101 public false disabled
  src_repo alpha >/dev/null
  cat >"$T/hook" <<'EOF'
#!/bin/sh
[ "$1" = publish-findings ] || exit 0
rm -f "$2/findings.tsv"
mkdir "$2/findings.tsv"
: >"$2/findings.tsv/blocker"
EOF
  chmod +x "$T/hook"
  EXTRA_ENV=(GH_SCAN_TEST_HOOK="$T/hook")
  run_scan --owner "$OWNER"
  assert_failure 1
  local st
  st="$(mfield alpha 4)"
  [[ "$st" != clean && "$st" != findings && "$st" != empty ]]
  [[ "$stderr" == *"publication failed"* ]]
  [[ "$output" != *"complete: yes"* ]]
}

@test "gh-public-history-scan (real gitleaks): inherited GIT_CONFIG_COUNT, GIT_DIR, GIT_TRACE and GITLEAKS_CONFIG are ignored" {
  use_real_gitleaks
  gh_repo alpha 101 public false disabled
  local d evil
  d="$(src_repo alpha)"
  printf 'aws_key = "%s"\n' "$KEY" >"$d/conf.txt"
  git -C "$d" add conf.txt
  git -C "$d" commit -q -m conf
  # A clean decoy: if the insteadOf rewrite were honoured, the clone would
  # silently come from here and the run would look clean.
  mkdir -p "$T/evil/$OWNER"
  git init -q -b main "$T/evil/$OWNER/alpha.git"
  echo decoy >"$T/evil/$OWNER/alpha.git/README"
  git -C "$T/evil/$OWNER/alpha.git" add README
  git -C "$T/evil/$OWNER/alpha.git" commit -q -m decoy
  printf '[allowlist]\npaths = [".*"]\n' >"$T/allow-all.toml"
  EXTRA_ENV=(GIT_CONFIG_COUNT=1 "GIT_CONFIG_KEY_0=url.file://$T/evil/.insteadOf" "GIT_CONFIG_VALUE_0=file://$SRC/"
    GIT_DIR="$T/nowhere" GIT_WORK_TREE="$T/nowhere" GIT_TRACE="$T/trace.log" GIT_TRACE2_EVENT="$T/trace2.log"
    GITLEAKS_CONFIG="$T/allow-all.toml" GITLEAKS_CONFIG_TOML="$(cat "$T/allow-all.toml")")
  run_scan --owner "$OWNER"
  assert_failure 10
  [[ "$(mfield alpha 4)" == findings && "$(mfield alpha 5)" == 1 ]]
  [[ ! -e "$T/trace.log" && ! -e "$T/trace2.log" ]]
}

@test "gh-public-history-scan: credential helper - invoked without isolation (control), never by the scan against an HTTP 401" {
  cat >"$T/srv.pl" <<'EOF'
use strict; use IO::Socket::INET;
my $s = IO::Socket::INET->new(LocalAddr => '127.0.0.1', LocalPort => 0, Listen => 5, ReuseAddr => 1) or die "listen: $!";
open my $p, '>', "$ARGV[0].tmp" or die; print $p $s->sockport; close $p; rename "$ARGV[0].tmp", $ARGV[0];
while (my $c = $s->accept) {
  my $first = <$c>;
  while (my $l = <$c>) { last if $l =~ /^\r?\n$/ }
  open my $log, '>>', $ARGV[1]; print $log $first; close $log;
  print $c "HTTP/1.1 401 Unauthorized\r\nWWW-Authenticate: Basic realm=\"synthetic\"\r\nContent-Length: 0\r\nConnection: close\r\n\r\n";
  close $c;
}
EOF
  /usr/bin/perl "$T/srv.pl" "$T/port" "$T/requests.log" &
  echo $! >"$FIX/srv.pid"
  local i=0
  while [[ ! -s "$T/port" && $i -lt 50 ]]; do
    sleep 0.1
    i=$((i + 1))
  done
  [[ -s "$T/port" ]]
  local port
  port="$(cat "$T/port")"
  cat >"$T/helper" <<EOF
#!/bin/sh
echo "helper \$*" >>"$T/helper.log"
[ "\$1" = get ] && printf 'username=synth\npassword=synth\n'
exit 0
EOF
  printf '#!/bin/sh\necho askpass >>"%s/askpass.log"\necho synth\n' "$T" >"$T/askpass"
  chmod +x "$T/helper" "$T/askpass"
  printf '[credential]\n\thelper = %s\n' "$T/helper" >"$T/helper.gitconfig"

  # Positive control: plain git with the same config does call the helper.
  run env -i HOME="$T/ctl-home" PATH="/usr/bin:/bin" GIT_CONFIG_NOSYSTEM=1 GIT_CONFIG_GLOBAL="$T/helper.gitconfig" \
    GIT_TERMINAL_PROMPT=0 "$REAL_GIT" clone -q --mirror "http://127.0.0.1:$port/$OWNER/alpha.git" "$T/ctl.git"
  assert_failure
  grep -q '^helper get' "$T/helper.log"
  rm -f "$T/helper.log" "$T/askpass.log"
  : >"$T/requests.log"

  gh_repo alpha 101 public false disabled
  CLONE_BASE="http://127.0.0.1:$port"
  EXTRA_ENV=(GIT_CONFIG_GLOBAL="$T/helper.gitconfig" GIT_CONFIG_COUNT=1 GIT_CONFIG_KEY_0=credential.helper
    "GIT_CONFIG_VALUE_0=$T/helper" GIT_ASKPASS="$T/askpass" SSH_ASKPASS="$T/askpass")
  run_scan --owner "$OWNER"
  assert_failure 1
  [[ "$(mfield alpha 4)" == error && "$(mfield alpha 12)" == *clone* ]]
  grep -q "GET /$OWNER/alpha.git/info/refs" "$T/requests.log"
  [[ ! -e "$T/helper.log" && ! -e "$T/askpass.log" ]]
}

@test "gh-public-history-scan (real gitleaks): an evil merge (secret only in the resolution) is found with the merge commit and file" {
  use_real_gitleaks
  gh_repo alpha 101 public false disabled
  local d m
  d="$(src_repo alpha)"
  diverge "$d"
  m="$(evil_merge "$d" evil.txt)"
  run_scan --owner "$OWNER"
  assert_failure 10
  [[ "$(mfield alpha 4)" == findings && "$(mfield alpha 5)" == 1 && "$(mfield alpha 11)" == 1 ]]
  [[ "$(frows alpha)" == "alpha"$'\t'"101"$'\t'"merge-touched-file"$'\t'"$m"$'\t'"evil.txt"$'\t'"aws-access-token"$'\t'"1"$'\t'"$m:evil.txt:aws-access-token:1" ]]
  assert_no_secret stdout "$output"
  assert_no_secret_on_disk
}

@test "gh-public-history-scan (real gitleaks): an evil merge that also adds an allowlisting .gitleaks.toml, .gitleaksignore and gitleaks:allow is still found" {
  use_real_gitleaks
  gh_repo alpha 101 public false disabled
  local d m
  d="$(src_repo alpha)"
  diverge "$d"
  git -C "$d" merge -q --no-ff --no-commit side >/dev/null 2>&1
  printf 'aws_key = "%s" # gitleaks:allow\n' "$KEY" >"$d/evil.txt"
  printf '[allowlist]\npaths = [".*"]\n' >"$d/.gitleaks.toml"
  printf 'evil.txt:aws-access-token:1\nrepo/evil.txt:aws-access-token:1\n' >"$d/.gitleaksignore"
  git -C "$d" add evil.txt .gitleaks.toml .gitleaksignore
  git -C "$d" commit -q -m merge
  m="$(git -C "$d" rev-parse HEAD)"
  run_scan --owner "$OWNER"
  assert_failure 10
  frows alpha | grep -q $'\tmerge-touched-file\t'"$m"$'\tevil.txt\taws-access-token\t1\t'
}

@test "gh-public-history-scan (real gitleaks): an octopus merge's resolution is scanned" {
  use_real_gitleaks
  gh_repo alpha 101 public false disabled
  local d m
  d="$(src_repo alpha)"
  diverge "$d"
  git -C "$d" checkout -q -b third main~1
  echo third >"$d/third.txt"
  git -C "$d" add third.txt
  git -C "$d" commit -q -m third
  git -C "$d" checkout -q main
  git -C "$d" merge -q --no-ff --no-commit side third >/dev/null 2>&1
  printf 'aws_key = "%s"\n' "$KEY" >"$d/octo.txt"
  git -C "$d" add octo.txt
  git -C "$d" commit -q -m octopus
  m="$(git -C "$d" rev-parse HEAD)"
  [[ "$(git -C "$d" rev-list --parents -n1 "$m" | wc -w | tr -d ' ')" -eq 4 ]]
  run_scan --owner "$OWNER"
  assert_failure 10
  frows alpha | grep -q $'\tmerge-touched-file\t'"$m"$'\tocto.txt\t'
}

@test "gh-public-history-scan (real gitleaks): a rename in a merge reports the (nested) destination path; the deleted source is skipped" {
  use_real_gitleaks
  gh_repo alpha 101 public false disabled
  local d m
  d="$(src_repo alpha)"
  echo "plain" >"$d/a.txt"
  git -C "$d" add a.txt
  git -C "$d" commit -q -m a
  diverge "$d"
  git -C "$d" merge -q --no-ff --no-commit side >/dev/null 2>&1
  mkdir -p "$d/sub/dir"
  git -C "$d" mv a.txt sub/dir/b.txt
  printf 'aws_key = "%s"\n' "$KEY" >>"$d/sub/dir/b.txt"
  git -C "$d" add -A
  git -C "$d" commit -q -m merge
  m="$(git -C "$d" rev-parse HEAD)"
  run_scan --owner "$OWNER"
  assert_failure 10
  frows alpha | grep -q $'\tmerge-touched-file\t'"$m"$'\tsub/dir/b.txt\taws-access-token\t2\t'
  [[ "$(mfield alpha 12)" == *"deleted=1"* ]]
}

@test "gh-public-history-scan: deleted-in-merge, symlink and gitlink entries are skipped and counted" {
  gh_repo alpha 101 public false disabled
  local d lb sub
  d="$(src_repo alpha)"
  echo keep >"$d/gone.txt"
  git -C "$d" add gone.txt
  git -C "$d" commit -q -m gone
  diverge "$d"
  lb="$(printf '/etc/passwd' | git -C "$d" hash-object -w --stdin)"
  sub="$(git -C "$d" rev-parse HEAD)"
  plumb_merge "$d" "grep -v 'gone.txt\$'; printf '120000 blob $lb\tlink\n160000 commit $sub\tmod\n'" >/dev/null
  run_scan --owner "$OWNER"
  assert_success
  [[ "$(mfield alpha 4)" == clean ]]
  [[ "$(mfield alpha 12)" == *"deleted=1"*"symlink=1"*"gitlink=1"* ]]
  # Nothing was exported, so no merge-tree scan ran.
  [[ ! -s "$FIX/dir.list" ]]
}

@test "gh-public-history-scan: each merge is scanned in a fresh tree (no earlier merge's files)" {
  gh_repo alpha 101 public false disabled
  local d
  d="$(src_repo alpha)"
  diverge "$d"
  evil_merge "$d" one.txt >/dev/null
  git -C "$d" checkout -q side
  echo more >"$d/side2.txt"
  git -C "$d" add side2.txt
  git -C "$d" commit -q -m side2
  git -C "$d" checkout -q main
  evil_merge "$d" two.txt >/dev/null
  run_scan --owner "$OWNER"
  assert_success
  [[ "$(grep -c . "$FIX/dir.list")" -eq 2 ]]
  grep -qx './repo/one.txt ' "$FIX/dir.list"
  grep -qx './repo/two.txt ' "$FIX/dir.list"
}

@test "gh-public-history-scan: case-colliding paths in one merge are an error, never overwritten" {
  gh_repo alpha 101 public false disabled
  local d b1 b2
  d="$(src_repo alpha)"
  diverge "$d"
  b1="$(printf 'one' | git -C "$d" hash-object -w --stdin)"
  b2="$(printf 'two' | git -C "$d" hash-object -w --stdin)"
  plumb_merge "$d" "cat; printf '100644 blob $b1\tKey.txt\n100644 blob $b2\tkey.txt\n'" >/dev/null
  # Parent-dir clash: Dir/x and dir/y would silently share one directory
  # (and be reported under the wrong path) on a case-insensitive disk.
  gh_repo beta 102 public false disabled
  local e t1 t2
  e="$(src_repo beta)"
  diverge "$e"
  b1="$(printf 'one' | git -C "$e" hash-object -w --stdin)"
  t1="$(printf '100644 blob %s\tx\n' "$b1" | git -C "$e" mktree)"
  t2="$(printf '100644 blob %s\ty\n' "$b1" | git -C "$e" mktree)"
  plumb_merge "$e" "cat; printf '040000 tree $t1\tDir\n040000 tree $t2\tdir\n'" >/dev/null
  run_scan --owner "$OWNER"
  assert_failure 1
  [[ "$(mfield alpha 4)" == error && "$(mfield alpha 12)" == *case* ]]
  [[ "$(mfield beta 4)" == error && "$(mfield beta 12)" == *case-colliding* ]]
}

@test "gh-public-history-scan (real gitleaks): --resume re-runs error and count-mismatched repos and keeps settled ones" {
  use_real_gitleaks
  gh_repo aaa 401 public false disabled
  gh_repo bbb 402 public false disabled
  gh_repo ccc 403 public false disabled
  src_repo aaa >/dev/null
  local d sd
  d="$(src_repo ccc)"
  printf 'aws_key = "%s"\n' "$KEY" >"$d/conf.txt"
  git -C "$d" add conf.txt
  git -C "$d" commit -q -m conf
  run_scan --owner "$OWNER"
  assert_failure 1
  sd="$(scan_dir)"
  [[ "$(mfield aaa 4)" == clean && "$(mfield bbb 4)" == error && "$(mfield ccc 4)" == findings ]]
  # bbb becomes cloneable; ccc's published findings lose a row.
  src_repo bbb >/dev/null
  awk -F'\t' '$1 != "ccc"' "$sd/findings.tsv" >"$T/f" && cat "$T/f" >"$sd/findings.tsv"
  : >"$FIX/gl.calls"
  run_scan --owner "$OWNER" --resume "$sd"
  assert_failure 10
  [[ "$(scan_dir)" == "$sd" ]]
  [[ "$(calls_for 401)" -eq 0 ]]
  [[ "$(calls_for 402)" -ge 1 && "$(calls_for 403)" -ge 1 ]]
  [[ "$(mfield aaa 4)" == clean && "$(mfield bbb 4)" == clean && "$(mfield ccc 4)" == findings ]]
  [[ "$(frows ccc | grep -c .)" -eq 1 && "$(mfield ccc 5)" -eq 1 ]]
}

# --- lock ----------------------------------------------------------------------------

# one_scan_dir: a finished one-repo scan dir (stub gitleaks); prints it.
one_scan_dir() {
  gh_repo alpha 101 public false disabled
  src_repo alpha >/dev/null
  run_scan --owner "$OWNER"
  [[ "$status" -eq 0 ]] || return 1
  scan_dir
}

# bg_scan <tag> [args...]: run the scan in the background; rc/out/err files.
bg_scan() {
  local tag="$1"
  shift
  (
    rc=0
    env -i HOME="$FAKE_HOME" TMPDIR="$TMPD" \
      GH_SCAN_GH="$T/gh" GH_SCAN_BASE_PATH="$BIN:/usr/bin:/bin:/usr/sbin:/sbin" \
      GH_SCAN_CLONE_BASE="$CLONE_BASE" GH_SCAN_TEST_INSECURE_URLS=1 \
      GH_SCAN_TIMEOUT="$TIMEOUT" GH_SCAN_KILL_GRACE=1 \
      ${EXTRA_ENV[@]+"${EXTRA_ENV[@]}"} \
      /bin/bash "$SCRIPT" "$@" </dev/null >"$T/$tag.out" 2>"$T/$tag.err" || rc=$?
    echo "$rc" >"$T/$tag.rc"
  ) &
  BG_PIDS+=($!)
}

dead_pid() {
  /bin/sh -c 'exit 0' &
  local p=$!
  wait "$p"
  echo "$p"
}

@test "gh-public-history-scan: a fresh ownerless lock and a live owner are busy (exit 75); nothing is reclaimed or changed" {
  local sd
  sd="$(one_scan_dir)"
  cp "$sd/manifest.tsv" "$T/manifest.before"
  : >"$sd/.lock"
  run_scan --owner "$OWNER" --resume "$sd"
  assert_failure 75
  [[ "$stderr" == *"in use"* ]]
  [[ -e "$sd/.lock" && ! -s "$sd/.lock" ]]
  cmp -s "$T/manifest.before" "$sd/manifest.tsv"
  printf 'pid=%s\nstarted=%s\n' "$$" "$(date +%s)" >"$sd/.lock"
  run_scan --owner "$OWNER" --resume "$sd"
  assert_failure 75
  grep -qx "pid=$$" "$sd/.lock"
}

@test "gh-public-history-scan: a dead-owner lock and an old ownerless lock are reclaimed" {
  local sd
  sd="$(one_scan_dir)"
  printf 'pid=%s\nstarted=1\n' "$(dead_pid)" >"$sd/.lock"
  run_scan --owner "$OWNER" --resume "$sd"
  assert_success
  [[ ! -e "$sd/.lock" ]]
  : >"$sd/.lock"
  touch -t 200001010000 "$sd/.lock"
  run_scan --owner "$OWNER" --resume "$sd"
  assert_success
  [[ ! -e "$sd/.lock" ]]
}

@test "gh-public-history-scan: concurrent contenders for a stale lock - exactly one proceeds" {
  local sd i ok=0 busy=0 rc
  sd="$(one_scan_dir)"
  printf 'pid=%s\nstarted=1\n' "$(dead_pid)" >"$sd/.lock"
  # Inside the reclaim mutex: reclaim-locked is a barrier (up to 2s) for all
  # four contenders, and reclaim-decided (between re-inspection and removal)
  # sleeps 1..4s by arrival order, so unserialized reclaimers would all judge
  # the old lock stale together and then remove each other's fresh locks one
  # after another. The winner holds the lock (locked) until every contender
  # has decided.
  cat >"$T/hook" <<EOF
#!/bin/sh
case "\$1" in
  reclaim-locked)
    : >"$T/arrived.\$PPID"
    n=1
    until mkdir "$T/ticket.\$n" 2>/dev/null; do n=\$((n + 1)); done
    echo "\$n" >"$T/order.\$PPID"
    i=0
    while [ "\$(ls "$T" | grep -c '^arrived\.')" -lt 4 ] && [ \$i -lt 20 ]; do sleep 0.1; i=\$((i + 1)); done
    ;;
  reclaim-decided) sleep "\$(cat "$T/order.\$PPID")" ;;
  locked) sleep 12 ;;
esac
exit 0
EOF
  chmod +x "$T/hook"
  EXTRA_ENV=(GH_SCAN_TEST_HOOK="$T/hook")
  BG_PIDS=()
  for i in 1 2 3 4; do bg_scan "c$i" --owner "$OWNER" --resume "$sd"; done
  for i in "${BG_PIDS[@]}"; do wait "$i" || true; done
  for i in 1 2 3 4; do
    rc="$(cat "$T/c$i.rc")"
    case "$rc" in
      0) ok=$((ok + 1)) ;;
      75) busy=$((busy + 1)) ;;
      *)
        echo "contender $i exited $rc" >&2
        return 1
        ;;
    esac
  done
  for i in 1 2 3 4; do echo "c$i rc=$(cat "$T/c$i.rc") $(cat "$T/c$i.err")" >&2; done
  [[ "$ok" -eq 1 && "$busy" -eq 3 ]]
  [[ ! -e "$sd/.lock" ]]
}

# --- log -----------------------------------------------------------------------------

@test "gh-public-history-scan: --log writes everything to a 600 file without ACL entries; a symlink is refused" {
  gh_repo alpha 101 public false disabled
  src_repo alpha >/dev/null
  mkdir -p "$T/logs"
  /bin/chmod +a "everyone allow read,file_inherit" "$T/logs"
  run_scan --owner "$OWNER" --log "$T/logs/scan.log"
  assert_success
  [[ -z "$output" && -z "$stderr" ]]
  [[ "$(/bin/ls -le "$T/logs/scan.log" | grep -c .)" -eq 1 ]]
  [[ "$(/bin/ls -le "$T/logs/scan.log" | cut -c1-11)" == "-rw------- " ]]
  grep -q 'complete: yes' "$T/logs/scan.log"
  ln -s "$T/elsewhere.log" "$T/logs/link.log"
  run_scan --owner "$OWNER" --log "$T/logs/link.log"
  assert_failure 2
  [[ ! -e "$T/elsewhere.log" ]]
}

# --- isolation layers ------------------------------------------------------------------
#
# env -i already removes every inherited config channel (GIT_CONFIG_*,
# GIT_CONFIG_GLOBAL, GIT_ASKPASS, ...; see the tests above). These tests check
# the remaining layers on their own by planting config in places the isolated
# git could still read (via the test-only work-ready hook, which receives the
# private work dir): the clone template (repo-level config) and the private
# HOME (credential.helper=, core.askPass= and GIT_CONFIG_GLOBAL=/dev/null are
# each mutation-checked on their own). GIT_CONFIG_NOSYSTEM=1 is not tested on
# its own: the system config path is compiled into git (e.g.
# /opt/homebrew/etc/gitconfig, which here carries the real osxkeychain helper)
# and env -i strips GIT_CONFIG_SYSTEM, so the only way to exercise it would be
# to read or call the real system config and keychain helper.

start_401_server() {
  cat >"$T/srv.pl" <<'EOF'
use strict; use IO::Socket::INET;
my $s = IO::Socket::INET->new(LocalAddr => '127.0.0.1', LocalPort => 0, Listen => 5, ReuseAddr => 1) or die "listen: $!";
open my $p, '>', "$ARGV[0].tmp" or die; print $p $s->sockport; close $p; rename "$ARGV[0].tmp", $ARGV[0];
while (my $c = $s->accept) {
  my $first = <$c>;
  while (my $l = <$c>) { last if $l =~ /^\r?\n$/ }
  open my $log, '>>', $ARGV[1]; print $log $first; close $log;
  print $c "HTTP/1.1 401 Unauthorized\r\nWWW-Authenticate: Basic realm=\"synthetic\"\r\nContent-Length: 0\r\nConnection: close\r\n\r\n";
  close $c;
}
EOF
  /usr/bin/perl "$T/srv.pl" "$T/port" "$T/requests.log" &
  echo $! >"$FIX/srv.pid"
  local i=0
  while [[ ! -s "$T/port" && $i -lt 50 ]]; do
    sleep 0.1
    i=$((i + 1))
  done
  [[ -s "$T/port" ]] || return 1
  PORT="$(cat "$T/port")"
  cat >"$T/helper" <<EOF
#!/bin/sh
echo "helper \$*" >>"$T/helper.log"
[ "\$1" = get ] && printf 'username=synth\npassword=synth\n'
exit 0
EOF
  chmod +x "$T/helper"
}

@test "gh-public-history-scan: credential.helper= alone keeps a helper from repo-level (template) config unused" {
  start_401_server
  mkdir -p "$T/tpl"
  printf '[credential]\n\thelper = %s\n' "$T/helper" >"$T/tpl/config"
  # Control: an otherwise isolated git does read the template's helper.
  run env -i HOME="$T/ctl-home" PATH="/usr/bin:/bin" GIT_CONFIG_NOSYSTEM=1 GIT_CONFIG_GLOBAL=/dev/null \
    GIT_TERMINAL_PROMPT=0 "$REAL_GIT" clone -q --mirror --template="$T/tpl" "http://127.0.0.1:$PORT/$OWNER/alpha.git" "$T/ctl.git"
  assert_failure
  grep -q '^helper get' "$T/helper.log"
  rm -f "$T/helper.log"
  cat >"$T/hook" <<EOF
#!/bin/sh
[ "\$1" = work-ready ] && cp "$T/tpl/config" "\$2/template/config"
exit 0
EOF
  chmod +x "$T/hook"
  gh_repo alpha 101 public false disabled
  CLONE_BASE="http://127.0.0.1:$PORT"
  EXTRA_ENV=(GH_SCAN_TEST_HOOK="$T/hook")
  : >"$T/requests.log"
  run_scan --owner "$OWNER"
  assert_failure 1
  [[ "$(mfield alpha 4)" == error ]]
  grep -q "GET /$OWNER/alpha.git/info/refs" "$T/requests.log"
  [[ ! -e "$T/helper.log" ]]
}

@test "gh-public-history-scan: GIT_CONFIG_GLOBAL=/dev/null alone keeps config in the private HOME unread" {
  gh_repo alpha 101 public false disabled
  src_repo alpha >/dev/null
  printf '[url "file:///nonexistent-synth/"]\n\tinsteadOf = file://%s/\n' "$SRC" >"$T/home.gitconfig"
  # Control: git that reads this HOME config cannot clone.
  mkdir -p "$T/ctl-home"
  cp "$T/home.gitconfig" "$T/ctl-home/.gitconfig"
  run env -i HOME="$T/ctl-home" PATH="/usr/bin:/bin" GIT_CONFIG_NOSYSTEM=1 \
    "$REAL_GIT" clone -q --mirror "file://$SRC/$OWNER/alpha.git" "$T/ctl.git"
  assert_failure
  cat >"$T/hook" <<EOF
#!/bin/sh
[ "\$1" = work-ready ] || exit 0
cp "$T/home.gitconfig" "\$2/home/.gitconfig"
mkdir -p "\$2/home/.config/git"
cp "$T/home.gitconfig" "\$2/home/.config/git/config"
exit 0
EOF
  chmod +x "$T/hook"
  EXTRA_ENV=(GH_SCAN_TEST_HOOK="$T/hook")
  run_scan --owner "$OWNER"
  assert_success
  [[ "$(mfield alpha 4)" == clean ]]
}

@test "gh-public-history-scan: core.askPass= alone keeps an askpass from repo-level (template) config unused" {
  start_401_server
  printf '#!/bin/sh\necho askpass >>"%s/askpass.log"\necho synth\n' "$T" >"$T/askpass"
  chmod +x "$T/askpass"
  mkdir -p "$T/tpl"
  printf '[core]\n\taskPass = %s\n' "$T/askpass" >"$T/tpl/config"
  # Control: an otherwise isolated git (no helper, no terminal prompt) does
  # run the template's askpass.
  run env -i HOME="$T/ctl-home" PATH="/usr/bin:/bin" GIT_CONFIG_NOSYSTEM=1 GIT_CONFIG_GLOBAL=/dev/null \
    GIT_TERMINAL_PROMPT=0 "$REAL_GIT" clone -q --mirror --template="$T/tpl" "http://127.0.0.1:$PORT/$OWNER/alpha.git" "$T/ctl.git"
  assert_failure
  grep -q askpass "$T/askpass.log"
  rm -f "$T/askpass.log"
  cat >"$T/hook" <<EOF
#!/bin/sh
[ "\$1" = work-ready ] && cp "$T/tpl/config" "\$2/template/config"
exit 0
EOF
  chmod +x "$T/hook"
  gh_repo alpha 101 public false disabled
  CLONE_BASE="http://127.0.0.1:$PORT"
  EXTRA_ENV=(GH_SCAN_TEST_HOOK="$T/hook")
  : >"$T/requests.log"
  run_scan --owner "$OWNER"
  assert_failure 1
  [[ "$(mfield alpha 4)" == error ]]
  grep -q "GET /$OWNER/alpha.git/info/refs" "$T/requests.log"
  [[ ! -e "$T/askpass.log" ]]
}

# --- lock: legacy directory locks and the publication seam ---------------------------

@test "gh-public-history-scan: a legacy .lock/ dir with a live pid stays busy and untouched, even when old" {
  local sd
  sd="$(one_scan_dir)"
  mkdir "$sd/.lock"
  echo "$$" >"$sd/.lock/pid"
  touch -t 200001010000 "$sd/.lock/pid" "$sd/.lock"
  run_scan --owner "$OWNER" --resume "$sd"
  assert_failure 75
  [[ "$stderr" == *"live pid $$"* ]]
  [[ -d "$sd/.lock" && "$(cat "$sd/.lock/pid")" == "$$" ]]
}

@test "gh-public-history-scan: a legacy .lock/ dir with a dead pid is reclaimed" {
  local sd
  sd="$(one_scan_dir)"
  mkdir "$sd/.lock"
  dead_pid >"$sd/.lock/pid"
  run_scan --owner "$OWNER" --resume "$sd"
  assert_success
  [[ ! -e "$sd/.lock" ]]
}

@test "gh-public-history-scan: TERM at the lock publication seam leaves no lock and no lock temp" {
  local sd
  sd="$(one_scan_dir)"
  printf '#!/bin/sh\n[ "$1" = lock-linked ] && kill -TERM "$PPID"\nexit 0\n' >"$T/hook"
  chmod +x "$T/hook"
  EXTRA_ENV=(GH_SCAN_TEST_HOOK="$T/hook")
  run_scan --owner "$OWNER" --resume "$sd"
  assert_failure 143
  [[ ! -e "$sd/.lock" ]]
  [[ -z "$(find "$sd" -name '.lock.tmp.*')" ]]
}

@test "gh-public-history-scan: --log refuses (exit 2) when the opened file is not the verified one" {
  gh_repo alpha 101 public false disabled
  src_repo alpha >/dev/null
  mkdir -p "$T/logs"
  cat >"$T/hook" <<'EOF'
#!/bin/sh
[ "$1" = log-verified ] || exit 0
mv "$2" "$2.moved"
: >"$2"
chmod 644 "$2"
exit 0
EOF
  chmod +x "$T/hook"
  EXTRA_ENV=(GH_SCAN_TEST_HOOK="$T/hook")
  run_scan --owner "$OWNER" --log "$T/logs/scan.log"
  assert_failure 2
  [[ "$stderr" == *"--log"* ]]
  [[ ! -s "$T/logs/scan.log" && ! -s "$T/logs/scan.log.moved" ]]
  [[ ! -d "$STATE" ]] || [[ -z "$(scan_dir)" ]]
}
