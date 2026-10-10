#!/usr/bin/env bash
# gitleaks-audit.sh — daily gitleaks history audit of the git repos under
# ~/code, with change detection, a known-findings baseline, and a launchd
# agent (--install) that runs `--run` every day at 11:00.
#
# Default mode is a dry run: it lists the repos it would scan and why, runs
# no scans, and writes nothing to disk. Secrets never leave the private temp
# dir: gitleaks runs with --redact=100, its stdout/stderr go to private temp
# files that are never read, and the JSON report is reduced to RuleID, File,
# Commit, StartLine, Fingerprint and then deleted.
#
# Designed for launchd's minimal environment and macOS /bin/bash 3.2: builds
# its own PATH, never prompts, never uses `set -e`.

set -uo pipefail

SCRIPT_DIR="$(cd "$(dirname "${BASH_SOURCE[0]}")" && pwd)"
SCRIPT_PATH="$SCRIPT_DIR/$(basename "${BASH_SOURCE[0]}")"
# shellcheck source=../lib/common.sh
source "$SCRIPT_DIR/../lib/common.sh"

usage() {
  cat <<'EOF'
Usage: gitleaks-audit [--run | --full | --report | --install | --uninstall | --status] [--no-notify]

Daily gitleaks history audit of git repositories under ~/code.

Modes:
  (none)        Dry run: list every discovered repo with what a run would do
                and why (never scanned / HEAD moved / refs changed / gitleaks
                config changed / gitleaks version changed / weekly full scan
                due / unchanged / excluded / linked worktree). No scans, no
                state or log writes.
  --run         Scan repos whose inputs changed since their last complete
                scan (all repos when the last full pass is >= 7 days old).
  --full        Like --run, but scan every repo regardless of changes.
  --report      Print current findings (reduced fields only), grouped
                repo -> rule -> file:line (commit), plus rotation guidance.
  --install     Render the launchd template into
                ~/Library/LaunchAgents/com.skwid138.gitleaks-audit.plist and
                bootstrap it (runs --run daily at 11:00; not started now).
  --uninstall   Boot out the agent (absent = OK) and remove the plist.
  --status      Show whether the agent is loaded, the plist path, and the
                last run summary.
  -h, --help    Show this help.

Options:
  --no-notify   With --run/--full, skip the macOS notification.

What a scan runs (cwd = the repo; GITLEAKS_CONFIG/GITLEAKS_CONFIG_TOML unset,
so the effective config is the repo's .gitleaks.toml/.gitleaksignore or the
gitleaks default):
  gitleaks git --redact=100 --no-banner --exit-code=10 \
    --report-format=json --report-path=<private tmp> .
Each scan runs in its own process group under a watchdog; on timeout or
interruption the whole group gets TERM, then KILL.

Change detection: before each scan the script snapshots every ref
(`git for-each-ref`, including refs/stash), HEAD, the sha256 of the
worktree .gitleaks.toml and .gitleaksignore (or "absent"), and the gitleaks
version. The snapshot is persisted only after a complete scan (rc 0 or 10,
report parsed and reduced, state written) whose refs did not move mid-scan.

Discovery: directories named .git up to 3 levels below ~/code (node_modules
skipped). Linked worktrees are skipped (their history is scanned through the
main repo); submodules are scanned as their own repos.

Excludes: ~/.config/gitleaks-audit/config — one repo path per line, relative
to ~/code (# comments and blank lines ignored). Absent = no excludes. Present
but unreadable = error (nothing scanned).

Baseline: the first complete scan of a repo records its findings as known and
the notification says "N existing findings in M repos baselined — run
`gitleaks-audit.sh --report`". Afterwards only NEW fingerprints and errors
notify; clean or known-only runs are silent.

Files:
  State:  ~/Library/Application Support/gitleaks-audit (700; files 600)
  Log:    ~/Library/Logs/gitleaks-audit.log (rc and counts only; rotated
          to .1 above 1 MiB)
  Lock:   ~/Library/Caches/gitleaks-audit.lock

Requires: git, gitleaks, jq (macOS ships /usr/bin/jq), /usr/bin/perl, shasum.

Exit codes:
  0   clean, or only known findings
  10  new findings (and no errors)
  1   any error (scan error/timeout, malformed report, state or log write
      failure, discovery or config failure); new findings are still
      notified and recorded
  2   usage error
  75  another run holds the lock

Environment overrides (tests/advanced use):
  GITLEAKS_AUDIT_BASE_PATH   PATH to use instead of the built-in one
  GITLEAKS_AUDIT_TIMEOUT     per-scan watchdog seconds (default 1800)
  GITLEAKS_AUDIT_KILL_GRACE  seconds between TERM and KILL (default 5)
  GITLEAKS_AUDIT_NOW         epoch seconds to use as "now"
EOF
}

MODE="dry-run"
NOTIFY=1
while [[ $# -gt 0 ]]; do
  case "$1" in
    -h | --help)
      usage
      exit 0
      ;;
    --run | --full | --report | --install | --uninstall | --status)
      [[ "$MODE" == "dry-run" ]] || die_usage "only one mode may be given (see --help)"
      MODE="${1#--}"
      shift
      ;;
    --no-notify)
      NOTIFY=0
      shift
      ;;
    *) die_usage "unknown argument: $1 (see --help)" ;;
  esac
done

# --- environment -------------------------------------------------------------

[[ -n "${HOME:-}" && -d "$HOME" ]] || die "HOME is unset or not a directory"
umask 077

