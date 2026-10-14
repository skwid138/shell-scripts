#!/usr/bin/env bash
# gh-public-history-scan.sh — local, read-only gitleaks history scan of an
# owner's PUBLIC GitHub repositories whose secret scanning is disabled, run
# before secret scanning is turned on (GitHub only scans new pushes plus its
# own backfill; this is the independent check of what is already public).
#
# Per repo, sequentially: a bare `git clone --mirror` (https only), a
# `gitleaks git` pass over every ref, and a merge overscan (`gitleaks dir`
# over the files each merge commit's resolution changed, which `gitleaks git`
# never reads). git and gitleaks run under `env -i` with an allowlisted
# environment, no git config, no credential helper, a pinned gitleaks and a
# private config. Results are metadata only (never secret values).
#
# Designed for macOS /bin/bash 3.2: builds its own PATH, never prompts,
# never uses `set -e`. Makes only GET requests to the GitHub API.

set -uo pipefail

SCRIPT_DIR="$(cd "$(dirname "${BASH_SOURCE[0]}")" && pwd)"
# shellcheck source=../lib/common.sh
source "$SCRIPT_DIR/../lib/common.sh"

usage() {
  cat <<'EOF'
Usage: gh-public-history-scan [--owner LOGIN] [--only a,b | --repos FILE]
                              [--resume DIR] [--timeout SECS] [--dry-run]
                              [--log FILE]

Scan the full git history of every PUBLIC repo owned by LOGIN whose
secret_scanning status is "disabled", with a pinned gitleaks (8.30.1).
Read-only: GitHub API GETs and anonymous https clones only.

Options:
  --owner LOGIN   Repo owner (default: the authenticated `gh api user`).
  --only a,b      Limit targets to these repo names (comma-separated).
  --repos FILE    Limit targets to the names in FILE (one per line, # comments).
  --resume DIR    Continue an earlier scan dir: repos whose manifest status is
                  error / timeout / not-attempted, or whose findings.tsv row
                  count disagrees with the manifest, are scanned again; settled
                  repos (clean / findings / empty) are kept. The inventory is
                  re-read; without --only/--repos the scope saved in the dir's
                  scope.txt is reused, so a limited (pilot) dir stays limited:
                  it can never be resumed into a full scan (start a new scan
                  dir for that). One run per dir at a time (.lock; exit 75).
  --timeout SECS  Bound for each clone / git / gitleaks command (default 3600).
  --dry-run       Inventory only: print targets, skips and errors; no clones,
                  no scans, nothing written.
  --log FILE      Send stdout and stderr to FILE, created 600 without ACL
                  entries (never through a symlink) before anything is written.
  -h, --help      Show this help.

Inventory:
  `gh api --paginate user/repos?affiliation=owner`, filtered to the owner and
  deduplicated by id, then `gh api repos/<owner>/<repo>` per public repo (the
  list endpoint omits security_and_analysis). Targets: public repos with
  secret_scanning.status == "disabled". A missing / null / unparseable status
  or a failed GET is an ERROR row, never silently skipped. The inventory is
  complete only if pagination and every GET succeeded (inventory.meta).

Per repo (sequential):
  1. git clone --mirror over https (process group, TERM then KILL on timeout).
     Ref snapshot = sha256 of `git for-each-ref`. empty = cloned with no
     commits reachable from any ref. A clone failure is an error, never empty.
  2. History pass: gitleaks git <mirror> (all refs).
  3. Merge overscan: for every merge commit, the paths of
     `git diff-tree --cc --no-renames` (content differing from every parent)
     are exported from the merge tree into a fresh private dir
     tree/repo/<path> and scanned with gitleaks dir <tree>. Deleted paths,
     symlinks (120000) and gitlinks (160000) are skipped and counted;
     absolute / ".." paths and case-colliding paths are errors. Findings are
     labelled pass=merge-touched-file: the line may be inherited from a parent
     rather than introduced by the merge. Fingerprint <merge>:<path>:<rule>:<line>.

gitleaks is run with an explicit private config ([extend] useDefault = true),
an empty --gitleaks-ignore-path, --ignore-gitleaks-allow, --redact=100,
--exit-code=10 and a JSON report; repo-provided .gitleaks.toml,
.gitleaksignore and gitleaks:allow comments are never honoured. A scan is
clean only when gitleaks exits 0 with an empty JSON array and no ERR/FTL
diagnostic line; exit 10 needs >= 1 finding; anything else is an error.

Known blind spot: gitleaks reports a failure of the `git log` it spawns
(cmd.Wait) only at debug level. A git that dies without writing to stderr can
therefore look like a clean, shorter history. Merge-tree content and the ref
snapshot are independent of it; re-run suspicious repos.

Output (dir 700, files 600, ACLs stripped; not in iCloud):
  ~/Library/Application Support/gh-security-rollout/scan-<UTC>/
    inventory.tsv   repo, repo_id, visibility, fork, secret_scanning, selection
    inventory.meta  owner, timestamps, complete=true|false, pagination, get_failed
    manifest.tsv    repo, repo_id, fork, status, findings, ref_sha256, clone_s,
                    history_s, merge_s, total_s, merges, detail
                    status: clean | findings | empty | error | timeout | not-attempted
    findings.tsv    repo, repo_id, pass (history | merge-touched-file), commit,
                    file, rule, line, fingerprint  (no secret / match / line text)
  findings.tsv is published before manifest.tsv (exclusive temp + rename),
  both before the repo's mirror is deleted.

Exit codes:
  0   every target clean or empty, inventory complete
  10  complete, with findings
  1   any error / timeout / not-attempted repo, incomplete inventory, or a
      failed publication
  2   usage error
  3   missing dependency or a gitleaks other than 8.30.1
  75  the scan dir is locked by another run (or a fresh ownerless lock)

Environment (tests):
  GH_SCAN_GH            gh command (default gh)
  GH_SCAN_BASE_PATH     PATH for this script and its children
  GH_SCAN_TIMEOUT       default for --timeout
  GH_SCAN_KILL_GRACE    seconds between TERM and KILL (default 5)
  GH_SCAN_CLONE_BASE    clone URL base (default https://github.com); http://
                        and file:// only with GH_SCAN_TEST_INSECURE_URLS=1
  GH_SCAN_PERL          perl for process groups and helpers (default /usr/bin/perl)
  GH_SCAN_GROUP_PROBE   `<probe> <pgid>` exit 0 = group alive (test only)
  GH_SCAN_TEST_HOOK     `<hook> <phase> <dir>` at work-ready (the private work
                        dir), locked, reclaim-locked, reclaim-decided,
                        publish-findings (test only)

Examples:
  gh-public-history-scan --dry-run
  gh-public-history-scan --only repo-a,repo-b
  nohup caffeinate -i gh-public-history-scan --timeout 7200 \
    --log ~/Library/Logs/gh-public-history-scan.log >/dev/null 2>&1 &
  gh-public-history-scan --resume "$HOME/Library/Application Support/gh-security-rollout/scan-20261014T120000Z"
EOF
}

# --- arguments -------------------------------------------------------------------

OWNER=""
ONLY=""
REPOS_FILE=""
RESUME=""
DRY_RUN=0
LOG_PATH=""
TIMEOUT="${GH_SCAN_TIMEOUT:-3600}"
while [[ $# -gt 0 ]]; do
  case "$1" in
    -h | --help)
      usage
      exit 0
      ;;
    --owner)
      [[ -n "${2-}" ]] || die_usage "--owner needs a login"
      OWNER="$2"
      shift 2
      ;;
    --only)
      [[ -n "${2-}" ]] || die_usage "--only needs a comma-separated list"
      ONLY="$2"
      shift 2
      ;;
    --repos)
      [[ -n "${2-}" ]] || die_usage "--repos needs a file"
      REPOS_FILE="$2"
      shift 2
      ;;
    --resume)
      [[ -n "${2-}" ]] || die_usage "--resume needs a scan dir"
      RESUME="$2"
      shift 2
      ;;
    --timeout)
      [[ -n "${2-}" ]] || die_usage "--timeout needs seconds"
      TIMEOUT="$2"
      shift 2
      ;;
    --dry-run)
      DRY_RUN=1
      shift
      ;;
    --log)
      [[ -n "${2-}" ]] || die_usage "--log needs a file path"
      LOG_PATH="$2"
      shift 2
      ;;
    *) die_usage "unknown argument: $1 (see --help)" ;;
  esac
