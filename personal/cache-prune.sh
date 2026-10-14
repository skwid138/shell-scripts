#!/usr/bin/env bash
# cache-prune.sh — monthly, conservative developer-cache pruning for macOS.
#
# Default is a zero-mutation dry-run that inventories what --apply would do.
# --apply runs an allowlisted set of prune commands (uv, pnpm, npm, Docker via
# OrbStack); everything else is report-only. --install/--uninstall manage a
# per-user launchd agent that runs `--apply` on the 1st of each month.
#
# Designed to run under launchd's minimal environment and macOS /bin/bash 3.2:
# it builds its own PATH, never prompts, and never uses `set -e`.

set -uo pipefail

SCRIPT_DIR="$(cd "$(dirname "${BASH_SOURCE[0]}")" && pwd)"
SCRIPT_PATH="$SCRIPT_DIR/$(basename "${BASH_SOURCE[0]}")"
# shellcheck source=../lib/common.sh
source "$SCRIPT_DIR/../lib/common.sh"

usage() {
  cat <<'EOF'
Usage: cache-prune [--apply | --install | --uninstall | --status] [--no-notify]

Conservative developer-cache pruning for macOS. Default mode is a dry-run
that performs zero mutations and prints/logs what --apply would do.

Modes:
  (none)        Dry-run: inventory caches, Docker images, and report-only items.
  --apply       Run the allowlisted prune steps:
                  uv cache prune            (never --force)
                  pnpm store prune          (Corepack offline; never downloads)
                  npm cache verify
                  docker image rm <repo:tag>  per eligible tag (never -f)
                  docker image prune -f --filter until=720h   (dangling only)
                  docker builder prune -f --filter until=720h
  --install     Render the launchd template into
                ~/Library/LaunchAgents/com.skwid138.cache-prune.plist and
                bootstrap it (runs --apply on day 1 of each month at 10:00).
  --uninstall   Boot out the launchd agent (absent = OK) and remove the plist.
  --status      Show whether the launchd agent is loaded and the plist path
                (read-only; exits 0).
  -h, --help    Show this help.

Options:
  --no-notify   With --apply, skip the best-effort macOS notification.
                (Dry-runs never notify.)

Docker policy (all calls pinned to `docker --context orbstack`, each one gated
on `orb status` exiting 0; OrbStack is never started):
  A tagged image is removed only if ALL hold:
    1. no container (running or stopped) references its image ID;
    2. it has RepoDigests (i.e. it can be re-pulled);
    3. it was created strictly more than 90 days ago;
    4. none of its tags/ID appear in the keep-list.
  Any container/image inventory error skips tagged removal entirely.
  Volumes are never touched; containers are report-only.

Keep-list: ~/.config/cache-prune/keep-images — one repo:tag or image ID per
line (# comments allowed). Listing any tag protects the whole image ID.

Signals and process groups:
  Every mutating command (uv/pnpm/npm, each docker image rm, image prune,
  builder prune) runs in its own process group, started through perl, which
  confirms the group to this script (readiness) before it execs the command.
  A TERM or INT during a mutation is handled at once: that group gets TERM,
  up to CACHE_PRUNE_GRACE seconds (default 8) to exit, then KILL, and the run
  exits 143/130 with the lock released. When a command exits but leaves
  processes in its group, they get the same TERM/grace/KILL; if the group
  still cannot be confirmed empty, the step fails, no later mutation runs,
  and the run exits 1 (report steps still run); the group stays registered,
  so a TERM/INT later in the run still stops it first. The stop deadlines
  are wall-clock, and each look at the group (ps) is cut off after about
  1-2 seconds (whole-second clock) and then counts as non-empty. A mutation
  whose group never confirms readiness (5s) is killed before it execs and
  its step fails.
  Inventory and report commands run under a watchdog (CACHE_PRUNE_TIMEOUT);
  a TERM/INT stops the running one and its watchdog too (TERM, up to 1s,
  then KILL).
  Because these groups are not the launchd job's, launchd's job-group
  cleanup no longer reaches them: this cleanup plus the agent's ExitTimeOut
  (30s) take its place.
  Docker: killing the docker CLI does not cancel or roll back work the
  daemon already accepted. An interrupted run may leave a removal or prune
  partly done; the next run re-inventories from scratch.

Files:
  Log:   ~/Library/Logs/cache-prune.log (rotated to .1 above 1 MiB; authoritative)
  Lock:  ~/Library/Caches/cache-prune.lock (mkdir lock with owner pid/host/start).
         A live owner pid is busy whatever its hostname or age (--apply
         notifies after a day); a dead one is reclaimed at once; a lock with
         no parseable owner pid once untouched for 6h. Reclaiming is
         serialized by an flock on cache-prune.lock.reclaim and revalidated
         against the lock's current contents.

Exit codes:
  0   every step succeeded or was skipped
  1   one or more steps failed or timed out (later steps still ran), or
      install/uninstall failed, or run as root, or a lock infrastructure
      failure (nothing done): owner metadata could not be written (lock
      released), lock parent not a writable directory, a non-directory at
      the lock path, a lock path that cannot be classified (an lstat error
      other than ENOENT, e.g. EACCES/ENOTDIR/EIO, or its perl helper
      failing), the reclaim mutex file unopenable or its perl helper or
      flock failing, or a stale lock that cannot be removed
  2   usage error
  75  another run holds the lock (live owner pid, a lock with no parseable
      owner younger than 6h, or another run is reclaiming); nothing done
  130/143  interrupted by INT/TERM (a running mutation's process group was
      stopped first; lock released)

Environment overrides (tests/advanced use):
  CACHE_PRUNE_BASE_PATH  PATH used instead of the built-in base PATH
                         (nvm default node bin is still prepended)
  CACHE_PRUNE_NOW        epoch seconds to use as "now" for age checks
  CACHE_PRUNE_TIMEOUT    watchdog seconds for inventory/report commands (default 120)
  CACHE_PRUNE_GRACE      seconds a mutation's process group gets after TERM
                         before KILL (default 8)
  CACHE_PRUNE_LOCK_STALE_SECS  age after which a lock with no parseable owner
                         pid is reclaimed (default 21600 = 6h)
  CACHE_PRUNE_RECLAIM_WAIT  seconds to wait for the reclaim mutex (default 10)
  CACHE_PRUNE_PERL       perl for the lock-path lstat, the reclaim mutex, and
                         starting each mutation in its own process group
                         (default /usr/bin/perl)
  CACHE_PRUNE_PS         ps used to watch a mutation's process group (default
                         /bin/ps); a failing or stalled (about 1-2 seconds,
                         whole-second clock) ps never counts as an empty group
  CACHE_PRUNE_TEST_HOOK  test-only: command run at lock decision points, when
                         a mutation's group is ready (before it is
                         registered) or being reaped after its leader
                         exited, when a group observer (ps) has been started
                         (before it is registered), and before the report
                         steps
  CACHE_PRUNE_CLOCK_CMD  test-only/advanced: command printing the whole-second
                         clock used for the ps observer cutoff (default: the
                         shell's SECONDS)
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
    --apply | --install | --uninstall | --status)
      [[ "$MODE" == "dry-run" ]] || die_usage "only one of --apply/--install/--uninstall/--status may be given"
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

LABEL="com.skwid138.cache-prune"
SYSTEM_PATH="/usr/bin:/bin:/usr/sbin:/sbin"
BASE_PATH="${CACHE_PRUNE_BASE_PATH:-/opt/homebrew/bin:/usr/local/bin:$HOME/.orbstack/bin:$SYSTEM_PATH}"
TIMEOUT="${CACHE_PRUNE_TIMEOUT:-120}"
LOG_FILE="$HOME/Library/Logs/cache-prune.log"
LOG_MAX_BYTES=1048576
KEEP_FILE="$HOME/.config/cache-prune/keep-images"
DOCKER_CTX="orbstack"
IMAGE_MIN_AGE_DAYS=90
PRUNE_UNTIL="720h"
PRUNE_UNTIL_SECS=$((720 * 3600))

# Deterministic Docker target: never let an inherited host/context win.
unset DOCKER_HOST DOCKER_CONTEXT

# Corepack (pnpm shim): never prompt, never hit the network, never honor a
# project's packageManager field, never jump to "latest".
export COREPACK_ENABLE_DOWNLOAD_PROMPT=0
export COREPACK_ENABLE_NETWORK=0
export COREPACK_ENABLE_PROJECT_SPEC=0
export COREPACK_DEFAULT_TO_LATEST=0

# --- nvm default resolution --------------------------------------------------

NVM_DIR_ROOT="$HOME/.nvm"

# Print installed node versions as "major minor patch" (one per line).
nvm_installed() {
  local d v
  for d in "$NVM_DIR_ROOT/versions/node"/v*; do
    [[ -d "$d" ]] || continue
    v="${d##*/v}"
    [[ "$v" =~ ^[0-9]+\.[0-9]+\.[0-9]+$ ]] || continue
    printf '%s\n' "${v//./ }"
  done
}

# nvm_match <numeric-spec>: highest installed version whose leading components
# equal the spec's components exactly ("24" matches 24.x.y, not 240.x.y).
# Empty spec matches everything (used for node/stable). Sets NVM_MATCH.
NVM_MATCH=""
nvm_match() {
  local spec="${1#v}" s1="" s2="" s3="" best="" best_key="" maj min pat key
  if [[ -n "$spec" ]]; then
    IFS=. read -r s1 s2 s3 <<<"$spec"
  fi
  while read -r maj min pat; do
    [[ -z "$s1" || "$maj" == "$((10#$s1))" ]] || continue
    [[ -z "$s2" || "$min" == "$((10#$s2))" ]] || continue
    [[ -z "$s3" || "$pat" == "$((10#$s3))" ]] || continue
    key="$(printf '%06d%06d%06d' "$maj" "$min" "$pat")"
    if [[ -z "$best_key" || "$key" > "$best_key" ]]; then
      best_key="$key"
      best="$maj.$min.$pat"
    fi
  done < <(nvm_installed)
  NVM_MATCH="$best"
  [[ -n "$best" ]]
}

# nvm_resolve <alias>: follow the alias chain (bounded, cycle-detected) to an
# installed version. Unsupported aliases (system, iojs, ...) are unresolved.
# Runs in the current shell (no $(...)) so NVM_RESOLVED / NVM_RESOLVE_NOTE
# survive. NVM_RESOLVED is set on success; NVM_RESOLVE_NOTE explains failure.
NVM_RESOLVED=""
NVM_RESOLVE_NOTE=""
nvm_resolve() {
  local name="$1" depth=0 seen=" " file
  while [[ $depth -lt 10 ]]; do
    name="$(printf '%s' "$name" | tr -d '[:space:]')"
    if [[ "$name" =~ ^v?[0-9]+(\.[0-9]+){0,2}$ ]]; then
      if nvm_match "$name"; then
        NVM_RESOLVED="$NVM_MATCH"
        return 0
      fi
      NVM_RESOLVE_NOTE="no installed version matches '$name'"
      return 1
    fi
    case "$name" in
      node | stable)
        if nvm_match ""; then
          NVM_RESOLVED="$NVM_MATCH"
          return 0
        fi
        NVM_RESOLVE_NOTE="no node versions installed"
        return 1
        ;;
      "" | system | iojs | *..*)
        NVM_RESOLVE_NOTE="unsupported or empty alias '$name'"
        return 1
        ;;
    esac
    if [[ "$seen" == *" $name "* ]]; then
      NVM_RESOLVE_NOTE="alias cycle at '$name'"
      return 1
    fi
    seen="$seen$name "
    file="$NVM_DIR_ROOT/alias/$name"
    if [[ ! -f "$file" ]]; then
      NVM_RESOLVE_NOTE="alias '$name' not found"
      return 1
    fi
    IFS= read -r name <"$file" || [[ -n "$name" ]] || {
      NVM_RESOLVE_NOTE="alias file '$file' unreadable"
      return 1
    }
    depth=$((depth + 1))
  done
  NVM_RESOLVE_NOTE="alias chain deeper than 10"
  return 1
}