LABEL="com.skwid138.gitleaks-audit"
SYSTEM_PATH="/usr/bin:/bin:/usr/sbin:/sbin"
export PATH="${GITLEAKS_AUDIT_BASE_PATH:-/opt/homebrew/bin:/usr/local/bin:$SYSTEM_PATH}"
TIMEOUT="${GITLEAKS_AUDIT_TIMEOUT:-1800}"
GRACE="${GITLEAKS_AUDIT_KILL_GRACE:-5}"
[[ "$TIMEOUT" =~ ^[0-9]+$ && "$TIMEOUT" -gt 0 ]] || die_usage "GITLEAKS_AUDIT_TIMEOUT must be a positive integer"
[[ "$GRACE" =~ ^[0-9]+$ ]] || die_usage "GITLEAKS_AUDIT_KILL_GRACE must be a non-negative integer"

ROOT="$HOME/code"
MAX_DEPTH=3
CONFIG_FILE="$HOME/.config/gitleaks-audit/config"
STATE_DIR="$HOME/Library/Application Support/gitleaks-audit"
REPOS_DIR="$STATE_DIR/repos"
META_FILE="$STATE_DIR/meta"
LAST_RUN_FILE="$STATE_DIR/last-run"
LOG_FILE="$HOME/Library/Logs/gitleaks-audit.log"
LOG_MAX_BYTES=1048576
LOCK_DIR="$HOME/Library/Caches/gitleaks-audit.lock"
FULL_INTERVAL=$((7 * 86400))

# Deterministic inputs: no inherited repo selection or gitleaks config.
unset GIT_DIR GIT_WORK_TREE GIT_INDEX_FILE GIT_OBJECT_DIRECTORY \
  GIT_ALTERNATE_OBJECT_DIRECTORIES GIT_COMMON_DIR GIT_NAMESPACE \
  GITLEAKS_CONFIG GITLEAKS_CONFIG_TOML
export GIT_TERMINAL_PROMPT=0 GIT_OPTIONAL_LOCKS=0

if [[ "$(id -u)" == "0" ]]; then
  die "refusing to run as root; gitleaks-audit manages per-user state and a gui/<uid> LaunchAgent"
fi

if [[ -n "${GITLEAKS_AUDIT_NOW:-}" ]]; then
  NOW="$GITLEAKS_AUDIT_NOW"
else
  NOW="$(/bin/date -u +%s)"
fi

# --- work dir, cleanup, signals ----------------------------------------------

WORK=""
LOCK_HELD=0
CUR_PGID=""
WD_PID=""

# reap_group <pgid>: TERM the whole process group, give it GRACE seconds to
# empty, then KILL it. Returns immediately if the group no longer exists.
reap_group() {
  local pg="$1" i=0 limit
  [[ -n "$pg" ]] || return 0
  kill -TERM -- "-$pg" 2>/dev/null || return 0
  limit=$((GRACE * 10))
  while kill -0 -- "-$pg" 2>/dev/null; do
    if [[ $i -ge $limit ]]; then
      kill -KILL -- "-$pg" 2>/dev/null
      i=0
      while kill -0 -- "-$pg" 2>/dev/null && [[ $i -lt 30 ]]; do
        sleep 0.1
        i=$((i + 1))
      done
      return 0
    fi
    sleep 0.1
    i=$((i + 1))
  done
  return 0
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
  stop_watchdog
  if [[ -n "$CUR_PGID" ]]; then
    reap_group "$CUR_PGID"
    CUR_PGID=""
  fi
  if [[ "$LOCK_HELD" -eq 1 ]]; then
    local owner_pid=""
    owner_pid="$(sed -n 's/^pid=//p' "$LOCK_DIR/owner" 2>/dev/null)"
    if [[ "$owner_pid" == "$$" ]]; then
      rm -f "$LOCK_DIR/owner"
      rmdir "$LOCK_DIR" 2>/dev/null
    fi
    LOCK_HELD=0
  fi
  [[ -n "$WORK" && -d "$WORK" ]] && rm -rf "$WORK"
}
trap cleanup EXIT
trap 'exit 130' INT
trap 'exit 143' TERM

make_work() {
  local base="${TMPDIR:-/tmp}"
  WORK="$(mktemp -d "${base%/}/gitleaks-audit.XXXXXX")" || die "cannot create private work dir"
  chmod 700 "$WORK" || die "cannot chmod work dir"
}

# --- logging -----------------------------------------------------------------

LOG_OK=0
LOG_WRITE_FAILED=0
open_log() {
  mkdir -p "$(dirname "$LOG_FILE")" 2>/dev/null
  if [[ -f "$LOG_FILE" ]]; then
    local size
    size="$(/usr/bin/stat -f %z "$LOG_FILE" 2>/dev/null || echo 0)"
    if [[ "$size" =~ ^[0-9]+$ && "$size" -gt "$LOG_MAX_BYTES" ]]; then
      mv -f "$LOG_FILE" "$LOG_FILE.1" 2>/dev/null
    fi
  fi
  if { : >>"$LOG_FILE"; } 2>/dev/null && chmod 600 "$LOG_FILE" 2>/dev/null; then
    LOG_OK=1
  else
    LOG_OK=0
    LOG_WRITE_FAILED=1
    warn "cannot write log file $LOG_FILE"
  fi
}

# log: stdout, plus the log file once open_log has run (scan modes only).
log() {
  printf '%s\n' "$*"
  [[ "$LOG_OK" -eq 1 ]] || return 0
  if ! { printf '[%s] %s\n' "$(/bin/date '+%Y-%m-%dT%H:%M:%S%z')" "$*" >>"$LOG_FILE"; } 2>/dev/null; then
    LOG_OK=0
    LOG_WRITE_FAILED=1
    warn "log write failed ($LOG_FILE)"
  fi
}