done
[[ -n "$ONLY" && -n "$REPOS_FILE" ]] && die_usage "--only and --repos are mutually exclusive"
[[ -n "$RESUME" && "$DRY_RUN" -eq 1 ]] && die_usage "--resume and --dry-run are mutually exclusive"

GITLEAKS_PIN="8.30.1"
SYSTEM_PATH="/usr/bin:/bin:/usr/sbin:/sbin"
export PATH="${GH_SCAN_BASE_PATH:-/opt/homebrew/bin:/usr/local/bin:$SYSTEM_PATH}"
GH="${GH_SCAN_GH:-gh}"
PERL="${GH_SCAN_PERL:-/usr/bin/perl}"
GRACE="${GH_SCAN_KILL_GRACE:-5}"
CLONE_BASE="${GH_SCAN_CLONE_BASE:-https://github.com}"
TEST_HOOK="${GH_SCAN_TEST_HOOK:-}"
GROUP_PROBE="${GH_SCAN_GROUP_PROBE:-}"
STATE_ROOT="$HOME/Library/Application Support/gh-security-rollout"
NAME_RE='^[A-Za-z0-9._-]+$'

[[ "$TIMEOUT" =~ ^[0-9]+$ && "$TIMEOUT" -gt 0 ]] || die_usage "--timeout / GH_SCAN_TIMEOUT must be a positive integer"
[[ "$GRACE" =~ ^[0-9]+$ ]] || die_usage "GH_SCAN_KILL_GRACE must be a non-negative integer"
case "$CLONE_BASE" in
  https://*) ;;
  http://* | file://*)
    [[ "${GH_SCAN_TEST_INSECURE_URLS:-}" == 1 ]] ||
      die_usage "clone base must be an https:// URL (got $CLONE_BASE)"
    ;;
  *) die_usage "clone base must be an https:// URL (got $CLONE_BASE)" ;;
esac
CLONE_BASE="${CLONE_BASE%/}"
CLONE_PROTO="${CLONE_BASE%%:*}"

valid_name() { [[ "$1" =~ $NAME_RE && "$1" != "." && "$1" != ".." ]]; }

umask 077

# --- work dir, process groups, cleanup ---------------------------------------------

WORK=""
CUR_PGID=""
WD_PID=""
RG_ERR=""
RG_SEQ=0
READY_WAIT=5
KILL_WAIT=2
LOCK_FILE=""
LOCK_HELD=0
LOCK_ERR=""
FATAL=0
FATAL_MSG=""

# group_live <pgid> <direct>: some process of the group can still be
# signalled, or (direct=1) its leader pid still exists.
group_live() {
  if [[ -n "$GROUP_PROBE" ]]; then
    "$GROUP_PROBE" "$1" </dev/null >/dev/null 2>&1 && return 0
  else
    kill -0 -- "-$1" 2>/dev/null && return 0
  fi
  [[ "$2" -eq 1 ]] && kill -0 "$1" 2>/dev/null
}

# reap_group <pgid> [direct]: TERM the group, GRACE seconds, KILL, KILL_WAIT.
# 0 = confirmed empty; 1 = something still runs.
reap_group() {
  local pg="$1" direct="${2:-1}" end
  [[ -n "$pg" ]] || return 0
  if ! kill -TERM -- "-$pg" 2>/dev/null; then
    [[ "$direct" -eq 1 ]] && kill -TERM "$pg" 2>/dev/null
  fi
  end=$((SECONDS + GRACE))
  while group_live "$pg" "$direct" && [[ $SECONDS -lt $end ]]; do
    sleep 0.1
  done
  if group_live "$pg" "$direct"; then
    kill -KILL -- "-$pg" 2>/dev/null
    [[ "$direct" -eq 1 ]] && kill -KILL "$pg" 2>/dev/null
    end=$((SECONDS + KILL_WAIT))
    while group_live "$pg" "$direct" && [[ $SECONDS -lt $end ]]; do
      sleep 0.1
    done
  fi
  kill -0 "$pg" 2>/dev/null || wait "$pg" 2>/dev/null
  ! group_live "$pg" "$direct"
}

stop_watchdog() {
  if [[ -n "$WD_PID" ]]; then
    kill -TERM "$WD_PID" 2>/dev/null
    wait "$WD_PID" 2>/dev/null
    WD_PID=""
  fi
}

# shellcheck disable=SC2329  # invoked via trap
cleanup() {
  CRIT_DEPTH=$((CRIT_DEPTH + 1))
  stop_watchdog
  if [[ -n "$CUR_PGID" ]]; then
    reap_group "$CUR_PGID" && CUR_PGID=""
  fi
  if [[ -n "$WORK" && -d "$WORK" ]]; then
    if [[ -z "$CUR_PGID" ]]; then
      rm -rf "$WORK"
    else
      warn "process group $CUR_PGID could not be confirmed empty; leaving $WORK in place (remove it once nothing runs)"
    fi
  fi
  release_lock
}
# Signals inside a critical section (a child launched but not yet
# registered) are recorded and delivered at its end.
CRIT_DEPTH=0
PENDING_SIG=""
on_signal() {
  if [[ "$CRIT_DEPTH" -gt 0 ]]; then
    [[ -n "$PENDING_SIG" ]] || PENDING_SIG="$1"
    return 0
  fi
  exit "$1"
}
begin_critical() { CRIT_DEPTH=$((CRIT_DEPTH + 1)); }
end_critical() {
  [[ "$CRIT_DEPTH" -gt 0 ]] && CRIT_DEPTH=$((CRIT_DEPTH - 1))
  if [[ "$CRIT_DEPTH" -eq 0 && -n "$PENDING_SIG" ]]; then
    exit "$PENDING_SIG"
  fi
  return 0
}
trap cleanup EXIT
trap 'on_signal 130' INT
trap 'on_signal 143' TERM

# ls_led_ok <path> <mode-string>: one `ls -led` line, that mode, no ACL.
ls_led_ok() {
  local out
  out="$(LC_ALL=C /bin/ls -led -- "$1" 2>/dev/null)" || return 1
  [[ -n "$out" && "$out" != *$'\n'* && "${out:0:10}" == "$2" && "${out:10:1}" != "+" ]]
}

# private_dir <path>: create (if needed) a 700 dir without ACL, verified.
private_dir() {
  mkdir -p "$1" 2>/dev/null && /bin/chmod 700 "$1" 2>/dev/null && /bin/chmod -N "$1" 2>/dev/null
  ls_led_ok "$1" drwx------
}

make_work() {
  local base="${TMPDIR:-/tmp}"
  WORK="$(mktemp -d "${base%/}/gh-public-history-scan.XXXXXX")" || die "cannot create a private work dir"
  if ! /bin/chmod 700 "$WORK" || ! /bin/chmod -N "$WORK" 2>/dev/null || ! ls_led_ok "$WORK" drwx------; then
    die "cannot make the work dir $WORK private (chmod 700 and no ACL)"
  fi
  mkdir -p "$WORK/home" "$WORK/tmp" "$WORK/template" "$WORK/cwd" "$WORK/cfg" || die "cannot populate $WORK"
  printf '[extend]\nuseDefault = true\n' >"$WORK/cfg/gitleaks.toml" || die "cannot write the gitleaks config"
  : >"$WORK/cfg/gitleaksignore" || die "cannot write the gitleaks ignore file"
}