NODE_VERSION=""
NODE_BIN=""
if nvm_resolve default; then
  NODE_VERSION="$NVM_RESOLVED"
  NODE_BIN="$NVM_DIR_ROOT/versions/node/v$NODE_VERSION/bin"
  if [[ ! -d "$NODE_BIN" ]]; then
    NVM_RESOLVE_NOTE="resolved v$NODE_VERSION but $NODE_BIN is missing"
    NODE_VERSION=""
    NODE_BIN=""
  fi
fi

if [[ -n "$NODE_BIN" ]]; then
  export PATH="$NODE_BIN:$BASE_PATH"
else
  export PATH="$BASE_PATH"
fi

if [[ "$(id -u)" == "0" ]]; then
  die "refusing to run as root; cache-prune manages per-user caches and a gui/<uid> LaunchAgent"
fi

# Neutral cwd: no project npmrc/packageManager/uv.toml influence. $HOME (not
# `/`): pnpm writes a probe file into cwd and `/` is read-only on macOS.
cd "$HOME" || die "cannot cd to $HOME"

# --- clock / dates -----------------------------------------------------------

now_epoch() {
  if [[ -n "${CACHE_PRUNE_NOW:-}" ]]; then
    printf '%s\n' "$CACHE_PRUNE_NOW"
  else
    /bin/date -u +%s
  fi
}
NOW="$(now_epoch)"

# iso_to_epoch <ISO-8601>: BSD /bin/date only (GNU date may shadow `date` on
# interactive PATHs). Fractional seconds are stripped (floor). Accepts Z or a
# ±HH:MM offset. Returns 1 on anything else.
iso_to_epoch() {
  local s="$1" base rest sign oh om off epoch
  [[ "$s" =~ ^([0-9]{4}-[0-9]{2}-[0-9]{2}T[0-9]{2}:[0-9]{2}:[0-9]{2})(\.[0-9]+)?(Z|[+-][0-9]{2}:[0-9]{2})$ ]] || return 1
  base="${BASH_REMATCH[1]}"
  rest="${BASH_REMATCH[3]}"
  epoch="$(/bin/date -j -u -f '%Y-%m-%dT%H:%M:%S' "$base" +%s 2>/dev/null)" || return 1
  [[ "$epoch" =~ ^[0-9]+$ ]] || return 1
  if [[ "$rest" != "Z" ]]; then
    sign="${rest:0:1}"
    oh="${rest:1:2}"
    om="${rest:4:2}"
    off=$((10#$oh * 3600 + 10#$om * 60))
    if [[ "$sign" == "+" ]]; then
      epoch=$((epoch - off))
    else
      epoch=$((epoch + off))
    fi
  fi
  printf '%s\n' "$epoch"
}

# --- work dir, logging -------------------------------------------------------

WORK="$(mktemp -d "/tmp/cache-prune.XXXXXX")" || die "cannot create work dir"
LOCK_DIR="$HOME/Library/Caches/cache-prune.lock"
LOCK_HELD=0

# shellcheck disable=SC2329  # invoked via trap
cleanup() {
  # A signal during cleanup is only recorded (on_signal): cleanup always
  # finishes, with this exit's status.
  SIG_CLEANUP=1
  stop_timed
  if [[ "$LOCK_HELD" -eq 1 ]]; then
    local owner_pid=""
    owner_pid="$(sed -n 's/^pid=//p' "$LOCK_DIR/owner" 2>/dev/null)"
    if [[ "$owner_pid" == "$$" ]]; then
      rm -f "$LOCK_DIR/owner" "$LOCK_DIR/owner.tmp.$$"
      rmdir "$LOCK_DIR" 2>/dev/null
    fi
    LOCK_HELD=0
  fi
  [[ -n "${WORK:-}" && -d "$WORK" ]] && rm -rf "$WORK"
}

# Signals. Each mutating command runs in its own process group (see
# run_mutating) while this shell waits for it with the `wait` builtin, so a
# TERM/INT is handled at once instead of after the command exits.
# The TERM/INT handlers are installed once and never replaced (bash 3.2
# briefly installs SIG_IGN while a trap is replaced, which can drop a
# signal). Inside a critical section (CRIT_DEPTH > 0: a child has been
# started and is not yet registered - a mutation's group before CHILD_PGID,
# a ps observer before OBS_PID, a timed command and its watchdog before
# RT_PID/RT_WD) they only record the signal; sections nest (a depth
# counter), and the outermost end_critical acts on it once everything
# started inside is registered. Outside, the handler stops what is
# registered: an observer (KILL), a timed command and its watchdog
# (stop_timed), then a mutation's group (stop_group: TERM, GRACE, KILL),
# and the run exits 143/130 through the EXIT trap (lock released). A signal
# arriving while that is under way is recorded and does not restart it.
CRIT_DEPTH=0
PENDING_SIG=""
SIG_CLEANUP=0
CHILD_PGID=""
GRACE="${CACHE_PRUNE_GRACE:-8}"
[[ "$GRACE" =~ ^[0-9]+$ ]] || GRACE=8
KILL_WAIT=2
READY_WAIT=5
PS_BIN="${CACHE_PRUNE_PS:-/bin/ps}"
OBS_WAIT=2 # seconds one process-group observation may take (observe_groups)
OBS_SEQ=0
OBS_PID="" # an observation in flight (on_signal kills it)
CLOCK_CMD="${CACHE_PRUNE_CLOCK_CMD:-}"
OBS_NOW=0
RT_PID="" # a run_timed command in flight (on_signal/cleanup stop it)
RT_WD=""  # and its watchdog
# shellcheck disable=SC2329  # invoked via trap
on_signal() { # <exit code>
  if [[ "$CRIT_DEPTH" -gt 0 || "$SIG_CLEANUP" -eq 1 ]]; then
    [[ -n "$PENDING_SIG" ]] || PENDING_SIG="$1"
    return 0
  fi
  SIG_CLEANUP=1
  # An observation interrupted by this signal is abandoned, not left running.
  if [[ -n "$OBS_PID" ]]; then
    { kill -KILL "$OBS_PID" && wait "$OBS_PID"; } 2>/dev/null
    OBS_PID=""
  fi
  stop_timed
  if [[ -n "$CHILD_PGID" ]]; then
    log "  signal: stopping mutation process group $CHILD_PGID (TERM, up to ${GRACE}s, then KILL)"
    stop_group "$CHILD_PGID" ||
      log "  ERROR: mutation process group $CHILD_PGID could not be confirmed empty after TERM and KILL"
  fi
  exit "$1"
}
# begin_critical / end_critical: enter / leave a critical section. Sections
# nest; a signal recorded inside is handled only when the outermost one
# ends (with everything started inside registered by then).
begin_critical() { CRIT_DEPTH=$((CRIT_DEPTH + 1)); }
end_critical() {
  [[ "$CRIT_DEPTH" -gt 0 ]] && CRIT_DEPTH=$((CRIT_DEPTH - 1))
  if [[ "$CRIT_DEPTH" -eq 0 && -n "$PENDING_SIG" && "$SIG_CLEANUP" -eq 0 ]]; then
    on_signal "$PENDING_SIG"
  fi
  return 0
}
trap cleanup EXIT
trap 'on_signal 130' INT
trap 'on_signal 143' TERM

LOG_OK=0
REFUSE_MUTATIONS=0
# Why mutations are refused (for the skip messages): a log write failure,
# unless an earlier mutation's process group could not be confirmed empty.
REFUSE_WHY="log unwritable"
open_log() {
  mkdir -p "$(dirname "$LOG_FILE")" 2>/dev/null
  if [[ -f "$LOG_FILE" ]]; then
    local size
    size="$(/usr/bin/stat -f %z "$LOG_FILE" 2>/dev/null || echo 0)"
    if [[ "$size" =~ ^[0-9]+$ && "$size" -gt "$LOG_MAX_BYTES" ]]; then
      mv -f "$LOG_FILE" "$LOG_FILE.1" 2>/dev/null
    fi
  fi
  if { : >>"$LOG_FILE"; } 2>/dev/null; then
    LOG_OK=1
  else
    LOG_OK=0
    warn "cannot write log file $LOG_FILE"
  fi
}

# log: stdout + log file. Every file write is checked: a failure after
# startup (disk full, permissions changed, file replaced) flips the run into
# refusal mode for --apply, since the log is the authoritative record.
LOG_WRITE_FAILED=0
log() {
  printf '%s\n' "$*"
  [[ "$LOG_OK" -eq 1 ]] || return 0
  if ! { printf '[%s] %s\n' "$(/bin/date '+%Y-%m-%dT%H:%M:%S%z')" "$*" >>"$LOG_FILE"; } 2>/dev/null; then
    LOG_OK=0
    LOG_WRITE_FAILED=1
    if [[ "$MODE" == "apply" ]]; then
      REFUSE_MUTATIONS=1
      warn "log write failed ($LOG_FILE); refusing all further destructive steps"
    else
      warn "log write failed ($LOG_FILE); continuing dry-run without a log"
    fi
  fi
}

# mutation_allowed <command description>: the last check before any
# destructive command. Records the intent in the log (which also proves the
# log is still writable) and refuses if any log write has failed.
mutation_allowed() {
  [[ "$MODE" == "apply" ]] || return 1
  [[ "$REFUSE_MUTATIONS" -eq 0 ]] || return 1
  log "  running: $*"
  [[ "$REFUSE_MUTATIONS" -eq 0 && "$LOG_OK" -eq 1 ]] || {
    REFUSE_MUTATIONS=1
    return 1
  }
  return 0
}

# log_file <path>: log each line of a file, indented.
log_file() {
  local line
  while IFS= read -r line || [[ -n "$line" ]]; do
    log "    $line"
  done <"$1"
}

# --- lock ----------------------------------------------------------------------

LOCK_BUSY_EXIT=75
# A live owner pid is busy whatever its hostname or age; a dead owner pid is
# reclaimed at once. A lock with no parseable owner pid is reclaimed once its
# dir is untouched this long (a run publishes its owner within milliseconds
# of mkdir). Reclamation is serialized and revalidated (see reclaim_lock).
LOCK_STALE_SECS="${CACHE_PRUNE_LOCK_STALE_SECS:-21600}"
# A live holder older than this is reported (hung run or recycled pid).
LOCK_NOTIFY_SECS=86400
THIS_HOST="$(/bin/hostname 2>/dev/null || echo unknown)"
LOCK_ERR=""
LOCK_BUSY_NOTE=""
RECLAIM_FILE="$LOCK_DIR.reclaim"
RECLAIM_WAIT="${CACHE_PRUNE_RECLAIM_WAIT:-10}"
PERL="${CACHE_PRUNE_PERL:-/usr/bin/perl}"
TEST_HOOK="${CACHE_PRUNE_TEST_HOOK:-}"
LK_STATE=""
LK_WHY=""
LK_PID=""
LK_AGE=""

# write_lock_owner: publish owner metadata atomically (tmp + rename). On
# failure the tmp file is removed and 1 is returned.
write_lock_owner() {
  local tmp="$LOCK_DIR/owner.tmp.$$"
  if { printf 'pid=%s\nhost=%s\nstarted=%s\n' "$$" "$THIS_HOST" "$(/bin/date -u +%s)" >"$tmp" &&
    mv -f "$tmp" "$LOCK_DIR/owner"; } 2>/dev/null; then
    return 0
  fi
  rm -f "$tmp" 2>/dev/null
  return 1
}

# lock_path_type: classify LOCK_DIR from ONE filesystem observation that
# does not follow symlinks: a single lstat(2) in a perl helper (errno is
# read from the call itself, never inferred). Prints one line:
#   absent          lstat failed with ENOENT (and only then)
#   dir             a directory
#   other           anything else (regular file, symlink - dangling or not -,
#                   fifo, ...)
#   error <diag>    lstat failed with any other errno (EACCES, ENOTDIR, EIO,
#                   ...), or the helper failed to run or printed anything
#                   unexpected; never treated as absent
# It runs in a command substitution, so it cannot set LOCK_ERR: the
# diagnosis travels in the output. Callers use the printed type and never
# stat the path again: a holder can release its dir between two separate
# tests (-e then -d), which would make a normal release look like a
# non-directory in the way.
lock_path_type() {
  local out rc
  # shellcheck disable=SC2016 # perl code: $!/$ARGV are perl variables
  out="$(LC_ALL=C "$PERL" -e 'use Errno; my @s = lstat($ARGV[0]); unless (@s) { if ($!{ENOENT}) { print "absent\n" } else { printf "error %s (errno %d)\n", $!, $! + 0 } exit 0 } print((-d _) ? "dir\n" : "other\n"); exit 0' "$LOCK_DIR" 2>/dev/null)"
  rc=$?
  if [[ $rc -ne 0 ]]; then
    echo "error lstat helper $PERL failed (exit $rc)"
    return
  fi
  case "$out" in
    *$'\n'*) echo "error lstat helper $PERL gave unexpected output" ;;
    absent | dir | other | "error "?*) echo "$out" ;;
    *) echo "error lstat helper $PERL gave unexpected output" ;;
  esac
}