# --- lock ----------------------------------------------------------------------

LOCK_BUSY_EXIT=75
THIS_HOST="$(/bin/hostname 2>/dev/null || echo unknown)"

write_lock_owner() {
  printf 'pid=%s\nhost=%s\nstarted=%s\n' "$$" "$THIS_HOST" "$(/bin/date -u +%s)" >"$LOCK_DIR/owner.tmp.$$" &&
    mv -f "$LOCK_DIR/owner.tmp.$$" "$LOCK_DIR/owner"
}

# acquire_lock: 0 = held; 1 = busy/ambiguous. Reclaims only a clearly stale
# lock (same host, numeric pid that is not running).
acquire_lock() {
  mkdir -p "$(dirname "$LOCK_DIR")" 2>/dev/null
  if mkdir "$LOCK_DIR" 2>/dev/null; then
    LOCK_HELD=1
    write_lock_owner || log "lock: acquired $LOCK_DIR but could not write owner metadata"
    return 0
  fi
  local pid="" host=""
  if [[ -f "$LOCK_DIR/owner" ]]; then
    pid="$(sed -n 's/^pid=//p' "$LOCK_DIR/owner" 2>/dev/null)"
    host="$(sed -n 's/^host=//p' "$LOCK_DIR/owner" 2>/dev/null)"
  fi
  if [[ -z "$pid" || ! "$pid" =~ ^[0-9]+$ || "$host" != "$THIS_HOST" ]]; then
    log "lock: $LOCK_DIR exists with ambiguous ownership (pid='${pid}' host='${host}'); skipping run"
    return 1
  fi
  if kill -0 "$pid" 2>/dev/null || ps -p "$pid" >/dev/null 2>&1; then
    log "lock: held by live pid $pid; skipping run"
    return 1
  fi
  log "lock: reclaiming stale lock from dead pid $pid"
  rm -f "$LOCK_DIR/owner"
  if ! rmdir "$LOCK_DIR" 2>/dev/null || ! mkdir "$LOCK_DIR" 2>/dev/null; then
    log "lock: could not reclaim $LOCK_DIR; skipping run"
    return 1
  fi
  LOCK_HELD=1
  write_lock_owner || log "lock: could not write owner metadata"
  return 0
}

# --- process-group runner ----------------------------------------------------

# run_group <dir> <stdout-file> <stderr-file> <cmd...>: run cmd with cwd=dir
# in a NEW process group (perl setpgrp + exec; bash 3.2 has no setsid and
# there is no TTY for job control) under a watchdog. Returns cmd's rc, or 124
# if the watchdog fired. Afterwards the whole group is reaped (TERM, then
# KILL), so descendants cannot outlive the scan even if the leader exited.
run_group() {
  local dir="$1" out="$2" err="$3" pid rc marker
  shift 3
  marker="$WORK/timeout.$RANDOM$RANDOM"
  (
    cd "$dir" || exit 126
    exec /usr/bin/perl -e 'setpgrp(0, 0) or die "setpgrp: $!\n"; exec { $ARGV[0] } @ARGV or die "exec $ARGV[0]: $!\n";' "$@"
  ) >"$out" 2>"$err" </dev/null &
  pid=$!
  CUR_PGID="$pid"
  (
    sp=""
    trap 'kill "$sp" 2>/dev/null; exit 0' TERM
    sleep "$TIMEOUT" &
    sp=$!
    wait "$sp"
    : >"$marker"
    kill -TERM -- "-$pid" 2>/dev/null
    sleep "$GRACE" &
    sp=$!
    wait "$sp"
    kill -KILL -- "-$pid" 2>/dev/null
  ) >/dev/null 2>&1 </dev/null &
  WD_PID=$!
  wait "$pid" 2>/dev/null
  rc=$?
  stop_watchdog
  reap_group "$pid"
  CUR_PGID=""
  if [[ -e "$marker" ]]; then
    rm -f "$marker"
    return 124
  fi
  return "$rc"
}

# --- helpers -------------------------------------------------------------------

sha256_file() { shasum -a 256 <"$1" 2>/dev/null | awk '{print $1}'; }
repo_id() { printf '%s' "$1" | shasum -a 256 | cut -c1-16; }

# --- excludes ------------------------------------------------------------------

EXCLUDES_FILE=""
CONFIG_ERR=""
# load_excludes: normalized excludes -> $WORK/excludes. 1 = config present
# but unreadable (fatal: never scan with a silently-dropped exclude list).
load_excludes() {
  EXCLUDES_FILE="$WORK/excludes"
  : >"$EXCLUDES_FILE" || return 1
  if [[ ! -e "$CONFIG_FILE" && ! -L "$CONFIG_FILE" ]]; then
    return 0
  fi
  if [[ ! -f "$CONFIG_FILE" || ! -r "$CONFIG_FILE" ]]; then
    CONFIG_ERR="exclude config $CONFIG_FILE exists but is not a readable regular file"
    return 1
  fi
  local line
  if ! cat "$CONFIG_FILE" >"$WORK/config.raw" 2>/dev/null; then
    CONFIG_ERR="exclude config $CONFIG_FILE could not be read"
    return 1
  fi
  while IFS= read -r line || [[ -n "$line" ]]; do
    line="${line%%#*}"
    line="$(printf '%s' "$line" | sed -e 's/^[[:space:]]*//' -e 's/[[:space:]]*$//')"
    [[ -n "$line" ]] || continue
    [[ "$line" == "$ROOT/"* ]] && line="${line#"$ROOT"/}"
    while [[ "$line" == ./* ]]; do line="${line#./}"; done
    while [[ "$line" == */ ]]; do line="${line%/}"; done
    [[ -n "$line" ]] && printf '%s\n' "$line" >>"$EXCLUDES_FILE"
  done <"$WORK/config.raw"
  return 0
}