# The group spawn helper (perl, argv: <fifo> <cmd...>): new process group,
# one readiness byte, then exec.
# shellcheck disable=SC2016 # perl code
GROUP_SPAWN='use Fcntl; my $f = shift @ARGV;
setpgrp(0, 0) or die "setpgrp: $!\n";
sysopen(my $w, $f, O_WRONLY | O_NONBLOCK) or die "readiness: $!\n";
(syswrite($w, "R", 1) // 0) == 1 or die "readiness: $!\n";
close($w) or die "readiness: $!\n";
exec { $ARGV[0] } @ARGV or die "exec $ARGV[0]: $!\n";'

group_watchdog() { # <pgid> <marker> <secs> <grace>
  local n=0
  while [[ $n -lt $3 ]]; do
    /bin/sleep 1
    n=$((n + 1))
  done
  : >"$2"
  kill -TERM -- "-$1" 2>/dev/null
  n=0
  while [[ $n -lt $4 ]]; do
    /bin/sleep 1
    n=$((n + 1))
  done
  kill -KILL -- "-$1" 2>/dev/null
}

start_watchdog() {
  begin_critical
  group_watchdog "$@" >/dev/null 2>&1 </dev/null &
  WD_PID=$!
  end_critical
}

# spawn_group <dir> <stdout> <stderr> <cmd...>: start cmd in a new process
# group, registered in CUR_PGID, readiness confirmed. 1 = not started (RG_ERR).
spawn_group() {
  local dir="$1" out="$2" err="$3" fifo pid byte="" end
  shift 3
  RG_ERR=""
  if [[ -n "$CUR_PGID" ]]; then
    RG_ERR="not started: process group $CUR_PGID is still registered"
    return 1
  fi
  RG_SEQ=$((RG_SEQ + 1))
  fifo="$WORK/ready.$RG_SEQ"
  if ! mkfifo -m 600 "$fifo" 2>/dev/null || ! { exec 8<>"$fifo"; } 2>/dev/null; then
    rm -f "$fifo" 2>/dev/null
    RG_ERR="not started: cannot create a readiness FIFO"
    return 1
  fi
  begin_critical
  (
    cd "$dir" || exit 126
    exec "$PERL" -e "$GROUP_SPAWN" "$fifo" "$@"
  ) >"$out" 2>"$err" </dev/null 8>&- &
  pid=$!
  CUR_PGID="$pid"
  end_critical
  end=$((SECONDS + READY_WAIT))
  while :; do
    byte=""
    IFS= read -r -n 1 -t 1 -u 8 byte
    [[ "$byte" == R || $SECONDS -ge $end ]] && break
  done
  exec 8>&-
  rm -f "$fifo"
  [[ "$byte" == R ]] && return 0
  kill -TERM "$pid" 2>/dev/null
  end=$((SECONDS + 1))
  while kill -0 "$pid" 2>/dev/null && [[ $SECONDS -le $end ]]; do
    sleep 0.1
  done
  kill -KILL "$pid" 2>/dev/null
  wait "$pid" 2>/dev/null
  RG_ERR="not started: no readiness from its process group within ${READY_WAIT}s"
  if reap_group "$pid" 0; then
    CUR_PGID=""
  else
    RG_ERR="$RG_ERR; process group $pid could not be confirmed empty"
  fi
  return 1
}

# run_group <dir> <stdout> <stderr> <cmd...>: cmd in its own process group
# under the watchdog; rc, or 124 on timeout; 1 + RG_ERR when it never
# started or its group could not be confirmed empty afterwards (then the
# group stays registered and the run is FATAL: nothing else starts, the work
# dir is kept).
run_group() {
  local dir="$1" out="$2" err="$3" pid rc marker
  shift 3
  marker="$WORK/timeout.$RG_SEQ.$RANDOM"
  if ! spawn_group "$dir" "$out" "$err" "$@"; then
    [[ -n "$CUR_PGID" ]] && set_fatal "$RG_ERR"
    return 1
  fi
  pid="$CUR_PGID"
  start_watchdog "$pid" "$marker" "$TIMEOUT" "$GRACE"
  wait "$pid" 2>/dev/null
  rc=$?
  stop_watchdog
  if reap_group "$pid" 0; then
    CUR_PGID=""
  else
    RG_ERR="process group $pid could not be confirmed empty after TERM and KILL"
    set_fatal "$RG_ERR"
    return 1
  fi
  if [[ -e "$marker" ]]; then
    rm -f "$marker"
    return 124
  fi
  return "$rc"
}

set_fatal() {
  FATAL=1
  [[ -n "$FATAL_MSG" ]] || FATAL_MSG="$1"
}

# --- isolation ---------------------------------------------------------------------

# ISO: the only environment git and gitleaks ever see (env -i + allowlist).
# GIT: git with no credential helper and no askpass.
ISO=()
GIT=()
setup_iso() {
  ISO=(/usr/bin/env -i "PATH=$PATH" "HOME=$WORK/home" LANG=C LC_ALL=C "TMPDIR=$WORK/tmp/"
    GIT_CONFIG_NOSYSTEM=1 GIT_CONFIG_GLOBAL=/dev/null GIT_TERMINAL_PROMPT=0
    "GIT_ALLOW_PROTOCOL=$CLONE_PROTO" GIT_OPTIONAL_LOCKS=0)
  GIT=("${ISO[@]}" "$GIT_BIN" -c credential.helper= -c core.askPass= -c core.fsmonitor=false)
}

check_gitleaks_version() {
  local v
  v="$("${ISO[@]}" "$GITLEAKS_BIN" version 2>/dev/null </dev/null)"
  v="${v#v}"
  v="$(printf '%s' "$v" | tr -d '[:space:]')"
  [[ "$v" == "$GITLEAKS_PIN" ]] ||
    die_missing_dep "gitleaks ${v:-unknown} at $GITLEAKS_BIN; this scan requires exactly $GITLEAKS_PIN"
}

# --- inventory ---------------------------------------------------------------------

INV_COMPLETE=1
INV_PAGINATION=ok
INV_GET_FAILED=0
INV_STARTED=""

# sanitize <text>: one printable line, at most 160 chars (for detail fields).
sanitize() { printf '%s' "$1" | LC_ALL=C tr -c '[:print:]' ' ' | cut -c1-160; }

in_scope() { [[ ! -s "$WORK/scope" ]] || grep -qxF -- "$1" "$WORK/scope"; }

# load_scope: $WORK/scope = the limited names (empty file = all).
load_scope() {
  local n line
  : >"$WORK/scope"
  if [[ -n "$ONLY" ]]; then
    printf '%s\n' "$ONLY" | tr ',' '\n' >"$WORK/scope.raw"
  elif [[ -n "$REPOS_FILE" ]]; then
    [[ -f "$REPOS_FILE" && -r "$REPOS_FILE" ]] || die_usage "cannot read --repos file $REPOS_FILE"
    cat "$REPOS_FILE" >"$WORK/scope.raw"
  elif [[ -n "$RESUME" && -f "$RESUME/scope.txt" ]]; then
    cat "$RESUME/scope.txt" >"$WORK/scope.raw"
  else
    return 0
  fi
  while IFS= read -r line || [[ -n "$line" ]]; do
    line="${line%%#*}"
    n="$(printf '%s' "$line" | tr -d '[:space:]')"
    [[ -n "$n" ]] || continue
    valid_name "$n" || die_usage "invalid repo name in scope: $(sanitize "$n")"
    printf '%s\n' "$n"
  done <"$WORK/scope.raw" | LC_ALL=C sort -u >"$WORK/scope"
  [[ -s "$WORK/scope" ]] || die_usage "the repo scope is empty"
}

# JQ_SS: secret_scanning state of a per-repo GET body, distinguishing a
# missing key from a null one; id-mismatch when the body is another repo.
# shellcheck disable=SC2016 # jq program
JQ_SS='if .id != $id then "id-mismatch\t-"
else
  (if has("security_and_analysis") | not then "missing"
   elif .security_and_analysis == null then "null"
   elif (.security_and_analysis | has("secret_scanning")) | not then "missing"
   elif .security_and_analysis.secret_scanning == null then "null"
   elif (.security_and_analysis.secret_scanning | has("status")) | not then "missing"
   elif .security_and_analysis.secret_scanning.status == null then "null"
   else (.security_and_analysis.secret_scanning.status | tostring) end)
  + "\t" + (.visibility // (if .private == false then "public" elif .private == true then "private" else "unknown" end))
end'

# inventory: $WORK/inv.tsv rows: name, id, visibility, fork, ss, selection, detail.
inventory() {
  local pages="$WORK/pages.json" list="$WORK/list.tsv" inv="$WORK/inv.tsv" rc
  local name id vis fork ss sel detail body out gvis
  INV_STARTED="$(/bin/date -u +%Y-%m-%dT%H:%M:%SZ)"
  : >"$inv"
  "$GH" api --paginate 'user/repos?affiliation=owner&per_page=100' >"$pages" 2>"$WORK/gh.err" </dev/null
  rc=$?
  if [[ "$rc" -ne 0 ]]; then
    INV_PAGINATION=failed
    INV_COMPLETE=0
    warn "repo list pagination failed (gh rc $rc): $(sanitize "$(head -n1 "$WORK/gh.err")")"
  fi
  # shellcheck disable=SC2016 # jq program
  if ! jq -r -s --arg o "$OWNER" '
      if all(.[]; type == "array") then (add // []) else error("a page is not an array") end
      | map(select(.owner.login == $o)) | unique_by(.id) | sort_by(.name)
      | .[] | [.name, (.id | tostring),
               (.visibility // (if .private == false then "public" elif .private == true then "private" else "unknown" end)),
               (if .fork == true then "true" else "false" end)] | @tsv' "$pages" >"$list" 2>/dev/null; then
    INV_PAGINATION=failed
    INV_COMPLETE=0
    : >"$list"
    warn "repo list response is not valid paginated JSON"
  fi
  # Requested names absent from the list.
  if [[ -s "$WORK/scope" ]]; then
    while IFS= read -r name; do
      if ! cut -f1 "$list" | grep -qxF -- "$name"; then
        printf '%s\t-\t-\t-\tnot-listed\terror\tnot in the owned-repo inventory\n' "$name" >>"$inv"
      fi
    done <"$WORK/scope"
  fi
  while IFS=$'\t' read -r name id vis fork; do
    in_scope "$name" || continue
    if ! valid_name "$name" || [[ ! "$id" =~ ^[0-9]+$ ]]; then
      printf '%s\t%s\t%s\t%s\t-\terror\tunexpected repo name or id\n' "$(sanitize "$name")" "$(sanitize "$id")" "$vis" "$fork" >>"$inv"
      continue
    fi
    if [[ "$vis" != public ]]; then
      printf '%s\t%s\t%s\t%s\t-\tskipped-private\t\n' "$name" "$id" "$vis" "$fork" >>"$inv"
      continue
    fi
    body="$WORK/repo.json"
    "$GH" api "repos/$OWNER/$name" >"$body" 2>"$WORK/gh.err" </dev/null
    rc=$?
    if [[ "$rc" -ne 0 ]]; then
      INV_GET_FAILED=$((INV_GET_FAILED + 1))
      INV_COMPLETE=0
      detail="secret_scanning status unknown (request-failed: GET repos/$OWNER/$name rc $rc: $(sanitize "$(head -n1 "$WORK/gh.err")"))"
      printf '%s\t%s\t%s\t%s\trequest-failed\terror\t%s\n' "$name" "$id" "$vis" "$fork" "$detail" >>"$inv"
      continue
    fi
    if ! out="$(jq -r --argjson id "$id" "$JQ_SS" "$body" 2>/dev/null)" || [[ "$out" != *$'\t'* ]]; then
      INV_COMPLETE=0
      printf '%s\t%s\t%s\t%s\tunparseable\terror\tsecret_scanning status unknown (unparseable GET body)\n' "$name" "$id" "$vis" "$fork" >>"$inv"
      continue
    fi
    ss="${out%%$'\t'*}"
    gvis="${out#*$'\t'}"
    ss="$(sanitize "$ss")"
    if [[ "$ss" == id-mismatch ]]; then
      INV_COMPLETE=0
      printf '%s\t%s\t%s\t%s\tid-mismatch\terror\tGET returned a different repo id\n' "$name" "$id" "$vis" "$fork" >>"$inv"
      continue
    fi
    if [[ "$gvis" != public ]]; then
      printf '%s\t%s\t%s\t%s\t%s\tskipped-private\t\n' "$name" "$id" "$(sanitize "$gvis")" "$fork" "$ss" >>"$inv"
      continue
    fi
    case "$ss" in
      disabled) sel=target detail="" ;;
      enabled) sel=skipped-enabled detail="" ;;
      *) sel=error detail="secret_scanning status is $ss (unknown; never skipped)" ;;
    esac
    printf '%s\t%s\t%s\t%s\t%s\t%s\t%s\n' "$name" "$id" "$vis" "$fork" "$ss" "$sel" "$detail" >>"$inv"
  done <"$list"
}

# --- publication -------------------------------------------------------------------

SCAN_DIR=""
MANIFEST_HEADER=$'# repo\trepo_id\tfork\tstatus\tfindings\tref_sha256\tclone_s\thistory_s\tmerge_s\ttotal_s\tmerges\tdetail'
FINDINGS_HEADER=$'# repo\trepo_id\tpass\tcommit\tfile\trule\tline\tfingerprint'

test_hook() {
  [[ -n "$TEST_HOOK" ]] || return 0
  "$TEST_HOOK" "$@" </dev/null >/dev/null 2>&1 9>&-
}

# publish_file <src> <dest>: exclusive temp beside dest (noclobber), 600, no
# ACL, then rename(2) over dest (fails on a directory).
publish_file() {
  local src="$1" dest="$2" tmp
  tmp="$dest.tmp.$$.$RANDOM$RANDOM"
  (
    set -C
    cat "$src" >"$tmp"
  ) 2>/dev/null || return 1
  if ! /bin/chmod 600 "$tmp" 2>/dev/null || ! /bin/chmod -N "$tmp" 2>/dev/null ||
    ! "$PERL" -e 'rename($ARGV[0], $ARGV[1]) or exit 1' "$tmp" "$dest" 2>/dev/null; then
    rm -f "$tmp"
    return 1
  fi
}

# manifest_set <row...12 fields>: replace the repo's row (by name) and publish.
manifest_set() {
  local new="$WORK/manifest.new"
  {
    printf '%s\n' "$MANIFEST_HEADER"
    {
      awk -F'\t' -v n="$1" '!/^#/ && $1 != n' "$SCAN_DIR/manifest.tsv" || return 1
      local IFS=$'\t'
      printf '%s\n' "$*"
    } | LC_ALL=C sort -t $'\t' -k1,1
  } >"$new" || return 1
  publish_file "$new" "$SCAN_DIR/manifest.tsv"
}

# findings_count <repo>: published findings rows for the repo.
findings_count() { awk -F'\t' -v n="$1" '!/^#/ && $1 == n { c++ } END { print c + 0 }' "$SCAN_DIR/findings.tsv"; }

# publish_repo <name> <rows-file> <manifest fields...>: findings first, then
# the manifest row. 1 = publication failed (the run stops).
publish_repo() {
  local name="$1" rows="$2" new="$WORK/findings.new"
  shift 2
  test_hook publish-findings "$SCAN_DIR"
  if ! {
    printf '%s\n' "$FINDINGS_HEADER"
    awk -F'\t' -v n="$name" '!/^#/ && $1 != n' "$SCAN_DIR/findings.tsv" || exit 1
    cat "$rows" || exit 1
  } >"$new" 2>/dev/null || ! publish_file "$new" "$SCAN_DIR/findings.tsv"; then
    warn "$name: findings publication failed; the repo is not marked complete"
    return 1
  fi
  if ! manifest_set "$@"; then
    warn "$name: manifest publication failed; the repo is not marked complete"
    return 1
  fi
}

# --- scan-dir lock -------------------------------------------------------------------
#
# $SCAN_DIR/.lock is a FILE holding `pid=<pid>` and `started=<epoch>`. It is
# taken by link(2) of a fully written private temp file, so the owner is
# published atomically with the lock itself (a contender never sees an
# ownerless lock of a live run) and an existing lock is never replaced.
# Reclamation of a stale lock is serialized by an flock on
# $SCAN_DIR/.lock.reclaim (never deleted), and re-inspected under it.

LOCK_STALE_SECS=60 # an ownerless lock (hand-made, or a crash mid-write) is stale only after this
RECLAIM_WAIT=10
LK_STATE=""
LK_WHY=""

# lock_try: 0 = held; 3 = a lock exists; 4 = error (LOCK_ERR).
lock_try() {
  local tmp="$SCAN_DIR/.lock.tmp.$$.$RANDOM$RANDOM" rc
  if ! (
    set -C
    printf 'pid=%s\nstarted=%s\n' "$$" "$(/bin/date -u +%s)" >"$tmp"
  ) 2>/dev/null; then
    LOCK_ERR="cannot write a lock temp file in $SCAN_DIR"
    return 4
  fi
  "$PERL" -MErrno -e 'link($ARGV[0], $ARGV[1]) and exit 0; exit($!{EEXIST} ? 3 : 4)' "$tmp" "$LOCK_FILE"
  rc=$?
  rm -f "$tmp"
  case "$rc" in
    0) LOCK_HELD=1 ;;
    3) ;;
    *)
      LOCK_ERR="cannot create the lock $LOCK_FILE (link failed)"
      rc=4
      ;;
  esac
  return "$rc"
}