# lock_path_blocked: set LOCK_ERR and return 0 when a failed mkdir of the
# lock dir is an infrastructure failure, judged only from conditions that
# contention cannot produce: the parent is not a writable, searchable
# directory, a non-directory (file, symlink) sits at the lock path, or the
# lock path cannot be classified (lstat error other than ENOENT, or helper
# failure). Runs only ever create and remove the lock as a plain directory,
# so none of these states is a holder's. Sets LOCK_PATH_TYPE (lock_path_type's
# single observation: absent|dir|other|error) for the caller; the
# lock-classify test hook runs right after that observation.
LOCK_PATH_TYPE=""
lock_path_blocked() {
  local parent cls
  LOCK_PATH_TYPE=""
  parent="$(dirname "$LOCK_DIR")"
  if [[ ! -d "$parent" || ! -w "$parent" || ! -x "$parent" ]]; then
    LOCK_ERR="lock: cannot create $LOCK_DIR: $parent is not a writable directory (fix its permissions or remove what is in the way); nothing done"
    return 0
  fi
  cls="$(lock_path_type)"
  LOCK_PATH_TYPE="${cls%% *}"
  test_hook lock-classify
  case "$LOCK_PATH_TYPE" in
    other)
      LOCK_ERR="lock: cannot create $LOCK_DIR: a non-directory is in the way (remove it); nothing done"
      return 0
      ;;
    error)
      LOCK_ERR="lock: cannot classify $LOCK_DIR: ${cls#error } (an lstat error is never taken as an absent lock; inspect the path and its parent); nothing done"
      return 0
      ;;
  esac
  return 1
}

# take_lock: 0 = held; 1 = busy; 2 = error (LOCK_ERR set). A failed mkdir is
# an error only when lock_path_blocked says so; otherwise it is contention
# (the lock exists, or a holder released it between our mkdir and any later
# look), retried up to LOCK_MKDIR_TRIES times and then reported busy. The
# errno of a failed mkdir is never inferred from the path being absent
# afterwards. 2 also means the dir was created but the owner could not be
# published, so the lock was released again.
LOCK_MKDIR_TRIES=3
take_lock() {
  local try=0
  while :; do
    test_hook lock-mkdir
    mkdir "$LOCK_DIR" 2>/dev/null && break
    test_hook lock-mkdir-failed
    lock_path_blocked && return 2
    [[ "$LOCK_PATH_TYPE" == dir ]] && return 1
    try=$((try + 1))
    [[ $try -lt $LOCK_MKDIR_TRIES ]] || return 1
  done
  if write_lock_owner; then
    LOCK_HELD=1
    return 0
  fi
  rm -f "$LOCK_DIR/owner" "$LOCK_DIR"/owner.tmp.* 2>/dev/null
  rmdir "$LOCK_DIR" 2>/dev/null
  LOCK_ERR="lock: could not write owner metadata in $LOCK_DIR; lock released, nothing done"
  return 2
}

# seconds_since <epoch>: real-clock age (never CACHE_PRUNE_NOW).
seconds_since() {
  [[ "$1" =~ ^[0-9]+$ ]] || return 0
  echo $(($(/bin/date -u +%s) - $1))
}

# inspect_lock: classify the CURRENT lock contents into LK_STATE:
#   absent  no lock dir
#   live    owner pid parses (any hostname: macOS hostnames change with
#           networks, and the lock lives on this machine's disk) and is alive;
#           a recycled pid also reads as live, which is the conservative side
#   stale   owner pid parses and is dead, or there is no parseable owner pid
#           and the lock dir is untouched for >= LOCK_STALE_SECS
#   fresh   no parseable owner pid, but the lock dir is younger than that
#           (a run publishes its owner within milliseconds of mkdir)
# LK_WHY describes the decision; LK_PID/LK_AGE are set for live locks.
inspect_lock() {
  local line pid="" host="" started="" age
  LK_STATE=""
  LK_WHY=""
  LK_PID=""
  LK_AGE=""
  if [[ ! -d "$LOCK_DIR" ]]; then
    LK_STATE=absent
    return
  fi
  if [[ -f "$LOCK_DIR/owner" ]]; then
    {
      while IFS= read -r line || [[ -n "$line" ]]; do
        case "$line" in
          pid=*) pid="${line#pid=}" ;;
          host=*) host="${line#host=}" ;;
          started=*) started="${line#started=}" ;;
        esac
      done <"$LOCK_DIR/owner"
    } 2>/dev/null
  fi
  if [[ "$pid" =~ ^[1-9][0-9]*$ ]]; then
    if kill -0 "$pid" 2>/dev/null || ps -p "$pid" >/dev/null 2>&1; then
      age="$(seconds_since "$started")"
      [[ -n "$age" ]] || age="$(seconds_since "$(/usr/bin/stat -f %m "$LOCK_DIR" 2>/dev/null)")"
      LK_STATE=live
      LK_PID="$pid"
      LK_AGE="$age"
      LK_WHY="held by live pid $pid (host '$host') for ${age:-?}s"
      return
    fi
    LK_STATE=stale
    LK_WHY="dead pid $pid (host '$host')"
    return
  fi
  age="$(seconds_since "$(/usr/bin/stat -f %m "$LOCK_DIR" 2>/dev/null)")"
  if [[ "$age" =~ ^[0-9]+$ && "$age" -ge "$LOCK_STALE_SECS" ]]; then
    LK_STATE=stale
    LK_WHY="no parseable owner pid (pid='${pid}' host='${host}'), untouched for ${age}s >= ${LOCK_STALE_SECS}s"
    return
  fi
  LK_STATE=fresh
  LK_WHY="no parseable owner pid (pid='${pid}' host='${host}'), untouched ${age:-?}s < ${LOCK_STALE_SECS}s"
}

# Reclaim mutex: an exclusive flock on RECLAIM_FILE held through fd 9 of this
# shell (perl takes it on the inherited descriptor and exits; the lock lives
# as long as fd 9 is open). The kernel drops it when this process dies, so a
# crashed reclaimer never wedges later runs and no stale timeout is needed.
# RECLAIM_FILE is never deleted (unlinking a flocked file breaks exclusion).
# Returns 0 = held; 1 = another reclaimer held it for RECLAIM_WAIT seconds
# (contention: the helper's exit 3); 2 = infrastructure failure (LOCK_ERR
# set): the file cannot be opened, flock fails with an errno other than
# EWOULDBLOCK, or the helper is missing or fails.
reclaim_mutex_take() {
  local rc
  if ! { exec 9>>"$RECLAIM_FILE"; } 2>/dev/null; then
    LOCK_ERR="lock: cannot open reclaim mutex file $RECLAIM_FILE; stale lock $LOCK_DIR left in place, nothing done"
    return 2
  fi
  # Helper exits: 0 held; 3 still EWOULDBLOCK at the deadline (contention);
  # 4 flock failed with any other errno; 2 fd 9 unusable.
  # shellcheck disable=SC2016 # perl code: $f/$!/$ARGV are perl variables
  "$PERL" -e 'use Fcntl qw(:flock); use Errno; open(my $f, ">&=", 9) or exit 2; my $end = time + $ARGV[0]; until (flock($f, LOCK_EX | LOCK_NB)) { unless ($!{EWOULDBLOCK} || $!{EAGAIN}) { print STDERR "flock: $!\n"; exit 4 } exit 3 if time >= $end; select(undef, undef, undef, 0.05) } exit 0' "$RECLAIM_WAIT"
  rc=$?
  [[ $rc -eq 0 ]] && return 0
  exec 9>&-
  [[ $rc -eq 3 ]] && return 1
  if [[ $rc -eq 4 ]]; then
    LOCK_ERR="lock: reclaim mutex flock on $RECLAIM_FILE failed (exit 4: an error other than EWOULDBLOCK); stale lock $LOCK_DIR left in place, nothing done"
  else
    LOCK_ERR="lock: reclaim mutex helper $PERL failed (exit $rc); stale lock $LOCK_DIR left in place, nothing done"
  fi
  return 2
}

reclaim_mutex_release() { exec 9>&-; }

# test_hook <phase> [args...]: test-only seam to pause at a decision point
# (runs with fd 9 closed so a paused hook never holds the reclaim mutex
# itself, and fd 8 closed so it never holds a mutation's readiness FIFO).
test_hook() {
  [[ -n "$TEST_HOOK" ]] || return 0
  "$TEST_HOOK" "$@" </dev/null >/dev/null 2>&1 8>&- 9>&-
  return 0
}

# reclaim_lock: serialized reclamation. Under the reclaim mutex, re-inspect
# the CURRENT lock and remove it only if it is still stale (a contender may
# have reclaimed and re-taken it since our first look). Release the mutex,
# then take the lock by plain mkdir: whoever loses that is busy.
# Return codes as take_lock (0 held, 1 busy, 2 error with LOCK_ERR set).
reclaim_lock() {
  reclaim_mutex_take
  case $? in
    0) ;;
    1)
      log "lock: another run is reclaiming $LOCK_DIR; skipping run"
      return 1
      ;;
    *) return 2 ;;
  esac
  test_hook reclaim-locked
  inspect_lock
  case "$LK_STATE" in
    stale)
      log "lock: reclaiming stale lock $LOCK_DIR ($LK_WHY)"
      rm -f "$LOCK_DIR/owner" "$LOCK_DIR"/owner.tmp.* 2>/dev/null
      # Under the mutex nobody else may touch a stale lock (its owner is
      # dead and contenders only mkdir), so a failed rmdir of a lock that is
      # still there is an infrastructure problem, not contention.
      if ! rmdir "$LOCK_DIR" 2>/dev/null && [[ "$(lock_path_type)" != absent ]]; then
        reclaim_mutex_release
        LOCK_ERR="lock: cannot remove stale lock $LOCK_DIR ($LK_WHY): rmdir failed (unexpected contents or permissions; inspect and remove it by hand); nothing done"
        return 2
      fi
      ;;
    absent) ;;
    *)
      reclaim_mutex_release
      log "lock: $LOCK_DIR is no longer stale ($LK_WHY); skipping run"
      return 1
      ;;
  esac
  reclaim_mutex_release
  take_lock
  case $? in
    0) return 0 ;;
    1)
      log "lock: a concurrent run took $LOCK_DIR first; skipping run"
      return 1
      ;;
    *) return 2 ;;
  esac
}