is_excluded() { grep -qxF -- "$1" "$EXCLUDES_FILE" 2>/dev/null; }

# --- discovery -----------------------------------------------------------------

DISCOVERY_ERR=""
# discover: candidate repo dirs (relative to ROOT, sorted) -> $WORK/candidates.
# Returns 1 only when nothing usable was found (fatal). A partial find error
# sets DISCOVERY_ERR and still returns 0 (the run is marked as an error).
discover() {
  local rc p
  if [[ ! -d "$ROOT" ]]; then
    DISCOVERY_ERR="$ROOT is not a directory"
    return 1
  fi
  find "$ROOT" -mindepth 1 -maxdepth $((MAX_DEPTH + 1)) \
    \( -name node_modules -prune \) -o \( -name .git -print -prune \) \
    >"$WORK/gitpaths" 2>"$WORK/find.err"
  rc=$?
  if [[ $rc -ne 0 ]]; then
    DISCOVERY_ERR="find exited $rc: $(head -n1 "$WORK/find.err" | cut -c1-200)"
  fi
  : >"$WORK/candidates.unsorted"
  while IFS= read -r p; do
    [[ -n "$p" ]] || continue
    p="${p%/.git}"
    printf '%s\n' "${p#"$ROOT"/}" >>"$WORK/candidates.unsorted"
  done <"$WORK/gitpaths"
  LC_ALL=C sort -u "$WORK/candidates.unsorted" >"$WORK/candidates"
  if [[ ! -s "$WORK/candidates" ]]; then
    DISCOVERY_ERR="${DISCOVERY_ERR:+$DISCOVERY_ERR; }no git repositories found under $ROOT (depth <= $MAX_DEPTH)"
    return 1
  fi
  return 0
}

# classify <abs>: prints "repo", "worktree <common-dir>", or "error <reason>".
classify() {
  local abs="$1" gd cd
  gd="$(git -C "$abs" rev-parse --path-format=absolute --git-dir 2>/dev/null)" || {
    echo "error not a usable git repository"
    return
  }
  cd="$(git -C "$abs" rev-parse --path-format=absolute --git-common-dir 2>/dev/null)" || {
    echo "error not a usable git repository"
    return
  }
  if [[ "$gd" != "$cd" ]]; then
    echo "worktree $cd"
  else
    echo "repo"
  fi
}

# --- snapshot ------------------------------------------------------------------

GITLEAKS_VERSION=""
# snapshot <abs> <out>: the complete set of scan inputs for one repo.
snapshot() {
  local abs="$1" out="$2" f h head
  {
    printf 'gitleaks-version %s\n' "$GITLEAKS_VERSION"
    for f in .gitleaks.toml .gitleaksignore; do
      if [[ -f "$abs/$f" ]]; then
        h="$(sha256_file "$abs/$f")"
        [[ -n "$h" ]] || return 1
        printf 'config %s %s\n' "$f" "$h"
      elif [[ -e "$abs/$f" ]]; then
        printf 'config %s not-a-file\n' "$f"
      else
        printf 'config %s absent\n' "$f"
      fi
    done
    if head="$(git -C "$abs" rev-parse --verify -q HEAD 2>/dev/null)"; then
      printf 'head %s\n' "$head"
    else
      printf 'head %s\n' "$(git -C "$abs" symbolic-ref -q HEAD 2>/dev/null || echo detached-or-unborn) unborn"
    fi
    git -C "$abs" for-each-ref --format='ref %(refname) %(objectname)' 2>/dev/null || return 1
  } >"$out"
}

# change_reason <old> <new>: comma list of what changed; empty = unchanged.
change_reason() {
  local old="$1" new="$2" r=""
  if [[ ! -f "$old" ]]; then
    echo "never scanned"
    return
  fi
  cmp -s "$old" "$new" && return 0
  [[ "$(grep '^gitleaks-version ' "$old")" == "$(grep '^gitleaks-version ' "$new")" ]] || r="$r, gitleaks version changed"
  [[ "$(grep '^config ' "$old")" == "$(grep '^config ' "$new")" ]] || r="$r, gitleaks config changed"
  [[ "$(grep '^head ' "$old")" == "$(grep '^head ' "$new")" ]] || r="$r, HEAD moved"
  [[ "$(grep '^ref ' "$old")" == "$(grep '^ref ' "$new")" ]] || r="$r, refs changed"
  [[ -n "$r" ]] || r=", inputs changed"
  echo "${r#, }"
}

# --- report reduction ----------------------------------------------------------

# Keep only the five non-secret fields; reject anything that is not an array
# of findings carrying all of them with the expected types.
JQ_REDUCE='if type != "array" then error("report is not a JSON array") else .[] | if ((.RuleID|type) == "string" and (.File|type) == "string" and (.Commit|type) == "string" and (.StartLine|type) == "number" and (.Fingerprint|type) == "string") then [.RuleID, .File, .Commit, (.StartLine|tostring), .Fingerprint] | @tsv else error("finding is missing a required field") end end'

# --- state ---------------------------------------------------------------------

STATE_OK=1
ensure_state_dir() {
  mkdir -p "$REPOS_DIR" 2>/dev/null &&
    chmod 700 "$STATE_DIR" "$REPOS_DIR" 2>/dev/null
}