# lock_inspect: LK_STATE = absent | live | stale | fresh, LK_WHY. live = the
# owner pid parses and exists; stale = it parses and is dead, or there is no
# parseable owner and the lock is untouched for >= LOCK_STALE_SECS; fresh =
# no parseable owner yet, younger than that (never reclaimed).
lock_inspect() {
  local pid="" mt now
  LK_WHY=""
  if [[ ! -e "$LOCK_FILE" && ! -L "$LOCK_FILE" ]]; then
    LK_STATE=absent
    return
  fi
  if [[ -f "$LOCK_FILE" && ! -L "$LOCK_FILE" ]]; then
    pid="$(sed -n 's/^pid=//p' "$LOCK_FILE" 2>/dev/null | head -n1)"
  fi
  if [[ "$pid" =~ ^[1-9][0-9]*$ ]]; then
    if kill -0 "$pid" 2>/dev/null || ps -p "$pid" >/dev/null 2>&1; then
      LK_STATE=live
      LK_WHY="held by live pid $pid"
    else
      LK_STATE=stale
      LK_WHY="dead owner pid $pid"
    fi
    return
  fi
  mt="$(/usr/bin/stat -f %m "$LOCK_FILE" 2>/dev/null)"
  now="$(/bin/date +%s)"
  if [[ "$mt" =~ ^[0-9]+$ && $((now - mt)) -ge $LOCK_STALE_SECS ]]; then
    LK_STATE=stale
    LK_WHY="no parseable owner, untouched for $((now - mt))s"
  else
    LK_STATE=fresh
    LK_WHY="lock without a parseable owner, younger than ${LOCK_STALE_SECS}s"
  fi
}