# acquire_lock: 0 = held; 1 = busy (exit 75; LOCK_BUSY_NOTE set when a live
# holder is older than LOCK_NOTIFY_SECS); 2 = lock infrastructure error
# (exit 1; LOCK_ERR set): lock parent not a writable directory, a
# non-directory at the lock path, owner publish failed, the reclaim mutex
# file/helper/flock failed, or a stale lock could not be removed.
acquire_lock() {
  local rc
  mkdir -p "$(dirname "$LOCK_DIR")" 2>/dev/null
  lock_path_blocked && return 2
  take_lock
  rc=$?
  [[ $rc -eq 1 ]] || return $rc
  inspect_lock
  case "$LK_STATE" in
    absent)
      # Released between our mkdir and the inspection: one more plain try.
      take_lock
      rc=$?
      [[ $rc -eq 1 ]] && log "lock: $LOCK_DIR was re-taken by a concurrent run; skipping run"
      return $rc
      ;;
    live)
      log "lock: $LK_WHY; skipping run"
      if [[ "$LK_AGE" =~ ^[0-9]+$ && "$LK_AGE" -ge "$LOCK_NOTIFY_SECS" ]]; then
        LOCK_BUSY_NOTE="lock held by pid $LK_PID for $((LK_AGE / 3600))h; cache prune not running - see log"
      fi
      return 1
      ;;
    stale)
      test_hook reclaim-decided
      reclaim_lock
      return $?
      ;;
    *)
      log "lock: $LOCK_DIR exists with $LK_WHY; skipping run"
      return 1
      ;;
  esac
}

# --- step bookkeeping --------------------------------------------------------

STEP_NAMES=()
STEP_STATUSES=()
STEP_DETAILS=()
record_step() {
  STEP_NAMES+=("$1")
  STEP_STATUSES+=("$2")
  STEP_DETAILS+=("$3")
  log "  -> [$2] $1: $3"
}

# --- watchdog (inventory/report commands only) -------------------------------

# rt_watchdog <pid> <marker>: run in the background by run_timed. Sleeps in
# 1s foreground steps (never a backgrounded sleep) for TIMEOUT seconds,
# then marks the timeout and TERMs the command, and KILLs it 1s later. It
# keeps the default TERM disposition, so stopping it is immediate; its
# current 1s sleep may outlive it by up to a second.
rt_watchdog() {
  local n=0
  while [[ $n -lt $TIMEOUT ]]; do
    /bin/sleep 1
    n=$((n + 1))
  done
  : >"$2"
  kill -TERM "$1" 2>/dev/null
  /bin/sleep 1
  kill -KILL "$1" 2>/dev/null
}

# stop_timed: stop the registered run_timed command and watchdog (TERM, up
# to 1s, then KILL; both reaped). Used on a signal and at exit.
stop_timed() {
  local p end
  [[ -n "$RT_PID$RT_WD" ]] || return 0
  for p in $RT_PID $RT_WD; do
    kill -TERM "$p" 2>/dev/null
  done
  end=$((SECONDS + 1))
  while [[ $SECONDS -le $end ]]; do
    { [[ -n "$RT_PID" ]] && kill -0 "$RT_PID"; } 2>/dev/null ||
      { [[ -n "$RT_WD" ]] && kill -0 "$RT_WD"; } 2>/dev/null || break
    /bin/sleep 0.1
  done
  for p in $RT_PID $RT_WD; do
    kill -KILL "$p" 2>/dev/null
    wait "$p" 2>/dev/null
  done
  RT_PID=""
  RT_WD=""
}

# run_timed <out-file> <cmd...>: stdout -> out-file, stderr -> out-file.err.
# Returns the command's exit code, or 124 if the watchdog killed it.
# Never used for mutating commands. Always called in the main shell (never
# inside a command substitution, where a TERM to the script would wait for
# the command): callers read <out-file> afterwards. The command and its
# watchdog are started inside a critical section and registered (RT_PID,
# RT_WD), so a TERM/INT stops both (stop_timed).
run_timed() {
  local out="$1" rc marker
  shift
  marker="$WORK/timeout.$RANDOM.$RANDOM"
  begin_critical
  "$@" >"$out" 2>"$out.err" </dev/null 8>&- 9>&- &
  RT_PID=$!
  rt_watchdog "$RT_PID" "$marker" >/dev/null 2>&1 </dev/null 8>&- 9>&- &
  RT_WD=$!
  end_critical
  wait "$RT_PID"
  rc=$?
  RT_PID=""
  kill -TERM "$RT_WD" 2>/dev/null
  wait "$RT_WD" 2>/dev/null
  RT_WD=""
  if [[ -e "$marker" ]]; then
    rm -f "$marker"
    return 124
  fi
  return "$rc"
}

status_for_rc() {
  case "$1" in
    0) echo success ;;
    124) echo timeout ;;
    *) echo fail ;;
  esac
}

# --- mutating commands: own process group ------------------------------------

# obs_clock: OBS_NOW = the whole-second clock for the observer cutoff
# (SECONDS; CACHE_PRUNE_CLOCK_CMD substitutes it in tests).
obs_clock() {
  OBS_NOW=$SECONDS
  [[ -n "$CLOCK_CMD" ]] || return 0
  OBS_NOW="$("$CLOCK_CMD" </dev/null 2>/dev/null)"
  [[ "$OBS_NOW" =~ ^[0-9]+$ ]] || OBS_NOW=$SECONDS
}

# observe_groups <file> <until>: one bounded process listing (pid, pgid,
# stat) into <file>. ps runs in the background and is killed once OBS_WAIT
# whole seconds have elapsed since it started (so after about OBS_WAIT-1 to
# OBS_WAIT seconds of real time), or once SECONDS passes <until> (a phase
# deadline), so a stalled observer never holds up a deadline. Its launch is
# a critical section that ends once OBS_PID is registered. 0 = ps finished
# in time and succeeded; 1 = it failed, stalled, or was killed.
observe_groups() {
  local file="$1" until="$2" start p
  obs_clock
  start=$OBS_NOW
  begin_critical
  "$PS_BIN" -A -o pid= -o pgid= -o stat= >"$file" 2>/dev/null </dev/null 8>&- 9>&- &
  p=$!
  test_hook observer-launched "$p"
  OBS_PID=$p
  end_critical
  while kill -0 "$OBS_PID" 2>/dev/null; do
    obs_clock
    if [[ $((OBS_NOW - start)) -ge $OBS_WAIT || $SECONDS -gt $until ]]; then
      { kill -KILL "$OBS_PID" && wait "$OBS_PID"; } 2>/dev/null
      OBS_PID=""
      return 1
    fi
    /bin/sleep 0.05
  done
  wait "$OBS_PID" 2>/dev/null
  local rc=$?
  OBS_PID=""
  return "$rc"
}

# group_has_members <pgid> [until]: 0 when the group has a live (non-zombie)
# member OR cannot be observed (ps failed, stalled, or its listing does not
# include this shell); 1 only when a successful listing shows no live
# member. An observation failure is never read as an empty group. <until>
# (a SECONDS value) caps the observation; by default OBS_WAIT bounds it.
group_has_members() {
  local file verdict
  OBS_SEQ=$((OBS_SEQ + 1))
  file="$WORK/obs.$OBS_SEQ"
  if ! observe_groups "$file" "${2:-$((SECONDS + OBS_WAIT + 1))}"; then
    rm -f "$file" 2>/dev/null
    return 0
  fi
  verdict="$(awk -v g="$1" -v me="$$" '
    $1 == me { seen = 1 }
    $2 == g && $3 !~ /^Z/ { live = 1 }
    END { print (seen && !live) ? "empty" : "busy" }' "$file" 2>/dev/null)"
  rm -f "$file" 2>/dev/null
  [[ "$verdict" != empty ]]
}

# wait_group_empty <pgid> <secs>: 0 once the group is observed empty, 1 if
# it is not by the wall-clock deadline: <secs> seconds from now (bash's
# whole-second SECONDS, so between <secs> and <secs>+1 of real time). Each
# observation is capped by that deadline too.
wait_group_empty() {
  local end=$((SECONDS + $2))
  while group_has_members "$1" "$end"; do
    [[ $SECONDS -le $end ]] || return 1
    /bin/sleep 0.1
  done
  return 0
}

# stop_group <pgid>: TERM the group, wait up to GRACE seconds for it to
# empty, then KILL it and wait up to KILL_WAIT. 0 = observed empty;
# 1 = emptiness could not be established (members persist or ps fails).
# Bounded by wall clock: about GRACE + KILL_WAIT + 2 seconds in all.
stop_group() {
  kill -TERM -- "-$1" 2>/dev/null
  wait_group_empty "$1" "$GRACE" && return 0
  kill -KILL -- "-$1" 2>/dev/null
  wait_group_empty "$1" "$KILL_WAIT"
}