meta_get() { sed -n "s/^$1=//p" "$META_FILE" 2>/dev/null | tail -n1; }

# meta_set <key> <value>: atomic rewrite of the meta file.
meta_set() {
  local tmp="$META_FILE.tmp.$$"
  {
    grep -v "^$1=" "$META_FILE" 2>/dev/null
    printf '%s=%s\n' "$1" "$2"
  } >"$tmp" 2>/dev/null && mv -f "$tmp" "$META_FILE" 2>/dev/null
}

# --- scanning ------------------------------------------------------------------

N_SCANNED=0
N_SKIPPED=0
N_EXCLUDED=0
N_WORKTREES=0
N_ERRORS=0
N_NEW=0
N_NEW_REPOS=0
N_BASELINED=0
N_BASELINED_REPOS=0
ERRORS_FILE=""
RULES_FILE=""

record_error() {
  N_ERRORS=$((N_ERRORS + 1))
  printf '%s: %s\n' "$1" "$2" >>"$ERRORS_FILE"
  log "  ERROR $1: $2"
}

# scan_repo <abs> <rel> <pre-snapshot>
scan_repo() {
  local abs="$1" rel="$2" pre="$3" id dir report out err rc reduced n started post settled=1
  local fps newfps n_new known_existed=0
  id="$(repo_id "$rel")"
  dir="$REPOS_DIR/$id"
  report="$WORK/report.json"
  out="$WORK/scan.out"
  err="$WORK/scan.err"
  reduced="$WORK/reduced.tsv"
  rm -f "$report" "$reduced"
  started=$SECONDS
  run_group "$abs" "$out" "$err" \
    gitleaks git --redact=100 --no-banner --exit-code=10 \
    --report-format=json --report-path="$report" .
  rc=$?
  # Raw gitleaks output may contain secret material: never read, just drop.
  rm -f "$out" "$err"
  N_SCANNED=$((N_SCANNED + 1))
  case "$rc" in
    0 | 10) ;;
    124)
      rm -f "$report"
      record_error "$rel" "timeout after ${TIMEOUT}s (process group killed)"
      return
      ;;
    *)
      rm -f "$report"
      record_error "$rel" "gitleaks scan error rc=$rc"
      return
      ;;
  esac
  if [[ ! -s "$report" ]]; then
    record_error "$rel" "gitleaks rc=$rc but no JSON report was written"
    return
  fi
  if ! jq -r "$JQ_REDUCE" "$report" >"$reduced" 2>/dev/null; then
    rm -f "$report" "$reduced"
    record_error "$rel" "malformed gitleaks JSON report (rc=$rc)"
    return
  fi
  rm -f "$report"
  n="$(grep -c . "$reduced")"
  if [[ "$rc" -eq 0 && "$n" -ne 0 ]] || [[ "$rc" -eq 10 && "$n" -eq 0 ]]; then
    record_error "$rel" "inconsistent gitleaks result (rc=$rc, $n findings in report)"
    return
  fi

  # Did any input move while gitleaks was reading history?
  post="$WORK/post.snap"
  if ! snapshot "$abs" "$post" || ! cmp -s "$pre" "$post"; then
    settled=0
  fi

  fps="$WORK/fps"
  cut -f5 "$reduced" | LC_ALL=C sort -u >"$fps"
  newfps="$WORK/newfps"
  if [[ -f "$dir/known" ]]; then
    known_existed=1
    LC_ALL=C comm -23 "$fps" "$dir/known" >"$newfps"
  else
    : >"$newfps"
  fi
  n_new="$(grep -c . "$newfps")"

  # Persist: findings and known first, the snapshot last (and only when the
  # inputs held still), so any failure leaves the old snapshot -> rescan.
  local ok=1
  # New dirs are 700 via umask 077. Existing dirs are never chmod'ed here: a
  # write failure must surface as an error, not be papered over.
  mkdir -p "$dir" 2>/dev/null || ok=0
  if [[ $ok -eq 1 ]]; then
    { printf '%s\n' "$rel" >"$dir/path.tmp" && mv -f "$dir/path.tmp" "$dir/path"; } 2>/dev/null || ok=0
  fi
  if [[ $ok -eq 1 ]]; then
    { cp "$reduced" "$dir/findings.tsv.tmp" && mv -f "$dir/findings.tsv.tmp" "$dir/findings.tsv"; } 2>/dev/null || ok=0
  fi
  if [[ $ok -eq 1 ]]; then
    if [[ -f "$dir/known" ]]; then
      LC_ALL=C sort -u "$fps" "$dir/known" >"$dir/known.tmp" 2>/dev/null || ok=0
    else
      LC_ALL=C sort -u "$fps" >"$dir/known.tmp" 2>/dev/null || ok=0
    fi
    [[ $ok -eq 1 ]] && { mv -f "$dir/known.tmp" "$dir/known" 2>/dev/null || ok=0; }
  fi
  if [[ $ok -eq 1 && $settled -eq 1 ]]; then
    { cp "$pre" "$dir/snapshot.tmp" && mv -f "$dir/snapshot.tmp" "$dir/snapshot"; } 2>/dev/null || ok=0
  fi
  rm -f "$dir/path.tmp" "$dir/findings.tsv.tmp" "$dir/known.tmp" "$dir/snapshot.tmp" 2>/dev/null

  local tag=""
  if [[ $known_existed -eq 0 && "$n" -gt 0 ]]; then
    N_BASELINED=$((N_BASELINED + n))
    N_BASELINED_REPOS=$((N_BASELINED_REPOS + 1))
    tag=" (baselined)"
  fi
  if [[ "$n_new" -gt 0 ]]; then
    N_NEW=$((N_NEW + n_new))
    N_NEW_REPOS=$((N_NEW_REPOS + 1))
    tag=" (NEW)"
  fi
  log "  scanned $rel: rc=$rc findings=$n new=$n_new$tag $((SECONDS - started))s"
  if [[ "$n" -gt 0 ]]; then
    printf '%s: %s\n' "$rel" "$(cut -f1 "$reduced" | LC_ALL=C sort | uniq -c | awk '{printf "%s%s=%s", sep, $2, $1; sep = " "}')" >>"$RULES_FILE"
  fi
  [[ $settled -eq 1 ]] || log "  note $rel: refs/HEAD/config changed during the scan; snapshot not advanced (rescans next run)"
  if [[ $ok -ne 1 ]]; then
    STATE_OK=0
    record_error "$rel" "state write failed in $dir (old snapshot kept)"
  fi
}