# lock_reclaim: under the reclaim flock, re-inspect and remove the lock only
# if it is still stale, then try to take it. 0 held; 1 busy; 2 error.
lock_reclaim() {
  local rc
  if ! { exec 9>>"$SCAN_DIR/.lock.reclaim"; } 2>/dev/null; then
    LOCK_ERR="cannot open the reclaim mutex $SCAN_DIR/.lock.reclaim"
    return 2
  fi
  # shellcheck disable=SC2016 # perl code
  "$PERL" -e 'use Fcntl qw(:flock); use Errno; open(my $f, ">&=", 9) or exit 2; my $end = time + $ARGV[0]; until (flock($f, LOCK_EX | LOCK_NB)) { unless ($!{EWOULDBLOCK} || $!{EAGAIN}) { exit 4 } exit 3 if time >= $end; select(undef, undef, undef, 0.05) } exit 0' "$RECLAIM_WAIT" 2>/dev/null
  rc=$?
  if [[ "$rc" -ne 0 ]]; then
    exec 9>&-
    [[ "$rc" -eq 3 ]] && {
      LK_WHY="another run is reclaiming the lock"
      return 1
    }
    LOCK_ERR="reclaim mutex flock failed (helper exit $rc)"
    return 2
  fi
  test_hook reclaim-locked "$SCAN_DIR"
  lock_inspect
  case "$LK_STATE" in
    stale)
      test_hook reclaim-decided "$SCAN_DIR"
      if [[ -d "$LOCK_FILE" && ! -L "$LOCK_FILE" ]]; then
        rm -f "$LOCK_FILE/pid" 2>/dev/null
        rmdir "$LOCK_FILE" 2>/dev/null
      else
        rm -f "$LOCK_FILE" 2>/dev/null
      fi
      if [[ -e "$LOCK_FILE" || -L "$LOCK_FILE" ]]; then
        exec 9>&-
        LOCK_ERR="cannot remove the stale lock $LOCK_FILE ($LK_WHY); inspect and remove it by hand"
        return 2
      fi
      ;;
    absent) ;;
    *)
      exec 9>&-
      return 1
      ;;
  esac
  exec 9>&-
  lock_try
  case $? in
    0) return 0 ;;
    3)
      LK_WHY="a concurrent run took the lock first"
      return 1
      ;;
    *) return 2 ;;
  esac
}

# acquire_lock: 0 held; 1 busy (LK_WHY); 2 error (LOCK_ERR).
acquire_lock() {
  lock_try
  case $? in
    0) return 0 ;;
    3) ;;
    *) return 2 ;;
  esac
  lock_inspect
  case "$LK_STATE" in
    absent)
      lock_try
      case $? in
        0) return 0 ;;
        3)
          LK_WHY="a concurrent run took the lock first"
          return 1
          ;;
        *) return 2 ;;
      esac
      ;;
    stale) lock_reclaim ;;
    *) return 1 ;;
  esac
}

# release_lock: remove the lock only if this run holds it and it still names us.
release_lock() {
  [[ "$LOCK_HELD" -eq 1 && -n "$LOCK_FILE" ]] || return 0
  if [[ -f "$LOCK_FILE" && "$(sed -n 's/^pid=//p' "$LOCK_FILE" 2>/dev/null | head -n1)" == "$$" ]]; then
    rm -f "$LOCK_FILE"
  fi
  LOCK_HELD=0
}

die_busy() {
  printf '%bBusy:%b %s\n' "$RED" "$NC" "$*" >&2
  exit 75
}

# --- gitleaks ----------------------------------------------------------------------

# shellcheck disable=SC2016 # jq programs
JQ_GIT='if type != "array" then error("not an array") else .[] end
  | if (.RuleID | type) == "string" and (.File | type) == "string" and (.StartLine | type) == "number"
       and (.Commit | type) == "string" and (.Fingerprint | type) == "string"
    then [.Commit, .File, .RuleID, (.StartLine | tostring), .Fingerprint] | @tsv
    else error("finding lacks required fields") end'
# shellcheck disable=SC2016 # jq program
JQ_DIR='if type != "array" then error("not an array") else .[] end
  | if (.RuleID | type) == "string" and (.File | type) == "string" and (.StartLine | type) == "number"
       and (.File | startswith($p))
    then (.File[($p | length):]) as $f | (.StartLine | tostring) as $l
      | [$c, $f, .RuleID, $l, ($c + ":" + $f + ":" + .RuleID + ":" + $l)] | @tsv
    else error("finding lacks required fields or lies outside the scan tree") end'

STEP_STATUS=""
STEP_DETAIL=""
step_fail() { # <error|timeout> <detail>
  STEP_STATUS="$1"
  STEP_DETAIL="$2"
  return 1
}