# The spawn helper (perl, argv: <fifo> <cmd...>): leave this shell's process
# group (setpgrp; exit 121 if that fails), write ONE readiness byte to the
# FIFO (non-blocking open: exit 122 if nobody is reading it), close it, and
# only then exec the command. stdin and the caller's redirections are the
# helper's own, so the command inherits them unchanged.
# shellcheck disable=SC2016 # perl code: $f/$w/$!/@ARGV are perl variables
MUT_SPAWN='use Fcntl; my $f = shift @ARGV;
setpgrp(0, 0) or exit 121;
sysopen(my $w, $f, O_WRONLY | O_NONBLOCK) or exit 122;
(syswrite($w, "R", 1) // 0) == 1 or exit 122;
close($w) or exit 122;
exec { $ARGV[0] } @ARGV;
print STDERR "cache-prune: cannot exec $ARGV[0]: $!\n";
exit 127;'
MUT_SEQ=0
MUT_ERR=""

# abort_unready <pid>: the leader never confirmed its group: TERM it (and a
# group of that id, if it got that far), a short grace, KILL both, reap the
# leader, and check that no group of that id is left (if that cannot be
# confirmed, the group stays registered in CHILD_PGID).
abort_unready() {
  local pid="$1" end=$((SECONDS + 1))
  kill -TERM "$pid" 2>/dev/null
  kill -TERM -- "-$pid" 2>/dev/null
  while kill -0 "$pid" 2>/dev/null && [[ $SECONDS -le $end ]]; do
    /bin/sleep 0.1
  done
  kill -KILL "$pid" 2>/dev/null
  kill -KILL -- "-$pid" 2>/dev/null
  wait "$pid" 2>/dev/null
  MUT_ERR="mutation not started: no readiness signal from its process group within ${READY_WAIT}s (leader $pid terminated)"
  if ! wait_group_empty "$pid" "$KILL_WAIT"; then
    MUT_ERR="$MUT_ERR; process group $pid could not be confirmed empty after TERM and KILL"
    # Stays registered: a later TERM/INT still goes after it (on_signal).
    CHILD_PGID="$pid"
    REFUSE_MUTATIONS=1
    REFUSE_WHY="an earlier mutation's process group could not be confirmed empty"
  fi
  log "  ERROR: $MUT_ERR"
}

# run_mutating <stdout-file> <stderr-file> <cmd...>: run one mutating
# command in its own process group (stderr merged into stdout when both
# files are the same), stdin </dev/null. Returns the command's own exit
# status. MUT_ERR is set (and the return is nonzero) when the command never
# started (no readiness) or when its group could not be confirmed empty
# afterwards; the latter also sets REFUSE_MUTATIONS and leaves the group
# registered in CHILD_PGID (cleared only once the group is observed empty).
# Never use this for inventory commands (run_timed).
#
# Startup is a critical section: the group exists from the helper's setpgrp
# on, but this shell only knows it once the readiness byte arrives, so a
# TERM/INT in between is deferred (on_signal) until CHILD_PGID is set.
# Readiness is mandatory: the byte is written before exec, so a command that
# finishes instantly still reports it. The FIFO is opened read-write here
# (an open that never blocks); a missing byte is caught by the deadline.
run_mutating() {
  local out="$1" err="$2" dir="$WORK/mut" fifo pid rc byte="" end
  shift 2
  MUT_ERR=""
  # A group that could not be confirmed empty stays registered until the
  # run ends; never start (or register) another one over it. REFUSE_MUTATIONS
  # already keeps callers from getting here; this is the backstop.
  if [[ -n "$CHILD_PGID" ]]; then
    MUT_ERR="mutation not started: process group $CHILD_PGID of an earlier mutation is still registered (not confirmed empty)"
    REFUSE_MUTATIONS=1
    REFUSE_WHY="an earlier mutation's process group could not be confirmed empty"
    log "  ERROR: $MUT_ERR"
    return 1
  fi
  MUT_SEQ=$((MUT_SEQ + 1))
  fifo="$dir/ready.$MUT_SEQ"
  if ! { [[ -d "$dir" ]] || mkdir -m 700 "$dir"; } 2>/dev/null ||
    ! mkfifo -m 600 "$fifo" 2>/dev/null || ! { exec 8<>"$fifo"; } 2>/dev/null; then
    rm -f "$fifo" 2>/dev/null
    MUT_ERR="mutation not started: cannot create its readiness FIFO $fifo"
    log "  ERROR: $MUT_ERR"
    return 1
  fi
  begin_critical
  if [[ "$err" == "$out" ]]; then
    "$PERL" -e "$MUT_SPAWN" "$fifo" "$@" >"$out" 2>&1 </dev/null 8>&- 9>&- &
  else
    "$PERL" -e "$MUT_SPAWN" "$fifo" "$@" >"$out" 2>"$err" </dev/null 8>&- 9>&- &
  fi
  pid=$!
  end=$((SECONDS + READY_WAIT))
  while :; do
    byte=""
    IFS= read -r -n 1 -t 1 -u 8 byte
    [[ "$byte" == R || $SECONDS -ge $end ]] && break
  done
  exec 8>&-
  rm -f "$fifo"
  if [[ "$byte" != R ]]; then
    abort_unready "$pid"
    end_critical
    return 1
  fi
  test_hook mutation-ready "$pid"
  CHILD_PGID="$pid"
  end_critical
  wait "$pid"
  rc=$?
  # The leader is gone; anything it left in its group is stopped too.
  if group_has_members "$pid"; then
    log "  process group $pid still has members after its leader exited ($rc); stopping them (TERM, up to ${GRACE}s, then KILL)"
    test_hook mutation-reaping "$pid"
    if ! stop_group "$pid"; then
      MUT_ERR="process group $pid could not be confirmed empty after TERM and KILL"
      log "  ERROR: $MUT_ERR; refusing all further destructive steps"
      REFUSE_MUTATIONS=1
      REFUSE_WHY="an earlier mutation's process group could not be confirmed empty"
      # CHILD_PGID stays set: emptiness was never observed, so a TERM/INT
      # later in the run (report steps) still stops this group first.
      [[ $rc -ne 0 ]] || rc=1
      return "$rc"
    fi
  fi
  CHILD_PGID=""
  return "$rc"
}

# mut_note <rc> <what>: failure detail for a mutating command.
mut_note() {
  if [[ -n "$MUT_ERR" ]]; then
    echo "$2: $MUT_ERR"
  else
    echo "$2 exited $1"
  fi
}

# --- size helpers -------------------------------------------------------------

# du_kb <path>: DU_KB = KB used, or "unknown". Sets a variable instead of
# printing: run_timed must run in the main shell, never in $(...).
DU_KB=""
du_kb() {
  local p="$1" out="$WORK/du.$RANDOM"
  DU_KB=0
  [[ -e "$p" ]] || return 0
  DU_KB=unknown
  if run_timed "$out" du -sk "$p" && [[ ! -s "$out.err" ]]; then
    read -r DU_KB _ <"$out" || true
    [[ "$DU_KB" =~ ^[0-9]+$ ]] || DU_KB=unknown
  fi
  rm -f "$out" "$out.err"
}

human_kb() {
  case "$1" in
    unknown | "") echo "unknown" ;;
    *) awk -v k="$1" 'BEGIN { if (k >= 1048576) printf "%.2f GB", k/1048576; else if (k >= 1024) printf "%.1f MB", k/1024; else printf "%d KB", k }' ;;
  esac
}

human_bytes() {
  awk -v b="$1" 'BEGIN { if (b >= 1e9) printf "%.2fGB", b/1e9; else if (b >= 1e6) printf "%.1fMB", b/1e6; else if (b >= 1e3) printf "%.1fkB", b/1e3; else printf "%dB", b }'
}

FREED_KB=0
FREED_UNKNOWN=0
account_freed() {
  local before="$1" after="$2"
  if [[ "$before" =~ ^[0-9]+$ && "$after" =~ ^[0-9]+$ ]]; then
    if [[ "$before" -gt "$after" ]]; then
      FREED_KB=$((FREED_KB + before - after))
    fi
  else
    FREED_UNKNOWN=1
  fi
}

# --- docker (OrbStack) -------------------------------------------------------

DOCKER_OK=0
DOCKER_SKIP_REASON=""

# orb_gate: `orb status` must exit 0 (never bare `orb`, never start OrbStack).
orb_gate() {
  local out="$WORK/orb.out" rc
  if ! command -v orb >/dev/null 2>&1; then
    DOCKER_SKIP_REASON="orb not found on PATH"
    return 1
  fi
  run_timed "$out" orb status
  rc=$?
  if [[ $rc -ne 0 ]]; then
    DOCKER_SKIP_REASON="orb status exited $rc ($(head -n1 "$out" 2>/dev/null))"
    return 1
  fi
  return 0
}

# docker_inv <out-file> <args...>: gated, pinned, watchdog-bounded inventory.
docker_inv() {
  local out="$1"
  shift
  if [[ "$DOCKER_OK" -ne 1 ]] || ! orb_gate; then
    DOCKER_OK=0
    return 125
  fi
  run_timed "$out" docker --context "$DOCKER_CTX" "$@"
}

# docker_mut <out-file> <args...>: gated, pinned mutation in its own process
# group (run_mutating). No watchdog kill.
docker_mut() {
  local out="$1"
  shift
  MUT_ERR=""
  if [[ "$DOCKER_OK" -ne 1 ]] || ! orb_gate; then
    DOCKER_OK=0
    return 125
  fi
  run_mutating "$out" "$out.err" docker --context "$DOCKER_CTX" "$@"
}

docker_rc_note() {
  case "$1" in
    125) echo "docker unavailable: $DOCKER_SKIP_REASON" ;;
    124) echo "timed out after ${TIMEOUT}s" ;;
    *) echo "exit $1: $(head -n1 "$2.err" 2>/dev/null)" ;;
  esac
}

# docker_mut_note <rc> <out-file>: docker_rc_note for a docker_mut result
# (a readiness or process-group failure is reported as such).
docker_mut_note() {
  if [[ "$1" -ne 125 && -n "$MUT_ERR" ]]; then
    echo "$MUT_ERR"
  else
    docker_rc_note "$1" "$2"
  fi
}

# load_keep_list: snapshot the keep-list once. Absent = empty (protects
# nothing). Present but not a readable regular file (mode 000, directory,
# dangling symlink, read error) = 1, and the caller must fail closed.
KEEP_SNAPSHOT=""
KEEP_ERR=""
load_keep_list() {
  KEEP_SNAPSHOT="$WORK/keep-list"
  : >"$KEEP_SNAPSHOT"
  if [[ ! -e "$KEEP_FILE" && ! -L "$KEEP_FILE" ]]; then
    return 0
  fi
  if [[ ! -f "$KEEP_FILE" || ! -r "$KEEP_FILE" ]]; then
    KEEP_ERR="keep-list $KEEP_FILE exists but is not a readable regular file"
    return 1
  fi
  if ! cat "$KEEP_FILE" >"$KEEP_SNAPSHOT" 2>/dev/null; then
    KEEP_ERR="keep-list $KEEP_FILE could not be read"
    return 1
  fi
  return 0
}

# keep_list_protects <id> <tags...>: consults the snapshot from load_keep_list.
keep_list_protects() {
  local id="$1" entry hex
  shift
  [[ -n "$KEEP_SNAPSHOT" && -f "$KEEP_SNAPSHOT" ]] || return 1
  hex="${id#sha256:}"
  while IFS= read -r entry || [[ -n "$entry" ]]; do
    entry="${entry%%#*}"
    entry="$(printf '%s' "$entry" | tr -d '[:space:]')"
    [[ -n "$entry" ]] || continue
    local t
    for t in "$@"; do
      [[ "$entry" == "$t" ]] && return 0
    done
    case "$entry" in
      sha256:*) [[ "$entry" == "$id" ]] && return 0 ;;
      *)
        if [[ "$entry" =~ ^[0-9a-f]{12,64}$ && "$hex" == "$entry"* ]]; then
          return 0
        fi
        ;;
    esac
  done <"$KEEP_SNAPSHOT"
  return 1
}

CONTAINERS_FILE=""
# docker_inventory_containers: writes "$WORK/containers" (inspect rows).
docker_inventory_containers() {
  local ids="$WORK/ps.out" rows="$WORK/containers" rc n_ids n_rows
  CONTAINERS_FILE="$rows"
  : >"$rows"
  docker_inv "$ids" ps -aq --no-trunc
  rc=$?
  if [[ $rc -ne 0 ]]; then
    CONTAINER_INV_ERR="container list failed: $(docker_rc_note "$rc" "$ids")"
    return 1
  fi
  n_ids="$(grep -c . "$ids")"
  [[ "$n_ids" -eq 0 ]] && return 0
  local args=()
  while IFS= read -r id; do
    [[ -n "$id" ]] && args+=("$id")
  done <"$ids"
  docker_inv "$rows" container inspect --format "$CONTAINER_FORMAT" "${args[@]}"
  rc=$?
  if [[ $rc -ne 0 ]]; then
    CONTAINER_INV_ERR="container inspect failed: $(docker_rc_note "$rc" "$rows")"
    return 1
  fi
  n_rows="$(grep -c . "$rows")"
  if [[ "$n_rows" -ne "$n_ids" ]]; then
    CONTAINER_INV_ERR="container inspect returned $n_rows rows for $n_ids containers"
    return 1
  fi
  return 0
}