# --- notification ----------------------------------------------------------------

notify() {
  [[ "$NOTIFY" -eq 1 ]] || return 0
  local msg="" part
  if [[ "$N_NEW" -gt 0 ]]; then
    msg="$N_NEW NEW finding(s) in $N_NEW_REPOS repo(s) - run gitleaks-audit.sh --report"
  fi
  if [[ "$N_BASELINED" -gt 0 ]]; then
    part="$N_BASELINED existing findings in $N_BASELINED_REPOS repos baselined — run \`gitleaks-audit.sh --report\`"
    msg="${msg:+$msg · }$part"
  fi
  if [[ "$RUN_ERRORS" -gt 0 ]]; then
    part="$RUN_ERRORS error(s) - see ~/Library/Logs/gitleaks-audit.log"
    msg="${msg:+$msg · }$part"
  fi
  [[ -n "$msg" ]] || return 0
  command -v osascript >/dev/null 2>&1 || return 0
  run_group "$HOME" "$WORK/notify.out" "$WORK/notify.err" \
    osascript -e "display notification \"$msg\" with title \"gitleaks-audit\"" || true
}

# --- modes -----------------------------------------------------------------------

require_tools() {
  local t missing=""
  for t in git gitleaks jq shasum; do
    command -v "$t" >/dev/null 2>&1 || missing="$missing $t"
  done
  [[ -x /usr/bin/perl ]] || missing="$missing /usr/bin/perl"
  [[ -z "$missing" ]] || {
    printf '%s' "${missing# }"
    return 1
  }
}

RUN_ERRORS=0
EXIT_CODE=0

# fatal_run <reason>: an error that stops the run before any scanning.
fatal_run() {
  log "ERROR: $1"
  RUN_ERRORS=1
  notify
  EXIT_CODE=1
}

do_scan_mode() { # dry-run | run | full
  local mode="$1" missing rel abs kind cls pre old reason forced="" last_full
  make_work
  ERRORS_FILE="$WORK/errors"
  RULES_FILE="$WORK/rules"
  : >"$ERRORS_FILE"
  : >"$RULES_FILE"
  if [[ "$mode" != "dry-run" ]]; then
    open_log
    if ! acquire_lock; then
      EXIT_CODE=$LOCK_BUSY_EXIT
      return
    fi
    log "gitleaks-audit $mode starting (pid $$, bash $BASH_VERSION)"
  fi
  if ! missing="$(require_tools)"; then
    fatal_run "missing required tool(s): $missing"
    return
  fi
  GITLEAKS_VERSION="$(gitleaks version 2>/dev/null | head -n1)"
  if [[ -z "$GITLEAKS_VERSION" ]]; then
    fatal_run "gitleaks version failed"
    return
  fi
  [[ "$mode" == "dry-run" ]] || log "gitleaks $GITLEAKS_VERSION, $(git --version 2>/dev/null)"
  if ! load_excludes; then
    fatal_run "$CONFIG_ERR; nothing scanned"
    return
  fi
  if ! discover; then
    fatal_run "discovery failed: $DISCOVERY_ERR"
    return
  fi
  if [[ -n "$DISCOVERY_ERR" ]]; then
    log "ERROR: discovery incomplete: $DISCOVERY_ERR"
    RUN_ERRORS=$((RUN_ERRORS + 1))
  fi

  last_full="$(meta_get last_full)"
  if [[ "$mode" == "full" ]]; then
    forced="full scan requested"
  elif [[ ! "$last_full" =~ ^[0-9]+$ ]]; then
    forced="weekly full scan due (never completed)"
  elif [[ $((NOW - last_full)) -ge $FULL_INTERVAL ]]; then
    forced="weekly full scan due (last full $(((NOW - last_full) / 86400))d ago)"
  fi
  [[ -n "$forced" ]] && log "$forced: every repo will be scanned"

  if [[ "$mode" != "dry-run" ]]; then
    if ! ensure_state_dir; then
      fatal_run "cannot create state dir $STATE_DIR"
      return
    fi
  fi

  pre="$WORK/pre.snap"
  while IFS= read -r rel; do
    [[ -n "$rel" ]] || continue
    abs="$ROOT/$rel"
    if is_excluded "$rel"; then
      N_EXCLUDED=$((N_EXCLUDED + 1))
      log "$(printf '  %-9s %s' excluded "$rel")"
      continue
    fi
    cls="$(classify "$abs")"
    kind="${cls%% *}"
    case "$kind" in
      worktree)
        N_WORKTREES=$((N_WORKTREES + 1))
        log "$(printf '  %-9s %s  (linked worktree; history scanned via %s)' skip "$rel" "${cls#worktree }")"
        continue
        ;;
      error)
        if [[ "$mode" == "dry-run" ]]; then
          log "$(printf '  %-9s %s  (%s)' error "$rel" "${cls#error }")"
        else
          record_error "$rel" "${cls#error }"
        fi
        continue
        ;;
    esac
    if ! snapshot "$abs" "$pre"; then
      if [[ "$mode" == "dry-run" ]]; then
        log "$(printf '  %-9s %s  (cannot read refs)' error "$rel")"
      else
        record_error "$rel" "cannot snapshot refs/HEAD/config"
      fi
      continue
    fi
    old="$REPOS_DIR/$(repo_id "$rel")/snapshot"
    reason="$(change_reason "$old" "$pre")"
    if [[ -z "$reason" && -z "$forced" ]]; then
      N_SKIPPED=$((N_SKIPPED + 1))
      log "$(printf '  %-9s %s  (unchanged)' skip "$rel")"
      continue
    fi
    [[ -n "$reason" ]] || reason="unchanged"
    [[ -n "$forced" ]] && reason="$reason; $forced"
    if [[ "$mode" == "dry-run" ]]; then
      log "$(printf '  %-9s %s  (%s)' scan "$rel" "$reason")"
      continue
    fi
    log "$(printf '  %-9s %s  (%s)' scan "$rel" "$reason")"
    scan_repo "$abs" "$rel" "$pre"
  done <"$WORK/candidates"

  [[ "$mode" == "dry-run" ]] && return
  RUN_ERRORS=$((RUN_ERRORS + N_ERRORS))
  summarize "$forced"
}