# gl_run <git|dir> <target> <rows-out> [<commit> <prefix>]: run gitleaks and
# validate: no ERR/FTL diagnostic, exit 0/10, a JSON array of findings with
# the required fields, exit/count consistency. rows-out gets
# commit, file, rule, line, fingerprint (TSV, escaped).
gl_run() {
  local mode="$1" target="$2" rows="$3" commit="${4-}" prefix="${5-}"
  local report="$WORK/gl.json" out="$WORK/gl.out" err="$WORK/gl.err" clean="$WORK/gl.err.plain" rc grc n
  rm -f "$report" "$out" "$err" "$clean" "$rows"
  run_group "$WORK/cwd" "$out" "$err" "${ISO[@]}" "$GITLEAKS_BIN" "$mode" "$target" \
    --config "$WORK/cfg/gitleaks.toml" --gitleaks-ignore-path "$WORK/cfg/gitleaksignore" \
    --ignore-gitleaks-allow --redact=100 --no-banner --no-color --exit-code=10 \
    --report-format=json --report-path "$report"
  rc=$?
  # Raw scanner output may contain secret material: never printed.
  rm -f "$out"
  if [[ -n "$RG_ERR" ]]; then
    rm -f "$err" "$report"
    step_fail error "gitleaks $mode: $RG_ERR"
    return 1
  fi
  if [[ "$rc" -eq 124 ]]; then
    rm -f "$err" "$report"
    step_fail timeout "gitleaks $mode timed out after ${TIMEOUT}s"
    return 1
  fi
  if [[ ! -f "$err" || ! -r "$err" ]] || ! LC_ALL=C sed $'s/\033\\[[0-9;]*m//g' "$err" >"$clean" 2>/dev/null; then
    rm -f "$err" "$clean" "$report"
    step_fail error "gitleaks $mode diagnostic log unreadable (exit $rc)"
    return 1
  fi
  LC_ALL=C grep -Eq '^[^ ]+ (ERR|FTL)( |$)' "$clean"
  grc=$?
  rm -f "$err" "$clean"
  if [[ "$grc" -ne 1 ]]; then
    rm -f "$report"
    if [[ "$grc" -eq 0 ]]; then
      step_fail error "gitleaks $mode reported an ERR diagnostic (exit $rc)"
    else
      step_fail error "gitleaks $mode diagnostic log unreadable (exit $rc)"
    fi
    return 1
  fi
  if [[ "$rc" -ne 0 && "$rc" -ne 10 ]]; then
    rm -f "$report"
    step_fail error "gitleaks $mode exited $rc"
    return 1
  fi
  if [[ ! -f "$report" || ! -r "$report" ]]; then
    step_fail error "gitleaks $mode exited $rc without a JSON report"
    return 1
  fi
  # Exactly one JSON document, and it is an array: an empty file or several
  # documents (jq would read each in turn) are never a clean result.
  if [[ "$(jq -s 'length == 1 and (.[0] | type == "array")' "$report" 2>/dev/null)" != true ]]; then
    rm -f "$report"
    step_fail error "malformed gitleaks $mode JSON report: not exactly one JSON array (exit $rc)"
    return 1
  fi
  if [[ "$mode" == git ]]; then
    jq -r "$JQ_GIT" "$report" >"$rows" 2>/dev/null
  else
    jq -r --arg c "$commit" --arg p "$prefix" "$JQ_DIR" "$report" >"$rows" 2>/dev/null
  fi
  grc=$?
  rm -f "$report"
  if [[ "$grc" -ne 0 ]]; then
    rm -f "$rows"
    step_fail error "malformed gitleaks $mode JSON report (exit $rc)"
    return 1
  fi
  n="$(grep -c . "$rows")"
  if [[ "$rc" -eq 0 && "$n" -ne 0 ]] || [[ "$rc" -eq 10 && "$n" -eq 0 ]]; then
    rm -f "$rows"
    step_fail error "inconsistent gitleaks $mode result (exit $rc, $n findings in the report)"
    return 1
  fi
  return 0
}

# git_cap <out> <what> <git args...>: run git (isolated, in the mirror) in a
# process group; on failure STEP_* is set.
git_cap() {
  local out="$1" what="$2" rc
  shift 2
  run_group "$WORK/cwd" "$out" "$WORK/git.err" "${GIT[@]}" --git-dir="$MIRROR" "$@"
  rc=$?
  rm -f "$WORK/git.err"
  if [[ -n "$RG_ERR" ]]; then
    step_fail error "$what: $RG_ERR"
  elif [[ "$rc" -eq 124 ]]; then
    step_fail timeout "$what timed out after ${TIMEOUT}s"
  elif [[ "$rc" -ne 0 ]]; then
    step_fail error "$what failed (git rc $rc)"
  else
    return 0
  fi
}

# MERGE_JOIN (perl, argv: <paths.z> <tree.z>): join the merge's --cc path
# set with its full `ls-tree -r -z`. Prints NUL-separated triples
# kind, sha, path; kind = blob | absent | symlink | gitlink | badpath |
# badmode-<mode> | collide (case-insensitive clash with another exported
# path or one of its parent dirs). Exit != 0 = malformed input.
# shellcheck disable=SC2016 # perl code
MERGE_JOIN='use strict; use warnings;
my ($pf, $tf) = @ARGV; local $/;
open(my $p, "<", $pf) or die "paths: $!\n"; my $pd = <$p> // ""; close $p;
open(my $t, "<", $tf) or die "tree: $!\n"; my $td = <$t> // ""; close $t;
die "paths: no trailing NUL\n" if length($pd) && substr($pd, -1) ne "\0";
die "tree: no trailing NUL\n" if length($td) && substr($td, -1) ne "\0";
my @paths = split /\0/, $pd;
my %ent;
for my $r (split /\0/, $td) {
  $r =~ /\A([0-7]{6}) ([a-z]+) ([0-9a-f]{40,64})\t(.+)\z/s or die "tree: malformed entry\n";
  die "tree: duplicate entry\n" if exists $ent{$4};
  $ent{$4} = [$1, $2, $3];
}
my %seen;
for (@paths) { die "paths: empty entry\n" if $_ eq ""; die "paths: duplicate entry\n" if $seen{$_}++; }
my (@out, %lc);
for my $path (@paths) {
  my ($kind, $sha) = ("", "-");
  if ($path =~ m{\A/} || grep { $_ eq "" || $_ eq "." || $_ eq ".." } split(m{/}, $path, -1)) { $kind = "badpath" }
  elsif (!exists $ent{$path}) { $kind = "absent" }
  else {
    my ($mode, $type, $s) = @{$ent{$path}};
    if ($mode eq "120000") { $kind = "symlink" }
    elsif ($mode eq "160000") { $kind = "gitlink" }
    elsif (($mode eq "100644" || $mode eq "100755") && $type eq "blob") { $kind = "blob"; $sha = $s }
    else { $kind = "badmode-$mode" }
  }
  if ($kind eq "blob") {
    my @c = split m{/}, $path; my $acc = "";
    for my $i (0 .. $#c) {
      $acc = $i ? "$acc/$c[$i]" : $c[$i];
      my $k = lc $acc;
      if (exists $lc{$k} && $lc{$k} ne $acc) { $kind = "collide"; last }
      $lc{$k} = $acc;
    }
  }
  push @out, "$kind\0$sha\0$path\0";
}
print @out;'

# --- per repo ----------------------------------------------------------------------

MIRROR=""
R_SKIPS=""