# Templates use `index`/`with` for optional keys: Docker 29 renders inspect
# templates against raw JSON maps with missingkey=error, so `.Config.Labels`
# errors on images without labels (which would fail-close the whole step).
LABEL_TPL_PROJECT='{{with index . "Config"}}{{with index . "Labels"}}{{with index . "com.docker.compose.project"}}{{.}}{{end}}{{end}}{{end}}'
LABEL_TPL_SERVICE='{{with index . "Config"}}{{with index . "Labels"}}{{with index . "com.docker.compose.service"}}{{.}}{{end}}{{end}}{{end}}'
IMAGE_FORMAT="{{.Id}}|{{.Created}}|{{.Size}}|{{with index . \"RepoTags\"}}{{range .}}{{.}} {{end}}{{end}}|{{with index . \"RepoDigests\"}}{{len .}}{{else}}0{{end}}|$LABEL_TPL_PROJECT|$LABEL_TPL_SERVICE"
CONTAINER_FORMAT="{{.Id}}|{{.Image}}|{{.State.Status}}|{{.State.FinishedAt}}|{{.Name}}|$LABEL_TPL_PROJECT|$LABEL_TPL_SERVICE"

# docker_inventory_images <dangling:true|false> <rows-out>
docker_inventory_images() {
  local dangling="$1" rows="$2" ids="$WORK/imgids.$1" rc n_ids n_rows
  : >"$rows"
  docker_inv "$ids.raw" image ls -q --no-trunc --filter "dangling=$dangling"
  rc=$?
  if [[ $rc -ne 0 ]]; then
    IMAGE_INV_ERR="image list failed: $(docker_rc_note "$rc" "$ids.raw")"
    return 1
  fi
  # `image ls` repeats an ID once per tag/digest row; dedupe by ID.
  grep . "$ids.raw" | sort -u >"$ids"
  n_ids="$(grep -c . "$ids")"
  [[ "$n_ids" -eq 0 ]] && return 0
  local args=()
  while IFS= read -r id; do
    args+=("$id")
  done <"$ids"
  docker_inv "$rows" image inspect --format "$IMAGE_FORMAT" "${args[@]}"
  rc=$?
  if [[ $rc -ne 0 ]]; then
    IMAGE_INV_ERR="image inspect failed: $(docker_rc_note "$rc" "$rows")"
    return 1
  fi
  n_rows="$(grep -c . "$rows")"
  if [[ "$n_rows" -ne "$n_ids" ]]; then
    IMAGE_INV_ERR="image inspect returned $n_rows rows for $n_ids images"
    return 1
  fi
  return 0
}

# containers_using <image-id>: "name(state)" list of containers on that image.
containers_using() {
  [[ -n "$CONTAINERS_FILE" && -f "$CONTAINERS_FILE" ]] || return 0
  awk -F'|' -v id="$1" '$2 == id { n = $5; sub(/^\//, "", n); printf "%s%s(%s)", sep, n, $3; sep = ", " }' "$CONTAINERS_FILE"
}

short_id() {
  local h="${1#sha256:}"
  printf '%s\n' "${h:0:12}"
}

age_days() {
  echo $(((NOW - $1) / 86400))
}

REMOVE_TAGS_FILE=""
IMAGES_REMOVED_TAGS=0
REVIEW_ITEMS=0