summarize() {
  local forced="$1" total=0 nrepos=0 d
  for d in "$REPOS_DIR"/*/; do
    [[ -f "$d/findings.tsv" ]] || continue
    local c
    c="$(grep -c . "$d/findings.tsv")"
    if [[ "$c" -gt 0 ]]; then
      total=$((total + c))
      nrepos=$((nrepos + 1))
    fi
  done
  log ""
  log "== Summary =="
  log "  repos: scanned $N_SCANNED, skipped (unchanged) $N_SKIPPED, excluded $N_EXCLUDED, worktrees $N_WORKTREES, errors $RUN_ERRORS"
  log "  findings: $total known in $nrepos repos; new this run $N_NEW; baselined this run $N_BASELINED"
  if [[ -s "$RULES_FILE" ]]; then
    log "  rule counts (scanned repos with findings):"
    while IFS= read -r d; do log "    $d"; done <"$RULES_FILE"
  fi
  if [[ -s "$ERRORS_FILE" ]]; then
    log "  errors:"
    while IFS= read -r d; do log "    $d"; done <"$ERRORS_FILE"
  fi

  if [[ -n "$forced" ]]; then
    if [[ "$RUN_ERRORS" -eq 0 ]]; then
      if meta_set last_full "$NOW"; then
        log "  full pass complete; last_full advanced"
      else
        STATE_OK=0
        RUN_ERRORS=$((RUN_ERRORS + 1))
        log "  ERROR: could not write $META_FILE"
      fi
    else
      log "  full pass incomplete; last_full NOT advanced (forced again next run)"
    fi
  fi
  [[ "$LOG_WRITE_FAILED" -eq 1 ]] && RUN_ERRORS=$((RUN_ERRORS + 1))

  if [[ "$RUN_ERRORS" -gt 0 ]]; then
    EXIT_CODE=1
  elif [[ "$N_NEW" -gt 0 ]]; then
    EXIT_CODE=10
  else
    EXIT_CODE=0
  fi
  if ! printf 'finished=%s exit=%s scanned=%s skipped=%s errors=%s new=%s baselined=%s known_total=%s\n' \
    "$NOW" "$EXIT_CODE" "$N_SCANNED" "$N_SKIPPED" "$RUN_ERRORS" "$N_NEW" "$N_BASELINED" "$total" \
    >"$LAST_RUN_FILE" 2>/dev/null; then
    EXIT_CODE=1
    RUN_ERRORS=$((RUN_ERRORS + 1))
    log "  ERROR: could not write $LAST_RUN_FILE"
  fi
  log "gitleaks-audit finished: exit $EXIT_CODE"
  notify
}

do_report() {
  local d any=0 rel
  if [[ ! -d "$REPOS_DIR" ]]; then
    echo "no audit state yet ($STATE_DIR); run: gitleaks-audit.sh --run"
    return 0
  fi
  for d in "$REPOS_DIR"/*/; do
    [[ -s "$d/findings.tsv" && -f "$d/path" ]] || continue
    rel="$(head -n1 "$d/path")"
    printf '%s\t%s\n' "$rel" "$d"
  done | LC_ALL=C sort | while IFS=$'\t' read -r rel d; do
    printf '== %s (%s findings)\n' "$rel" "$(grep -c . "$d/findings.tsv")"
    LC_ALL=C sort -t$'\t' -k1,1 -k2,2 -k4,4n "$d/findings.tsv" | awk -F'\t' '
      { rule[NR] = $1; loc[NR] = $2 ":" $4 " (" substr($3, 1, 8) ")"; cnt[$1]++ }
      END {
        for (i = 1; i <= NR; i++) {
          if (rule[i] != prev) { printf "  %s (%d)\n", rule[i], cnt[rule[i]]; prev = rule[i] }
          printf "    %s\n", loc[i]
        }
      }'
    echo
  done
  for d in "$REPOS_DIR"/*/; do
    [[ -s "$d/findings.tsv" ]] && any=1
  done
  if [[ "$any" -eq 0 ]]; then
    echo "no findings recorded in $STATE_DIR"
    return 0
  fi
  cat <<'EOF'
Rotation guidance:
  1. Treat every real secret above as exposed: rotate/revoke it at the
     provider FIRST, and confirm the old value no longer works.
  2. Then clean up: remove it from the code; rewriting history is optional
     hygiene, not remediation (clones, forks, and caches keep old commits).
  3. Only for verified false positives: add the finding's fingerprint
     (<commit>:<file>:<rule>:<line>) to the repo's .gitleaksignore, or mark
     the line `gitleaks:allow`.
  Details for one repo (redacted): cd <repo> && gitleaks git --redact=100 -v .
EOF
}

do_status() {
  local uid service
  uid="$(id -u)"
  service="gui/$uid/$LABEL"
  if launchctl print "$service" >/dev/null 2>&1; then
    echo "agent: loaded ($service)"
  else
    echo "agent: not loaded ($service)"
  fi
  if [[ -f "$AGENT_PLIST" ]]; then
    echo "plist: $AGENT_PLIST (present)"
  else
    echo "plist: $AGENT_PLIST (absent)"
  fi
  echo "log:   $LOG_FILE"
  echo "state: $STATE_DIR"
  local lf
  lf="$(meta_get last_full)"
  if [[ "$lf" =~ ^[0-9]+$ ]]; then
    echo "last full pass: $(/bin/date -r "$lf" '+%Y-%m-%d %H:%M:%S %z')"
  else
    echo "last full pass: never"
  fi
  if [[ -f "$LAST_RUN_FILE" ]]; then
    echo "last run: $(cat "$LAST_RUN_FILE")"
  else
    echo "last run: none"
  fi
  return 0
}

# --- launchd install / uninstall ---------------------------------------------

TEMPLATE="$SCRIPT_DIR/launchd/$LABEL.plist"
AGENT_PLIST="$HOME/Library/LaunchAgents/$LABEL.plist"
AGENT_PATH="/opt/homebrew/bin:/usr/local/bin:$SYSTEM_PATH"
AGENT_LOG="$HOME/Library/Logs/gitleaks-audit.launchd.log"

xml_escape() {
  local v="$1"
  v="${v//&/&amp;}"
  v="${v//</&lt;}"
  v="${v//>/&gt;}"
  v="${v//\"/&quot;}"
  v="${v//\'/&apos;}"
  printf '%s' "$v"
}

render_plist() {
  local out="$1" line sp hp pp op
  sp="$(xml_escape "$SCRIPT_PATH")"
  hp="$(xml_escape "$HOME")"
  pp="$(xml_escape "$AGENT_PATH")"
  op="$(xml_escape "$AGENT_LOG")"
  : >"$out" || return 1
  while IFS= read -r line || [[ -n "$line" ]]; do
    line="${line//__SCRIPT_PATH__/$sp}"
    line="${line//__HOME__/$hp}"
    line="${line//__PATH__/$pp}"
    line="${line//__STDOUT_PATH__/$op}"
    line="${line//__STDERR_PATH__/$op}"
    printf '%s\n' "$line" >>"$out" || return 1
  done <"$TEMPLATE"
}

do_install() {
  local uid domain service tmp
  uid="$(id -u)"
  domain="gui/$uid"
  service="$domain/$LABEL"
  [[ -f "$TEMPLATE" ]] || die "launchd template not found: $TEMPLATE"
  make_work
  tmp="$WORK/$LABEL.plist"
  render_plist "$tmp" || die "failed to render $TEMPLATE"
  if grep -q '__[A-Z_]*__' "$tmp"; then
    die "rendered plist still contains placeholders"
  fi
  plutil -lint "$tmp" >/dev/null || die "rendered plist failed plutil -lint"
  mkdir -p "$(dirname "$AGENT_PLIST")" "$(dirname "$AGENT_LOG")" || die "cannot create LaunchAgents/Logs directories"
  if launchctl print "$service" >/dev/null 2>&1; then
    info "$LABEL already loaded; booting it out first"
    launchctl bootout "$service" || die "launchctl bootout $service failed"
  fi
  if ! cp "$tmp" "$AGENT_PLIST" || ! chmod 644 "$AGENT_PLIST"; then
    die "cannot write $AGENT_PLIST"
  fi
  launchctl enable "$service" || warn "launchctl enable $service failed (continuing)"
  if ! launchctl bootstrap "$domain" "$AGENT_PLIST"; then
    rm -f "$AGENT_PLIST"
    die "launchctl bootstrap $domain $AGENT_PLIST failed; removed the rendered plist"
  fi
  info "installed $AGENT_PLIST (runs --run daily at 11:00; not started now)"
}

do_uninstall() {
  local uid service
  uid="$(id -u)"
  service="gui/$uid/$LABEL"
  if launchctl print "$service" >/dev/null 2>&1; then
    launchctl bootout "$service" || die "launchctl bootout $service failed; plist left in place"
    info "booted out $service"
  else
    info "$service not loaded"
  fi
  if [[ -e "$AGENT_PLIST" ]]; then
    rm -f "$AGENT_PLIST" || die "cannot remove $AGENT_PLIST"
    info "removed $AGENT_PLIST"
  fi
}

case "$MODE" in
  dry-run)
    NOTIFY=0
    echo "gitleaks-audit dry run: no scans, no state or log writes"
    do_scan_mode dry-run
    exit "$EXIT_CODE"
    ;;
  run | full)
    do_scan_mode "$MODE"
    exit "$EXIT_CODE"
    ;;
  report) do_report ;;
  status) do_status ;;
  install) do_install ;;
  uninstall) do_uninstall ;;
esac
exit 0