# merge_pass <rdir> <rows-out>: the merge overscan. Sets MERGES and R_SKIPS.
merge_pass() {
  local rdir="$1" rows="$2" mdir="$1/m" m kind sha path dest exported n_del=0 n_sym=0 n_git=0
  MERGES=0
  : >"$rows"
  git_cap "$rdir/merges" "git rev-list --merges" rev-list --all --merges || return 1
  while IFS= read -r m; do
    [[ "$m" =~ ^[0-9a-f]{40,64}$ ]] || {
      step_fail error "git rev-list --merges printed an unexpected line"
      return 1
    }
    MERGES=$((MERGES + 1))
    rm -rf "$mdir"
    mkdir -p "$mdir/tree/repo" || {
      step_fail error "cannot create the merge scan dir"
      return 1
    }
    git_cap "$mdir/paths.z" "git diff-tree --cc $m" diff-tree --cc --name-only -z --no-renames --no-commit-id "$m" || return 1
    if [[ ! -s "$mdir/paths.z" ]]; then
      rm -rf "$mdir"
      continue
    fi
    git_cap "$mdir/tree.z" "git ls-tree $m" ls-tree -r -z --full-tree "$m" || return 1
    if ! "$PERL" -e "$MERGE_JOIN" "$mdir/paths.z" "$mdir/tree.z" >"$mdir/join.z" 2>/dev/null; then
      step_fail error "merge $m: unexpected diff-tree / ls-tree output"
      return 1
    fi
    exported=0
    while IFS= read -r -d '' kind && IFS= read -r -d '' sha && IFS= read -r -d '' path; do
      case "$kind" in
        absent) n_del=$((n_del + 1)) ;;
        symlink) n_sym=$((n_sym + 1)) ;;
        gitlink) n_git=$((n_git + 1)) ;;
        blob)
          dest="$mdir/tree/repo/$path"
          if [[ -e "$dest" || -L "$dest" ]]; then
            step_fail error "merge $m: path collision while exporting (case-insensitive file system)"
            return 1
          fi
          if [[ "$path" == */* ]] && ! mkdir -p "$mdir/tree/repo/${path%/*}" 2>/dev/null; then
            step_fail error "merge $m: cannot create a parent dir for an exported path"
            return 1
          fi
          git_cap "$dest" "git cat-file $sha" cat-file blob "$sha" || return 1
          exported=$((exported + 1))
          ;;
        collide)
          step_fail error "merge $m: case-colliding paths (would overwrite on a case-insensitive file system)"
          return 1
          ;;
        badpath)
          step_fail error "merge $m: absolute or dot-dot path"
          return 1
          ;;
        *)
          step_fail error "merge $m: unexpected tree entry ($kind)"
          return 1
          ;;
      esac
    done <"$mdir/join.z"
    if [[ "$exported" -gt 0 ]]; then
      gl_run dir "$mdir/tree" "$mdir/rows" "$m" "$mdir/tree/repo/" || return 1
      awk -F'\t' -v OFS='\t' '{ print "merge-touched-file", $0 }' "$mdir/rows" >>"$rows"
    fi
    rm -rf "$mdir"
  done <"$rdir/merges"
  R_SKIPS="deleted=$n_del symlink=$n_sym gitlink=$n_git"
  return 0
}

# scan_repo <name> <id> <fork>: clone, history pass, merge pass, publish.
# 1 = publication failed or the run became FATAL.
scan_repo() {
  local name="$1" id="$2" fork="$3" rdir t0 t1 tc=0 th=0 tm=0 status="" detail="" ref="-" n=0 rc
  local rows hist mrows
  rdir="$WORK/r-$id"
  MIRROR="$rdir/mirror.git"
  rows="$rdir/rows.tsv"
  hist="$rdir/hist.tsv"
  mrows="$rdir/merge.tsv"
  MERGES=0
  R_SKIPS=""
  STEP_STATUS=""
  STEP_DETAIL=""
  rm -rf "$rdir"
  mkdir -p "$rdir" || return 1
  : >"$rows"
  t0=$SECONDS
  run_group "$WORK/cwd" "$rdir/clone.out" "$rdir/clone.err" "${GIT[@]}" clone --mirror --quiet \
    --template="$WORK/template" -- "$CLONE_BASE/$OWNER/$name.git" "$MIRROR"
  rc=$?
  tc=$((SECONDS - t0))
  if [[ -n "$RG_ERR" ]]; then
    status=error detail="clone: $RG_ERR"
  elif [[ "$rc" -eq 124 ]]; then
    status=timeout detail="clone timed out after ${TIMEOUT}s"
  elif [[ "$rc" -ne 0 ]]; then
    status=error detail="clone failed (git rc $rc)"
  fi
  if [[ -z "$status" ]]; then
    if git_cap "$rdir/refs" "git for-each-ref" for-each-ref --format='%(objectname) %(objecttype) %(refname)'; then
      ref="$(shasum -a 256 <"$rdir/refs" | awk '{ print $1 }')"
      if git_cap "$rdir/head" "git rev-list" rev-list --all --max-count=1; then
        [[ -s "$rdir/head" ]] || status=empty
      else
        status="$STEP_STATUS" detail="$STEP_DETAIL"
      fi
    else
      status="$STEP_STATUS" detail="$STEP_DETAIL"
    fi
  fi
  if [[ -z "$status" ]]; then
    t1=$SECONDS
    if gl_run git "$MIRROR" "$hist"; then
      awk -F'\t' -v OFS='\t' '{ print "history", $0 }' "$hist" >>"$rows"
    else
      status="$STEP_STATUS" detail="history pass: $STEP_DETAIL"
    fi
    th=$((SECONDS - t1))
  fi
  if [[ -z "$status" ]]; then
    t1=$SECONDS
    if merge_pass "$rdir" "$mrows"; then
      cat "$mrows" >>"$rows"
      detail="$R_SKIPS"
    else
      status="$STEP_STATUS" detail="merge pass: $STEP_DETAIL"
    fi
    tm=$((SECONDS - t1))
  fi
  if [[ -z "$status" ]]; then
    n="$(grep -c . "$rows")"
    if [[ "$n" -gt 0 ]]; then status=findings; else status=clean; fi
  fi
  if [[ "$status" != clean && "$status" != findings ]]; then
    : >"$rows"
    n=0
  fi
  # Prefix repo identity onto the rows.
  awk -F'\t' -v OFS='\t' -v n="$name" -v i="$id" '{ print n, i, $0 }' "$rows" >"$rdir/final.tsv"
  detail="$(sanitize "$detail")"
  if [[ "$FATAL" -eq 1 ]]; then
    status=error
    detail="$(sanitize "$FATAL_MSG")"
    : >"$rdir/final.tsv"
    n=0
  fi
  if ! publish_repo "$name" "$rdir/final.tsv" "$name" "$id" "$fork" "$status" "$n" "$ref" \
    "$tc" "$th" "$tm" "$((SECONDS - t0))" "$MERGES" "$detail"; then
    PUBLISH_FAILED=1
    return 1
  fi
  REPORT_LINE="$status ($n findings) clone ${tc}s history ${th}s merges $MERGES (${tm}s) total $((SECONDS - t0))s${detail:+ - $detail}"
  [[ "$FATAL" -eq 1 ]] && return 1
  # Published; only now is the mirror removed (never with a live group).
  [[ -z "$CUR_PGID" ]] && rm -rf "$rdir"
  return 0
}

# --- main --------------------------------------------------------------------------

# open_log: with --log, send stdout and stderr to a private (600, no ACL)
# log file: created under umask 077 without following a symlink, then
# verified before anything is written to it.
open_log() {
  [[ -n "$LOG_PATH" ]] || return 0
  [[ -L "$LOG_PATH" ]] && die_usage "--log: $LOG_PATH is a symlink"
  [[ ! -e "$LOG_PATH" || -f "$LOG_PATH" ]] || die_usage "--log: $LOG_PATH is not a regular file"
  "$PERL" -MFcntl -e 'sysopen(my $f, $ARGV[0], O_WRONLY | O_APPEND | O_CREAT | O_NOFOLLOW, 0600) or exit 1' "$LOG_PATH" 2>/dev/null ||
    die "--log: cannot create $LOG_PATH"
  if [[ -L "$LOG_PATH" ]] || ! /bin/chmod 600 "$LOG_PATH" 2>/dev/null || ! /bin/chmod -N "$LOG_PATH" 2>/dev/null ||
    ! ls_led_ok "$LOG_PATH" -rw-------; then
    die "--log: cannot make $LOG_PATH private (600, no ACL)"
  fi
  exec >>"$LOG_PATH" 2>&1
}

require_cmd jq
require_cmd git
require_cmd gitleaks "Install gitleaks $GITLEAKS_PIN."
require_cmd shasum
[[ -x "$PERL" ]] || die_missing_dep "perl not found at $PERL"
command -v "$GH" >/dev/null 2>&1 || die_missing_dep "'$GH' (gh CLI) is required but not found."
GIT_BIN="$(command -v git)"
GITLEAKS_BIN="$(command -v gitleaks)"
[[ "$GIT_BIN" == /* && "$GITLEAKS_BIN" == /* ]] || die_missing_dep "git and gitleaks must be executables on PATH"
if [[ -n "$RESUME" ]]; then
  [[ -d "$RESUME" && -f "$RESUME/manifest.tsv" && -f "$RESUME/findings.tsv" ]] ||
    die_usage "--resume: $RESUME is not a scan dir (manifest.tsv and findings.tsv required)"
  RESUME="$(cd "$RESUME" && pwd)" || die_usage "--resume: cannot enter $RESUME"
fi

open_log
make_work
setup_iso
test_hook work-ready "$WORK"
check_gitleaks_version
if [[ -z "$OWNER" ]]; then
  OWNER="$("$GH" api user --jq .login 2>/dev/null </dev/null)" || die_unauthed "gh api user failed (run: gh auth login)"
fi
valid_name "$OWNER" || die_usage "invalid owner: $(sanitize "$OWNER")"
load_scope
inventory

if [[ "$DRY_RUN" -eq 1 ]]; then
  awk -F'\t' -v OFS='\t' '{ printf "%-16s %-40s id=%s fork=%s secret_scanning=%s %s\n", $6, $1, $2, $4, $5, $7 }' "$WORK/inv.tsv"
  printf 'Inventory: %s (pagination %s, GET failures %d)\n' \
    "$([[ "$INV_COMPLETE" -eq 1 ]] && echo complete || echo INCOMPLETE)" "$INV_PAGINATION" "$INV_GET_FAILED"
  printf 'Targets: %d, inventory errors: %d\n' \
    "$(awk -F'\t' '$6 == "target"' "$WORK/inv.tsv" | grep -c .)" "$(awk -F'\t' '$6 == "error"' "$WORK/inv.tsv" | grep -c .)"
  [[ "$INV_COMPLETE" -eq 1 && -z "$(awk -F'\t' '$6 == "error"' "$WORK/inv.tsv")" ]] && exit 0
  exit 1
fi

# Scan dir (new or resumed) and its lock.
private_dir "$STATE_ROOT" || die "cannot make $STATE_ROOT private (700, no ACL)"
if [[ -n "$RESUME" ]]; then
  SCAN_DIR="$RESUME"
else
  SCAN_DIR="$STATE_ROOT/scan-$(/bin/date -u +%Y%m%dT%H%M%SZ)"
  mkdir "$SCAN_DIR" 2>/dev/null || SCAN_DIR="$SCAN_DIR-$$"
  [[ -d "$SCAN_DIR" ]] || mkdir "$SCAN_DIR" || die "cannot create $SCAN_DIR"
fi
private_dir "$SCAN_DIR" || die "cannot make $SCAN_DIR private (700, no ACL)"
LOCK_FILE="$SCAN_DIR/.lock"
acquire_lock
case $? in
  0) ;;
  1) die_busy "$SCAN_DIR is in use ($LK_WHY); not started" ;;
  *) die "$LOCK_ERR" ;;
esac
test_hook locked "$SCAN_DIR"

PUBLISH_FAILED=0
# Inventory files.
{
  printf '# repo\trepo_id\tvisibility\tfork\tsecret_scanning\tselection\n'
  cut -f1-6 "$WORK/inv.tsv"
} >"$WORK/inv.pub"
{
  printf 'owner=%s\n' "$OWNER"
  printf 'inventory_utc=%s\n' "$INV_STARTED"
  printf 'complete=%s\n' "$([[ "$INV_COMPLETE" -eq 1 ]] && echo true || echo false)"
  printf 'pagination=%s\n' "$INV_PAGINATION"
  printf 'get_failed=%d\n' "$INV_GET_FAILED"
  printf 'scope=%s\n' "$([[ -s "$WORK/scope" ]] && echo limited || echo all)"
  printf 'gitleaks=%s\n' "$GITLEAKS_PIN"
  [[ -n "$RESUME" ]] && printf 'resumed=true\n'
} >"$WORK/meta.pub"
publish_file "$WORK/inv.pub" "$SCAN_DIR/inventory.tsv" &&
  publish_file "$WORK/meta.pub" "$SCAN_DIR/inventory.meta" || die "cannot publish the inventory in $SCAN_DIR"
if [[ -s "$WORK/scope" && -z "$RESUME" ]]; then
  publish_file "$WORK/scope" "$SCAN_DIR/scope.txt" || die "cannot publish the scope in $SCAN_DIR"
fi
if [[ ! -f "$SCAN_DIR/findings.tsv" ]]; then
  printf '%s\n' "$FINDINGS_HEADER" >"$WORK/f0"
  publish_file "$WORK/f0" "$SCAN_DIR/findings.tsv" || die "cannot publish findings.tsv in $SCAN_DIR"
fi
[[ -f "$SCAN_DIR/manifest.tsv" ]] || : >"$SCAN_DIR/manifest.tsv"

# Initial manifest: inventory errors are error rows; every target that is
# not settled (resume) is not-attempted.
: >"$WORK/todo"
while IFS=$'\t' read -r name id vis fork ss sel detail; do
  case "$sel" in
    error)
      manifest_set "$name" "$id" "$fork" error 0 - 0 0 0 0 0 "$(sanitize "inventory: $detail")" ||
        die "cannot publish manifest.tsv in $SCAN_DIR"
      ;;
    target)
      if [[ -n "$RESUME" ]]; then
        old="$(awk -F'\t' -v n="$name" '!/^#/ && $1 == n' "$SCAN_DIR/manifest.tsv")"
        ostatus="$(printf '%s' "$old" | cut -f4)"
        if [[ -n "$old" && "$(printf '%s' "$old" | cut -f2)" == "$id" ]] &&
          [[ "$ostatus" == clean || "$ostatus" == findings || "$ostatus" == empty ]] &&
          [[ "$(printf '%s' "$old" | cut -f5)" == "$(findings_count "$name")" ]]; then
          continue
        fi
      fi
      manifest_set "$name" "$id" "$fork" not-attempted 0 - 0 0 0 0 0 "" ||
        die "cannot publish manifest.tsv in $SCAN_DIR"
      printf '%s\t%s\t%s\n' "$name" "$id" "$fork" >>"$WORK/todo"
      ;;
  esac
done <"$WORK/inv.tsv"

total="$(grep -c . "$WORK/todo")"
echo "gh-public-history-scan: owner $OWNER, $total repo(s) to scan, scan dir $SCAN_DIR"
i=0
while IFS=$'\t' read -r name id fork; do
  i=$((i + 1))
  REPORT_LINE=""
  if ! scan_repo "$name" "$id" "$fork"; then
    if [[ "$PUBLISH_FAILED" -eq 1 ]]; then
      warn "publication failed for $name; stopping (see $SCAN_DIR)"
      break
    fi
    printf '[%d/%d] %s: %s\n' "$i" "$total" "$name" "$REPORT_LINE"
    warn "stopping: $FATAL_MSG"
    break
  fi
  printf '[%d/%d] %s: %s\n' "$i" "$total" "$name" "$REPORT_LINE"
done <"$WORK/todo" 3<&-

# --- summary -----------------------------------------------------------------------

counts="$(awk -F'\t' '!/^#/ { c[$4]++ } END { for (s in c) printf "%s=%d ", s, c[s] }' "$SCAN_DIR/manifest.tsv")"
nfind="$(awk '!/^#/' "$SCAN_DIR/findings.tsv" 2>/dev/null | grep -c .)"
bad="$(awk -F'\t' '!/^#/ && ($4 == "error" || $4 == "timeout" || $4 == "not-attempted")' "$SCAN_DIR/manifest.tsv" | grep -c .)"
echo "Scan dir: $SCAN_DIR"
printf 'Inventory: %s (pagination %s, GET failures %d)\n' \
  "$([[ "$INV_COMPLETE" -eq 1 ]] && echo complete || echo INCOMPLETE)" "$INV_PAGINATION" "$INV_GET_FAILED"
echo "Status: ${counts:-none}"
echo "Findings: $nfind (metadata only; see findings.tsv)"
if [[ "$PUBLISH_FAILED" -eq 1 || "$FATAL" -eq 1 || "$bad" -gt 0 || "$INV_COMPLETE" -ne 1 ]]; then
  echo "complete: no (re-run with --resume \"$SCAN_DIR\")"
  [[ "$PUBLISH_FAILED" -eq 1 ]] && warn "publication failed; results are incomplete"
  exit 1
fi
echo "complete: yes"
[[ "$nfind" -gt 0 ]] && exit 10
exit 0