docker_tagged_images() {
  local rows="$WORK/images.tagged" id created size tags ndig proj svc
  local epoch reasons users eligible n_elig=0 n_total=0
  REMOVE_TAGS_FILE="$WORK/remove-tags"
  : >"$REMOVE_TAGS_FILE"
  CONTAINER_INV_ERR=""
  IMAGE_INV_ERR=""

  log ""
  log "== Docker: tagged images (remove only if unused by any container, has RepoDigests, >${IMAGE_MIN_AGE_DAYS}d old, not keep-listed) =="
  if ! docker_inventory_containers; then
    record_step "docker:tagged-images" fail "$CONTAINER_INV_ERR; fail-closed, no tagged removals"
    return
  fi
  if ! docker_inventory_images false "$rows"; then
    record_step "docker:tagged-images" fail "$IMAGE_INV_ERR; fail-closed, no tagged removals"
    return
  fi
  if ! load_keep_list; then
    log "  ERROR: $KEEP_ERR"
    record_step "docker:tagged-images" fail "$KEEP_ERR; fail-closed, no tagged removals"
    return
  fi

  log "$(printf '  %-9s %-12s %6s  %-45s %s' ELIGIBLE IMAGE-ID AGE TAGS REASON)"
  while IFS='|' read -r id created size tags ndig proj svc; do
    [[ -n "$id" ]] || continue
    n_total=$((n_total + 1))
    reasons=""
    eligible=1
    # shellcheck disable=SC2086  # tags are whitespace-separated repo:tag tokens
    set -- $tags
    users="$(containers_using "$id")"
    if [[ -n "$users" ]]; then
      eligible=0
      reasons="${reasons}in use by $users; "
    fi
    if [[ ! "$ndig" =~ ^[0-9]+$ || "$ndig" -eq 0 ]]; then
      eligible=0
      reasons="${reasons}no RepoDigests (local build); "
    fi
    local age_txt="?"
    if epoch="$(iso_to_epoch "$created")"; then
      age_txt="$(age_days "$epoch")d"
      if [[ $((NOW - epoch)) -le $((IMAGE_MIN_AGE_DAYS * 86400)) ]]; then
        eligible=0
        reasons="${reasons}age $age_txt <= ${IMAGE_MIN_AGE_DAYS}d; "
      fi
    else
      eligible=0
      reasons="${reasons}unparseable Created '$created'; "
    fi
    if keep_list_protects "$id" "$@"; then
      eligible=0
      reasons="${reasons}keep-listed; "
    fi
    if [[ $# -eq 0 ]]; then
      eligible=0
      reasons="${reasons}no tags; "
    fi
    if [[ $eligible -eq 1 ]]; then
      n_elig=$((n_elig + 1))
      reasons="all criteria met"
      local t
      for t in "$@"; do
        printf '%s|%s\n' "$t" "$id" >>"$REMOVE_TAGS_FILE"
      done
    fi
    reasons="${reasons%; }"
    log "$(printf '  %-9s %-12s %6s  %-45s %s' "$([[ $eligible -eq 1 ]] && echo yes || echo no)" "$(short_id "$id")" "$age_txt" "$tags" "$reasons" | cut -c1-400)"
  done <"$rows"

  local n_tags
  n_tags="$(grep -c . "$REMOVE_TAGS_FILE")"
  if [[ "$MODE" != "apply" ]]; then
    if [[ "$n_tags" -gt 0 ]]; then
      log "  would run (per tag, never -f; each tag is re-resolved to the eligible image ID first):"
      while IFS='|' read -r t _; do
        log "    docker --context $DOCKER_CTX image rm $t"
      done <"$REMOVE_TAGS_FILE"
    fi
    record_step "docker:tagged-images" skip "dry-run: $n_elig of $n_total images eligible ($n_tags tags would be removed)"
    return
  fi
  local failed=0 refused=0 changed=0 untagged=0 deleted=0 out="$WORK/rmi.out" rc want got
  while IFS='|' read -r t want; do
    [[ -n "$t" ]] || continue
    if [[ "$REFUSE_MUTATIONS" -ne 0 ]]; then
      refused=$((refused + 1))
      continue
    fi
    # The inventory is a snapshot: re-resolve the tag (gated like every
    # docker call) and remove only if it still names the eligible image.
    # Residual window (accepted): `image rm` takes the tag, not the ID, so a
    # re-tag between this check and the rm below could still remove the
    # newer image's tag. Docker has no compare-and-delete for tags; the
    # window is milliseconds in a monthly unattended run, and rm without -f
    # still refuses images used by containers.
    docker_inv "$out" image inspect --format '{{.Id}}' "$t"
    rc=$?
    if [[ $rc -ne 0 ]]; then
      failed=$((failed + 1))
      log "  FAILED to re-resolve $t before removal ($(docker_rc_note "$rc" "$out")); not removed"
      continue
    fi
    got="$(head -n1 "$out" | tr -d '[:space:]')"
    if [[ "$got" != "$want" ]]; then
      changed=$((changed + 1))
      log "  skipped $t: now resolves to ${got:-nothing}, not eligible ID $want; not removed"
      continue
    fi
    if ! mutation_allowed "docker --context $DOCKER_CTX image rm $t   # $want"; then
      refused=$((refused + 1))
      continue
    fi
    docker_mut "$out" image rm "$t"
    rc=$?
    if [[ $rc -eq 0 ]]; then
      IMAGES_REMOVED_TAGS=$((IMAGES_REMOVED_TAGS + 1))
      untagged=$((untagged + $(grep -c '^Untagged:' "$out")))
      deleted=$((deleted + $(grep -c '^Deleted:' "$out")))
      log "  removed tag $t"
      log_file "$out"
    else
      failed=$((failed + 1))
      log "  FAILED to remove $t: $(docker_mut_note "$rc" "$out")"
    fi
  done <"$REMOVE_TAGS_FILE"
  local detail="removed $IMAGES_REMOVED_TAGS/$n_tags tags; $untagged untagged references, $deleted deleted image IDs/layers reported"
  [[ $changed -gt 0 ]] && detail="$detail; $changed skipped (tag changed since inventory)"
  if [[ $failed -gt 0 ]]; then
    # A failed removal fails the step even if later ones were refused (an
    # unconfirmed process group both fails its removal and refuses the rest).
    [[ $refused -gt 0 ]] && detail="$detail; $refused removals refused ($REFUSE_WHY)"
    record_step "docker:tagged-images" fail "$detail; $failed removals failed"
  elif [[ $refused -gt 0 ]]; then
    record_step "docker:tagged-images" skip "$detail; $refused removals refused ($REFUSE_WHY)"
  else
    record_step "docker:tagged-images" success "$detail"
  fi
}

docker_dangling() {
  local rows="$WORK/images.dangling" id created size tags ndig proj svc epoch n=0 total=0 users
  IMAGE_INV_ERR=""
  log ""
  log "== Docker: dangling images older than 30d (docker image prune -f --filter until=$PRUNE_UNTIL) =="
  # Runs after docker_tagged_images, so in --apply this inventory is taken
  # after tagged removals and immediately before the prune below.
  if [[ "$MODE" == "apply" ]]; then
    log "  (dangling candidates snapshot immediately before image prune, after tagged removals (Docker selects the final set; container-referenced rows are retained))"
  else
    log "  note: --apply re-inventories dangling images immediately before pruning (after tagged removals) and logs that candidate snapshot."
    log "        It can be longer than this list if a tagged removal leaves an image behind untagged (possible only once all of"
    log "        its tags are removed, which is what --apply does for eligible images) or if new images go dangling meanwhile."
    log "        Docker itself selects what image prune removes (dangling + until=$PRUNE_UNTIL); in-use images are kept."
  fi
  if ! docker_inventory_images true "$rows"; then
    record_step "docker:dangling-inventory" fail "$IMAGE_INV_ERR"
    [[ "$MODE" == "apply" ]] && log "  exact prune list unavailable; prune still applies docker's own dangling + until=$PRUNE_UNTIL rules"
  else
    log "$(printf '  %-12s %-36s %-28s %10s  %s' IMAGE-ID CREATED COMPOSE SIZE NOTE)"
    while IFS='|' read -r id created size tags ndig proj svc; do
      [[ -n "$id" ]] || continue
      if ! epoch="$(iso_to_epoch "$created")"; then
        log "$(printf '  %-12s %-36s %-28s %10s  %s' "$(short_id "$id")" "$created" "${proj:--}/${svc:--}" "$(human_bytes "$size")" "unparseable Created; prune decides")"
        continue
      fi
      [[ $((NOW - epoch)) -gt $PRUNE_UNTIL_SECS ]] || continue
      users="$(containers_using "$id")"
      n=$((n + 1))
      [[ "$size" =~ ^[0-9]+$ ]] && total=$((total + size))
      log "$(printf '  %-12s %-36s %-28s %10s  %s' "$(short_id "$id")" "$created" "${proj:--}/${svc:--}" "$(human_bytes "$size")" "${users:+in use by $users (prune keeps it)}")"
    done <"$rows"
    log "  $n dangling images older than 30d; combined size $(human_bytes "$total") (shared layers may make actual reclaim smaller)"
    record_step "docker:dangling-inventory" success "$n dangling images >30d, $(human_bytes "$total") listed"
  fi

  if [[ "$MODE" != "apply" ]]; then
    record_step "docker:image-prune" skip "dry-run: would run docker --context $DOCKER_CTX image prune -f --filter until=$PRUNE_UNTIL"
    return
  fi
  if ! mutation_allowed "docker --context $DOCKER_CTX image prune -f --filter until=$PRUNE_UNTIL"; then
    record_step "docker:image-prune" skip "$REFUSE_WHY; refusing destructive step"
    return
  fi
  local out="$WORK/iprune.out" rc
  docker_mut "$out" image prune -f --filter "until=$PRUNE_UNTIL"
  rc=$?
  log_file "$out"
  if [[ $rc -eq 0 ]]; then
    record_step "docker:image-prune" success "$(grep -i 'reclaimed' "$out" | head -n1)"
  else
    record_step "docker:image-prune" "$(status_for_rc "$rc")" "$(docker_mut_note "$rc" "$out")"
  fi
}

docker_builder() {
  local out="$WORK/bdu.out" rc
  log ""
  log "== Docker: build cache older than 30d (docker builder prune -f --filter until=$PRUNE_UNTIL) =="
  # `buildx du --filter until=` does not filter on this Docker version, so
  # estimate from the LAST ACCESSED column instead (relative, approximate).
  docker_inv "$out" buildx du
  rc=$?
  if [[ $rc -eq 0 ]]; then
    local est
    est="$(awk '
      $2 == "true" || $2 == "false" {
        n_all++
        if ($2 != "true") next
        rel = ""; for (i = 4; i <= NF; i++) rel = rel " " $i
        days = -1
        if (match(rel, /[0-9]+ (second|minute|hour|day|week|month|year)s? ago/)) {
          split(substr(rel, RSTART, RLENGTH), p, " "); q = p[1]; u = p[2]
        } else if (match(rel, /(About|Less than) an? [a-z]+ ago/)) {
          k = split(substr(rel, RSTART, RLENGTH), p, " "); q = 1; u = p[k - 1]
        } else next
        sub(/s$/, "", u)
        if (u == "day") days = q; else if (u == "week") days = 7 * q
        else if (u == "month") days = 30 * q; else if (u == "year") days = 365 * q
        else days = 0
        if (days <= 30) next
        s = $3; gsub(/\*/, "", s)
        num = s + 0; un = s; sub(/^[0-9.]+/, "", un)
        m = 1
        if (un == "kB" || un == "KB") m = 1e3; else if (un == "MB") m = 1e6; else if (un == "GB") m = 1e9; else if (un == "TB") m = 1e12
        t += num * m; c++
      }
      END { printf "%d %d %d", c + 0, n_all + 0, t + 0 }' "$out")"
    local cnt total_n bytes
    read -r cnt total_n bytes <<<"$est"
    grep -E '^(Shared|Private|Reclaimable|Total):' "$out" >"$out.totals"
    log_file "$out.totals"
    log "  estimate: $cnt of $total_n records last used >30d ago, ~$(human_bytes "$bytes") (from buildx du LAST ACCESSED, approximate; sizes marked * are shared and may not all be freed)"
    record_step "docker:builder-estimate" success "$cnt of $total_n records >30d, ~$(human_bytes "$bytes")"
  else
    record_step "docker:builder-estimate" "$(status_for_rc "$rc")" "$(docker_rc_note "$rc" "$out")"
  fi

  if [[ "$MODE" != "apply" ]]; then
    record_step "docker:builder-prune" skip "dry-run: would run docker --context $DOCKER_CTX builder prune -f --filter until=$PRUNE_UNTIL"
    return
  fi
  if ! mutation_allowed "docker --context $DOCKER_CTX builder prune -f --filter until=$PRUNE_UNTIL"; then
    record_step "docker:builder-prune" skip "$REFUSE_WHY; refusing destructive step"
    return
  fi
  out="$WORK/bprune.out"
  docker_mut "$out" builder prune -f --filter "until=$PRUNE_UNTIL"
  rc=$?
  log_file "$out"
  if [[ $rc -eq 0 ]]; then
    record_step "docker:builder-prune" success "$(grep -i 'total' "$out" | head -n1)"
  else
    record_step "docker:builder-prune" "$(status_for_rc "$rc")" "$(docker_mut_note "$rc" "$out")"
  fi
}

docker_containers_report() {
  local id img state finished name proj svc epoch n=0
  log ""
  log "== Docker: exited containers (report only; never removed) =="
  if [[ -z "$CONTAINERS_FILE" || ! -f "$CONTAINERS_FILE" || -n "$CONTAINER_INV_ERR" ]]; then
    record_step "docker:containers-report" fail "container inventory unavailable"
    return
  fi
  while IFS='|' read -r id img state finished name proj svc; do
    [[ -n "$id" ]] || continue
    [[ "$state" == "exited" || "$state" == "dead" || "$state" == "created" ]] || continue
    n=$((n + 1))
    local age="?"
    epoch="$(iso_to_epoch "$finished")" && age="$(age_days "$epoch")d ago"
    log "$(printf '  %-32s %-8s finished %-10s compose=%s/%s image=%s' "${name#/}" "$state" "$age" "${proj:--}" "${svc:--}" "$(short_id "$img")" | cut -c1-200)"
  done <"$CONTAINERS_FILE"
  REVIEW_ITEMS=$((REVIEW_ITEMS + n))
  record_step "docker:containers-report" success "$n exited/created containers to review"
}

docker_system_df() {
  local label="$1" out="$WORK/df.$1" rc
  docker_inv "$out" system df
  rc=$?
  log ""
  log "== Docker: system df ($label) =="
  if [[ $rc -eq 0 ]]; then
    log_file "$out"
  else
    log "  unavailable: $(docker_rc_note "$rc" "$out")"
  fi
}

docker_steps() {
  if ! command -v docker >/dev/null 2>&1; then
    record_step "docker" skip "docker CLI not found on PATH"
    return
  fi
  DOCKER_OK=1
  if ! orb_gate; then
    DOCKER_OK=0
    record_step "docker" skip "$DOCKER_SKIP_REASON; zero docker calls made"
    return
  fi
  docker_system_df before
  docker_tagged_images
  docker_dangling
  docker_builder
  docker_containers_report
  [[ "$MODE" == "apply" ]] && docker_system_df after
  if [[ "$DOCKER_OK" -ne 1 ]]; then
    record_step "docker" fail "OrbStack became unavailable mid-run: $DOCKER_SKIP_REASON"
  fi
}

# --- package-manager caches --------------------------------------------------

count_dirs() {
  local d="$1" n=0 e
  [[ -d "$d" ]] || {
    echo 0
    return
  }
  for e in "$d"/*; do
    [[ -d "$e" ]] && n=$((n + 1))
  done
  echo "$n"
}

uv_step() {
  local out="$WORK/uv.out" rc dir before after envs_before envs_after
  log ""
  log "== uv cache =="
  if ! command -v uv >/dev/null 2>&1; then
    record_step "uv" skip "uv not found on PATH"
    return
  fi
  dir=""
  if run_timed "$out" uv cache dir; then
    dir="$(head -n1 "$out")"
  fi
  if [[ -n "$dir" ]]; then
    du_kb "$dir"
    before="$DU_KB"
    envs_before="$(count_dirs "$dir/environments-v2")"
    log "  cache dir: $dir ($(human_kb "$before")); environments-v2 dirs: $envs_before"
  else
    before="unknown"
    envs_before="unknown"
    log "  cache dir: unknown (uv cache dir failed)"
  fi
  if [[ "$MODE" != "apply" ]]; then
    record_step "uv" skip "dry-run: would run uv cache prune (no --force); size $(human_kb "$before"), environments-v2 dirs $envs_before"
    return
  fi
  if ! mutation_allowed "uv cache prune"; then
    record_step "uv" skip "$REFUSE_WHY; refusing destructive step"
    return
  fi
  run_mutating "$out" "$out" uv cache prune
  rc=$?
  log_file "$out"
  after="unknown"
  envs_after="unknown"
  if [[ -n "$dir" ]]; then
    du_kb "$dir"
    after="$DU_KB"
    envs_after="$(count_dirs "$dir/environments-v2")"
  fi
  account_freed "$before" "$after"
  local detail
  detail="size $(human_kb "$before") -> $(human_kb "$after"); environments-v2 dirs $envs_before -> $envs_after"
  if [[ $rc -eq 0 ]]; then
    record_step "uv" success "$detail"
  else
    record_step "uv" fail "$(mut_note "$rc" "uv cache prune"); $detail"
  fi
}

pnpm_step() {
  local out="$WORK/pnpm.out" rc store before after pnpm
  log ""
  log "== pnpm store (Corepack offline, cwd \$HOME) =="
  if [[ -z "$NODE_BIN" ]]; then
    record_step "pnpm" skip "nvm default node unresolved (${NVM_RESOLVE_NOTE:-unknown})"
    return
  fi
  pnpm="$NODE_BIN/pnpm"
  if [[ ! -x "$pnpm" ]]; then
    record_step "pnpm" skip "no pnpm in $NODE_BIN"
    return
  fi
  run_timed "$out" "$pnpm" store path
  rc=$?
  if [[ $rc -ne 0 ]]; then
    log_file "$out.err"
    record_step "pnpm" "$(status_for_rc "$rc")" "pnpm store path exited $rc (Corepack offline: pnpm version may not be cached; no download attempted)"
    return
  fi
  store="$(head -n1 "$out")"
  du_kb "$store"
  before="$DU_KB"
  log "  store: $store ($(human_kb "$before"))"
  if [[ "$MODE" != "apply" ]]; then
    record_step "pnpm" skip "dry-run: would run pnpm store prune; store $(human_kb "$before")"
    return
  fi
  if ! mutation_allowed "$pnpm store prune"; then
    record_step "pnpm" skip "$REFUSE_WHY; refusing destructive step"
    return
  fi
  run_mutating "$out" "$out" "$pnpm" store prune
  rc=$?
  log_file "$out"
  du_kb "$store"
  after="$DU_KB"
  account_freed "$before" "$after"
  if [[ $rc -eq 0 ]]; then
    record_step "pnpm" success "store $(human_kb "$before") -> $(human_kb "$after")"
  else
    record_step "pnpm" fail "$(mut_note "$rc" "pnpm store prune"); store $(human_kb "$before") -> $(human_kb "$after")"
  fi
}

npm_step() {
  local out="$WORK/npm.out" rc cache before after npm
  log ""
  log "== npm cache =="
  if [[ -z "$NODE_BIN" ]]; then
    record_step "npm" skip "nvm default node unresolved (${NVM_RESOLVE_NOTE:-unknown})"
    return
  fi
  npm="$NODE_BIN/npm"
  if [[ ! -x "$npm" ]]; then
    record_step "npm" skip "no npm in $NODE_BIN"
    return
  fi
  cache="$HOME/.npm"
  if run_timed "$out" "$npm" config get cache && [[ -n "$(head -n1 "$out")" ]]; then
    cache="$(head -n1 "$out")"
  fi
  du_kb "$cache/_cacache"
  before="$DU_KB"
  log "  cache: $cache/_cacache ($(human_kb "$before"))"
  if [[ "$MODE" != "apply" ]]; then
    record_step "npm" skip "dry-run: would run npm cache verify; _cacache $(human_kb "$before")"
    return
  fi
  if ! mutation_allowed "$npm cache verify"; then
    record_step "npm" skip "$REFUSE_WHY; refusing destructive step"
    return
  fi
  run_mutating "$out" "$out" "$npm" cache verify
  rc=$?
  log_file "$out"
  du_kb "$cache/_cacache"
  after="$DU_KB"
  account_freed "$before" "$after"
  if [[ $rc -eq 0 ]]; then
    record_step "npm" success "_cacache $(human_kb "$before") -> $(human_kb "$after")"
  else
    record_step "npm" fail "$(mut_note "$rc" "npm cache verify"); _cacache $(human_kb "$before") -> $(human_kb "$after")"
  fi
}

# --- report-only ---------------------------------------------------------------

# report_cmd <step> <cmd...>: run a read-only command under the watchdog and
# log (up to 40 lines of) its output. Missing command -> skip.
report_cmd() {
  local step="$1" out="$WORK/report.$RANDOM" rc
  shift
  if ! command -v "$1" >/dev/null 2>&1; then
    record_step "$step" skip "$1 not found on PATH"
    return
  fi
  run_timed "$out" "$@"
  rc=$?
  head -n 40 "$out" >"$out.head"
  log_file "$out.head"
  if [[ $rc -ne 0 ]]; then
    head -n 5 "$out.err" >"$out.head"
    log_file "$out.head"
  fi
  case "$rc" in
    0) record_step "$step" success "$*" ;;
    124) record_step "$step" timeout "$* timed out after ${TIMEOUT}s" ;;
    *) record_step "$step" fail "$* exited $rc" ;;
  esac
}

report_nvm() {
  local d v n=0
  for d in "$NVM_DIR_ROOT/versions/node"/v*; do
    [[ -d "$d" ]] || continue
    v="${d##*/}"
    n=$((n + 1))
    du_kb "$d"
    if [[ -n "$NODE_VERSION" && "$v" == "v$NODE_VERSION" ]]; then
      log "    $v (default)  $(human_kb "$DU_KB")"
    else
      log "    $v  $(human_kb "$DU_KB")"
    fi
  done
  record_step "report:nvm" success "$n installed node versions (remove unused ones with: nvm uninstall <v>)"
}

report_simulators() {
  local out="$WORK/simctl" rc
  if ! command -v xcrun >/dev/null 2>&1; then
    record_step "report:simulators" skip "xcrun not found"
    return
  fi
  run_timed "$out" xcrun simctl list devices
  rc=$?
  if [[ $rc -ne 0 ]]; then
    record_step "report:simulators" skip "xcrun simctl unavailable (exit $rc)"
    return
  fi
  local total unavailable
  total="$(grep -cE '\((Booted|Shutdown)\)' "$out")"
  unavailable="$(grep -ci 'unavailable' "$out")"
  du_kb "$HOME/Library/Developer/CoreSimulator/Devices"
  log "    $total simulator devices, $unavailable marked unavailable; CoreSimulator/Devices $(human_kb "$DU_KB")"
  record_step "report:simulators" success "$total devices, $unavailable unavailable (xcrun simctl delete unavailable)"
}

report_library_caches() {
  local out="$WORK/libcaches" rc entries=() e
  for e in "$HOME/Library/Caches"/*; do
    [[ -e "$e" && "$e" != "$LOCK_DIR" ]] && entries+=("$e")
  done
  if [[ ${#entries[@]} -eq 0 ]]; then
    record_step "report:library-caches" skip "no entries in ~/Library/Caches"
    return
  fi
  run_timed "$out" du -sk "${entries[@]}"
  rc=$?
  local note=""
  if [[ $rc -ne 0 || -s "$out.err" ]]; then
    note="incomplete: some entries unreadable (TCC/permissions) or du exit $rc"
  fi
  [[ $rc -eq 124 ]] && note="incomplete: du timed out after ${TIMEOUT}s"
  sort -rn "$out" | head -n 10 | while IFS=$'\t' read -r kb path; do
    log "$(printf '    %10s  %s' "$(human_kb "$kb")" "${path##*/}")"
  done
  if [[ -n "$note" ]]; then
    log "    ($note)"
    record_step "report:library-caches" success "top 10 listed ($note)"
  else
    record_step "report:library-caches" success "top 10 listed"
  fi
}

report_steps() {
  test_hook report-steps
  log ""
  log "== Report only (nothing below is modified) =="
  log "  pip:"
  report_cmd "report:pip" python3 -m pip cache info
  log "  poetry:"
  report_cmd "report:poetry" poetry cache list
  log "  npx cache (~/.npm/_npx):"
  local npx
  du_kb "$HOME/.npm/_npx"
  npx="$DU_KB"
  log "    $(human_kb "$npx")"
  if [[ "$npx" == "unknown" ]]; then
    record_step "report:npx" fail "du failed for ~/.npm/_npx"
  else
    record_step "report:npx" success "$(human_kb "$npx")"
  fi
  log "  nvm node versions:"
  report_nvm
  log "  rustup toolchains:"
  local rustup_bin="rustup"
  command -v rustup >/dev/null 2>&1 || rustup_bin="$HOME/.cargo/bin/rustup"
  report_cmd "report:rustup" "$rustup_bin" toolchain list
  log "  simulators:"
  report_simulators
  log "  largest ~/Library/Caches entries:"
  report_library_caches
}

# --- main ----------------------------------------------------------------------

CONTAINER_INV_ERR=""
IMAGE_INV_ERR=""

df_report() {
  local out="$WORK/dfroot.$1"
  log ""
  log "== df -h / ($1; not a measure of freed space) =="
  if run_timed "$out" /bin/df -h /; then
    log_file "$out"
  else
    log "  df unavailable"
  fi
}

run_prune() {
  open_log
  acquire_lock
  case $? in
    0) ;;
    2)
      log "ERROR: $LOCK_ERR"
      EXIT_CODE=1
      notify_msg "Cache prune: $LOCK_ERR"
      return
      ;;
    *)
      EXIT_CODE=$LOCK_BUSY_EXIT
      [[ -n "$LOCK_BUSY_NOTE" ]] && notify_msg "Cache prune: $LOCK_BUSY_NOTE"
      return
      ;;
  esac
  if [[ "$MODE" == "apply" && "$LOG_OK" -ne 1 ]]; then
    REFUSE_MUTATIONS=1
    warn "--apply: log is not writable; destructive steps will be skipped"
  fi
  log "cache-prune $MODE starting (pid $$, bash $BASH_VERSION, node default: ${NODE_VERSION:-unresolved${NVM_RESOLVE_NOTE:+ — $NVM_RESOLVE_NOTE}})"
  [[ "$MODE" == "apply" ]] || log "dry-run: no changes will be made"

  df_report before
  uv_step
  pnpm_step
  npm_step
  docker_steps
  report_steps
  [[ "$MODE" == "apply" ]] && df_report after

  summarize
  [[ "$MODE" == "apply" && "$NOTIFY" -eq 1 ]] && notify
}

# notify_msg <msg>: best-effort notification for --apply (dry-runs and
# --no-notify never notify).
notify_msg() {
  [[ "$MODE" == "apply" && "$NOTIFY" -eq 1 ]] || return 0
  command -v osascript >/dev/null 2>&1 || return 0
  run_timed "$WORK/notify.out" osascript -e "display notification \"$1\" with title \"cache-prune\"" || true
}

# notify: best-effort; failure ignored. "freed" counts only measured du deltas
# of the uv/pnpm/npm caches (Docker reclaim is in the log, not here).
notify() {
  local gb msg prefix="Cache prune"
  gb="$(awk -v k="$FREED_KB" 'BEGIN { printf "%.2f", k / 1048576 }')"
  [[ "$EXIT_CODE" -ne 0 ]] && prefix="Cache prune (with failures; see log)"
  msg="$prefix: freed ~$gb GB · $IMAGES_REMOVED_TAGS image tags removed · $REVIEW_ITEMS items to review"
  command -v osascript >/dev/null 2>&1 || return 0
  run_timed "$WORK/notify.out" osascript -e "display notification \"$msg\" with title \"cache-prune\"" || true
}

summarize() {
  local i n_fail=0
  log ""
  log "== Summary ($MODE) =="
  for ((i = 0; i < ${#STEP_NAMES[@]}; i++)); do
    log "$(printf '  %-26s %-8s %s' "${STEP_NAMES[$i]}" "${STEP_STATUSES[$i]}" "${STEP_DETAILS[$i]}")"
    case "${STEP_STATUSES[$i]}" in
      fail | timeout) n_fail=$((n_fail + 1)) ;;
    esac
  done
  [[ "$REFUSE_MUTATIONS" -eq 1 ]] && n_fail=$((n_fail + 1))
  [[ "$LOG_WRITE_FAILED" -eq 1 ]] && log "  log write failed during the run; destructive steps after that point were refused (--apply)"
  if [[ "$MODE" == "apply" ]]; then
    log "  measured cache reclaim (uv/pnpm/npm du deltas): $(human_kb "$FREED_KB")$([[ $FREED_UNKNOWN -eq 1 ]] && echo '; some sizes unknown')"
    log "  docker image tags removed: $IMAGES_REMOVED_TAGS (Docker reclaim: see prune output and system df above)"
  fi
  if [[ $n_fail -gt 0 ]]; then
    log "cache-prune $MODE finished with $n_fail failed/timed-out step(s) (partial results above)"
    EXIT_CODE=1
  else
    log "cache-prune $MODE finished OK"
    EXIT_CODE=0
  fi
  # Final check, after every summary write: the log is the authoritative
  # record, so a write failure anywhere (including the lines above, after
  # n_fail was counted) must not end in success.
  if [[ "$LOG_WRITE_FAILED" -eq 1 ]]; then
    EXIT_CODE=1
    warn "log write failed during the run ($LOG_FILE is incomplete); exiting nonzero"
  fi
}

# --- launchd install / uninstall ---------------------------------------------

TEMPLATE="$SCRIPT_DIR/launchd/$LABEL.plist"
AGENT_PLIST="$HOME/Library/LaunchAgents/$LABEL.plist"
AGENT_PATH="$SYSTEM_PATH:/opt/homebrew/bin:/usr/local/bin"
AGENT_LOG="$HOME/Library/Logs/cache-prune.launchd.log"

xml_escape() {
  local v="$1"
  v="${v//&/&amp;}"
  v="${v//</&lt;}"
  v="${v//>/&gt;}"
  v="${v//\"/&quot;}"
  v="${v//\'/&apos;}"
  printf '%s' "$v"
}

# render_plist <out>: substitute XML-escaped values into the template.
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
  info "installed $AGENT_PLIST (runs --apply on day 1 of each month at 10:00; not started now)"
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

# do_status: read-only launchd state for `make agents-status`.
do_status() {
  local service
  service="gui/$(id -u)/$LABEL"
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
}

EXIT_CODE=0
case "$MODE" in
  dry-run | apply)
    run_prune
    exit "$EXIT_CODE"
    ;;
  install) do_install ;;
  uninstall) do_uninstall ;;
  status) do_status ;;
esac
exit 0
