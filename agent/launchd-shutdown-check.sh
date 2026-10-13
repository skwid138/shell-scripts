#!/usr/bin/env bash
# launchd-shutdown-check.sh — opt-in MANUAL exercise: when launchd stops a
# running gitleaks-audit or cache-prune job (`launchctl bootout` or
# `launchctl kill TERM`), does anything survive or stay half-done?
#
# It never touches the real agents (com.skwid138.cache-prune,
# com.skwid138.gitleaks-audit) beyond `launchctl print`, never uses the real
# store, state, caches, or LaunchAgents dir: everything runs from a
# throwaway job com.skwid138.shutdowntest.<pid> whose plist, HOME, stubs, and
# fixtures live in one private temp dir. See --help.

set -uo pipefail

SCRIPT_DIR="$(cd "$(dirname "${BASH_SOURCE[0]}")" && pwd)"
# shellcheck source=../lib/common.sh
source "$SCRIPT_DIR/../lib/common.sh"

usage() {
  cat <<'EOF'
Usage: launchd-shutdown-check.sh --target gitleaks-audit|cache-prune [--run]

An opt-in manual exercise of launchd stopping a real gitleaks-audit or
cache-prune run. Without --run it only describes what it would do. With
--run it talks to YOUR launchd (gui/<uid> domain) and takes a few minutes.

It refuses to start if its label already exists, and only ever acts on one
throwaway job, always by its exact service name gui/<uid>/<label> with
<label> = com.skwid138.shutdowntest.<pid> (never a domain-only bootout).
The real agents are only read with `launchctl print`, before and after;
their output must be identical.

The throwaway job runs the real script (personal/<target>.sh, --run or
--apply) with a plist that mirrors production (gitleaks-audit: ExitTimeOut
30; cache-prune: no ExitTimeOut) and these EnvironmentVariables:
  HOME                      a temp dir (fake repo / fake nvm default inside)
  GITLEAKS_AUDIT_BASE_PATH  <temp>/stubs:/usr/bin:/bin:/usr/sbin:/sbin
  CACHE_PRUNE_BASE_PATH     <temp>/stubs:/usr/bin:/bin:/usr/sbin:/sbin
  GITLEAKS_AUDIT_TIMEOUT    3600 (the audit's own watchdog cannot fire)
No Homebrew or OrbStack directory is on either PATH. Before bootstrapping,
the resolution of every tool the job uses is checked explicitly against
that PATH and the fake nvm default bin (absolute npm/pnpm included).

The stubbed step (`gitleaks git` for the audit, `uv cache prune` for
cache-prune) writes a per-attempt marker (pid, pgid, attempt), spawns a
descendant (TERM-ignoring for the audit), and sleeps past the observation
window. For each target:
  stop (a)  launchctl bootout gui/<uid>/<label> while the step runs: no
            process may survive in the step's process group, nor in the
            job's own process group (the script and, for the audit, its
            watchdog), within the stop timeout counted from the stop
            request (audit: ExitTimeOut 30 + 5s), the lock must be released
            or reclaimable, and nothing may be published (audit: the repo
            snapshot not advanced, or the publication unsettled; cache-prune:
            no "finished OK" for that attempt). Re-bootstrap; the next run
            must exit 0 (cache-prune: and log "finished OK").
  stop (b)  launchctl kill TERM gui/<uid>/<label>: a signal only, the
            service stays registered; the same checks, then the next run
            (kickstart) must exit 0.
A readiness timeout (no marker) is a failure, and so is any failure to
observe processes (ps erroring is never read as "nothing left" or "owner
gone"). Every check runs and is
reported BEFORE any rescue cleanup; the EXIT trap then boots out the
throwaway job (exact service) if it is still loaded, kills only processes
of this run (argv inside its temp dir), and removes only its temp dir.

Options:
  --target T   gitleaks-audit or cache-prune (required)
  --run        actually run the exercise (otherwise describe it)
  -h, --help   this help

Exit: 0 every check passed; 1 a check failed or the run was refused;
2 usage error.

Environment overrides (tests/advanced use):
  LAUNCHD_CHECK_LAUNCHCTL      launchctl (default /bin/launchctl)
  LAUNCHD_CHECK_PS             ps (default /bin/ps)
  LAUNCHD_CHECK_READY_TIMEOUT  seconds to wait for a marker (default 60)
  LAUNCHD_CHECK_STOP_TIMEOUT   seconds for the group to empty after a stop
                               (default 35 audit, 25 cache-prune)
  LAUNCHD_CHECK_RUN_TIMEOUT    seconds for a normal run to finish (default 300)
  LAUNCHD_CHECK_SYSTEM_PATH    system dirs after the stubs
                               (default /usr/bin:/bin:/usr/sbin:/sbin)
EOF
}

TARGET=""
RUN=0
while [[ $# -gt 0 ]]; do
  case "$1" in
    -h | --help)
      usage
      exit 0
      ;;
    --target)
      [[ $# -ge 2 ]] || die_usage "--target needs gitleaks-audit or cache-prune"
      TARGET="$2"
      shift 2
      ;;
    --run)
      RUN=1
      shift
      ;;
    *) die_usage "unknown argument: $1 (see --help)" ;;
  esac
done
case "$TARGET" in
  gitleaks-audit)
    JOB_ARG="--run"
    EXIT_TIMEOUT=30
    STOP_DEFAULT=35
    LOCK_NAME="gitleaks-audit.lock"
    ;;
  cache-prune)
    JOB_ARG="--apply"
    EXIT_TIMEOUT=""
    STOP_DEFAULT=25 # launchd's default exit timeout (20s) + 5s
    LOCK_NAME="cache-prune.lock"
    ;;
  "") die_usage "--target gitleaks-audit|cache-prune is required (see --help)" ;;
  *) die_usage "unknown target: $TARGET (gitleaks-audit or cache-prune)" ;;
esac

LAUNCHCTL="${LAUNCHD_CHECK_LAUNCHCTL:-/bin/launchctl}"
PS="${LAUNCHD_CHECK_PS:-/bin/ps}"
READY_TIMEOUT="${LAUNCHD_CHECK_READY_TIMEOUT:-60}"
STOP_TIMEOUT="${LAUNCHD_CHECK_STOP_TIMEOUT:-$STOP_DEFAULT}"
RUN_TIMEOUT="${LAUNCHD_CHECK_RUN_TIMEOUT:-300}"
SYSTEM_PATH="${LAUNCHD_CHECK_SYSTEM_PATH:-/usr/bin:/bin:/usr/sbin:/sbin}"
for v in READY_TIMEOUT STOP_TIMEOUT RUN_TIMEOUT; do
  [[ "${!v}" =~ ^[1-9][0-9]*$ ]] || die_usage "LAUNCHD_CHECK_$v must be a positive integer"
done
REPO_ROOT="$(cd "$SCRIPT_DIR/.." && pwd -P)"
TARGET_SCRIPT="$REPO_ROOT/personal/$TARGET.sh"
MYUID="$(id -u)"
DOMAIN="gui/$MYUID"
LABEL="com.skwid138.shutdowntest.$$"
SERVICE="$DOMAIN/$LABEL"
REAL_AGENTS="com.skwid138.cache-prune com.skwid138.gitleaks-audit"
NODE_VER="24.0.0"
FIXTURE_REPO="shutdowntest-repo"

if [[ "$RUN" -eq 0 ]]; then
  echo "launchd-shutdown-check (description only; nothing is started)"
  echo "  target:   $TARGET ($TARGET_SCRIPT $JOB_ARG)"
  echo "  service:  $DOMAIN/com.skwid138.shutdowntest.<pid> (throwaway; exact target only)"
  echo "  stops:    launchctl bootout, then launchctl kill TERM, each followed by a normal run"
  echo "  real agents: read with launchctl print only (must be unchanged)"
  echo "Run it with: $0 --target $TARGET --run   (manual opt-in; see --help)"
  exit 0
fi

[[ "$(uname -s)" == "Darwin" ]] || die "launchd-shutdown-check is macOS-only"
[[ "$MYUID" != "0" ]] || die "refusing to run as root (it exercises the gui/<uid> domain)"
[[ -f "$TARGET_SCRIPT" ]] || die "target script not found: $TARGET_SCRIPT"

# --- results ---------------------------------------------------------------------

PASSES=0
FAILS=0
DETAIL=""
pass() {
  PASSES=$((PASSES + 1))
  echo "PASS: $*"
}
fail() {
  FAILS=$((FAILS + 1))
  echo "FAIL: $*"
}
# check <name> <predicate...>: predicates may set DETAIL to explain a failure.
check() {
  local name="$1"
  shift
  DETAIL=""
  if "$@"; then
    pass "$name"
  else
    fail "$name${DETAIL:+: $DETAIL}"
  fi
}
# finish: the summary; the EXIT trap does any rescue cleanup afterwards.
finish() {
  echo
  if [[ "$FAILS" -eq 0 ]]; then
    echo "result: PASS ($PASSES checks)"
    exit 0
  fi
  echo "result: FAIL ($FAILS of $((PASSES + FAILS)) checks failed)"
  exit 1
}
# gate: stop after a phase whose checks failed (the next phase would only
# measure the leftovers of this one).
gate() { [[ "$FAILS" -eq 0 ]] || finish; }

# --- rescue (EXIT trap): only what this run created ------------------------------

ROOT=""
BOOTSTRAPPED=0
PGIDS=""
# shellcheck disable=SC2329 # invoked via trap
cleanup() {
  local rc=$? pid pgid cmd
  trap - EXIT
  if [[ "$BOOTSTRAPPED" -eq 1 ]]; then
    echo "rescue: booting out $SERVICE"
    "$LAUNCHCTL" bootout "$SERVICE" >/dev/null 2>&1
    BOOTSTRAPPED=0
  fi
  if [[ -n "$ROOT" && -n "$PGIDS" ]]; then
    "$PS" -axo pid=,pgid=,command= 2>/dev/null | while read -r pid pgid cmd; do
      [[ " $PGIDS " == *" $pgid "* && "$cmd" == *"$ROOT"* ]] || continue
      echo "rescue: killing pid $pid (pgid $pgid): $cmd"
      kill -KILL "$pid" 2>/dev/null
    done
  fi
  [[ -n "$ROOT" && -d "$ROOT" ]] && rm -rf "$ROOT"
  exit "$rc"
}
trap cleanup EXIT
trap 'exit 130' INT
trap 'exit 143' TERM

# --- helpers ---------------------------------------------------------------------

xml() {
  local v="$1"
  v="${v//&/&amp;}"
  v="${v//</&lt;}"
  v="${v//>/&gt;}"
  printf '%s' "$v"
}

# alive <pid>: 0 alive, 1 gone, 2 could not observe (PS_ERR set). ps exits
# 1 with no output and no message for a valid pid that does not exist; any
# other outcome is an observation failure, never "gone".
PS_ERR=""
alive() {
  local out err rc
  out="$("$PS" -o pid= -p "$1" 2>"$ROOT/ps.err")"
  rc=$?
  err="$(head -c 200 "$ROOT/ps.err" 2>/dev/null)"
  if [[ $rc -eq 0 && "$(printf '%s' "$out" | tr -d ' ')" == "$1" ]]; then
    return 0
  fi
  if [[ $rc -eq 1 && -z "$out" && -z "$err" ]]; then
    return 1
  fi
  PS_ERR="cannot observe pid $1 (ps exit $rc${err:+: $err})"
  return 2
}

# pgid_members <pgid>: pids currently in that process group; returns 2 (and
# prints the reason) when ps fails or lists nothing (it always lists at
# least launchd and itself), so a failed observation never reads as empty.
pgid_members() {
  local out rc
  out="$("$PS" -axo pid=,pgid= 2>"$ROOT/ps.err")"
  rc=$?
  if [[ $rc -ne 0 || -z "$out" ]]; then
    printf 'cannot observe processes (ps exit %s%s)' "$rc" "$(head -c 200 "$ROOT/ps.err" 2>/dev/null | sed 's/^/: /')"
    return 2
  fi
  awk -v g="$1" '$2 == g { printf "%s ", $1 }' <<<"$out"
}

# now_ms: wall clock in milliseconds (stop deadlines count from the request).
now_ms() { /usr/bin/perl -MTime::HiRes=time -e 'printf "%d\n", time() * 1000'; }

# resolve <PATH> <tool>: what a job with that PATH runs for <tool>.
resolve() { env -i PATH="$1" /bin/bash -c 'command -v -- "$1"' _ "$2" 2>/dev/null; }

fixture_git() {
  env -i HOME="$ROOT/githome" PATH="$SYSTEM_PATH" GIT_CONFIG_GLOBAL=/dev/null GIT_CONFIG_NOSYSTEM=1 \
    GIT_AUTHOR_NAME=shutdowntest GIT_AUTHOR_EMAIL=shutdowntest@example.invalid \
    GIT_COMMITTER_NAME=shutdowntest GIT_COMMITTER_EMAIL=shutdowntest@example.invalid \
    git -C "$HOMEDIR/code/$FIXTURE_REPO" "$@" >/dev/null 2>&1
}

capture_real() { # <before|after>
  local a
  for a in $REAL_AGENTS; do
    {
      "$LAUNCHCTL" print "$DOMAIN/$a" 2>&1
      echo "rc=$?"
    } >"$ROOT/real.$1.$a"
  done
}

# --- fixture -----------------------------------------------------------------------

write_stub() { # <path> <body>
  printf '#!/bin/bash\n# launchd-shutdown-check stub\n%s\n' "$2" >"$1" && chmod 755 "$1"
}

# The stubbed step: marker (pid, pgid, attempt, descendant), then hang past
# the observation window while $FX/hang exists; otherwise succeed.
# shellcheck disable=SC2016 # stub code, expanded when the stub runs
STEP_BODY='fx="${SHUTDOWN_FIXTURE:?}"
root="${fx%/fixture}"
id="$(cat "$fx/attempt" 2>/dev/null)"
pg="$(/bin/ps -o pgid= -p $$ | tr -d " ")"
child=""
if [[ -e "$fx/hang" ]]; then
  if [[ "${STEP_CHILD_IGNORES_TERM:-0}" -eq 1 ]]; then
    (trap "" TERM; exec "$root/stubs/shutdowntest-sleep" 600) </dev/null >/dev/null 2>&1 &
  else
    ("$root/stubs/shutdowntest-sleep" 600) </dev/null >/dev/null 2>&1 &
  fi
  child=$!
fi
printf "pid=%s pgid=%s fixture=%s child=%s\n" "$$" "$pg" "$id" "$child" >"$fx/marker.$id.tmp" &&
  mv -f "$fx/marker.$id.tmp" "$fx/marker.$id"
if [[ -e "$fx/hang" ]]; then
  "$root/stubs/shutdowntest-sleep" 600
  exit 0
fi'

build_stubs() {
  local s="$STUBDIR"
  mkdir -p "$s" "$NVM_BIN" "$HOMEDIR/.nvm/alias" "$HOMEDIR/.cache/uv" "$HOMEDIR/code" "$FX" "$ROOT/githome" || return 1
  printf '%s\n' "$NODE_VER" >"$HOMEDIR/.nvm/alias/default"
  ln -s /bin/sleep "$s/shutdowntest-sleep" || return 1
  # shellcheck disable=SC2016 # stub code
  write_stub "$s/gitleaks" 'case "${1-}" in
  version) echo "8.30.1"; exit 0 ;;
  git) ;;
  *) exit 2 ;;
esac
STEP_CHILD_IGNORES_TERM=1
'"$STEP_BODY"'
for a in "$@"; do case "$a" in --report-path=*) echo "[]" >"${a#--report-path=}" ;; esac; done
exit 0' || return 1
  # shellcheck disable=SC2016 # stub code
  write_stub "$s/uv" 'case "$*" in
  "cache dir") echo "$HOME/.cache/uv"; exit 0 ;;
  "cache prune") ;;
  *) exit 0 ;;
esac
'"$STEP_BODY"'
exit 0' || return 1
  write_stub "$s/osascript" 'exit 0' || return 1
  write_stub "$s/python3" 'exit 0' || return 1
  write_stub "$s/poetry" 'exit 0' || return 1
  write_stub "$s/rustup" 'exit 0' || return 1
  write_stub "$s/xcrun" 'exit 1' || return 1
  # shellcheck disable=SC2016 # stub code
  write_stub "$NVM_BIN/npm" 'case "$*" in "config get cache") echo "$HOME/.npm" ;; esac
exit 0' || return 1
  # shellcheck disable=SC2016 # stub code
  write_stub "$NVM_BIN/pnpm" 'case "$*" in "store path") echo "$HOME/Library/pnpm/store" ;; esac
exit 0'
}

# --- explicit command resolution ---------------------------------------------------

is_stub() { [[ -x "$1" ]] && grep -q '^# launchd-shutdown-check stub$' "$1" 2>/dev/null; }

expect_stub() { # <tool>: resolves to our stub on the job's base PATH
  local r
  r="$(resolve "$BASE_PATH" "$1")"
  DETAIL="resolves to '${r:-nothing}'"
  [[ "$r" == "$STUBDIR/$1" ]] && is_stub "$r"
}

expect_system() { # <tool>: resolves under the system PATH (not Homebrew/OrbStack)
  local r
  r="$(resolve "$BASE_PATH" "$1")"
  DETAIL="resolves to '${r:-nothing}' with PATH=$BASE_PATH"
  [[ -n "$r" && "$r" == "$(resolve "$SYSTEM_PATH" "$1")" && "$r" != "$STUBDIR/"* ]] || return 1
  case "$r" in
    /opt/homebrew/* | /usr/local/* | *.orbstack*) return 1 ;;
  esac
  return 0
}

expect_absent() { # <tool>: nothing resolves (Docker/OrbStack steps skip)
  local r
  r="$(resolve "$BASE_PATH" "$1")"
  DETAIL="resolves to '$r'"
  [[ -z "$r" ]]
}

expect_nvm_stub() { # <tool>: the nvm default bin holds our stub, and it wins on PATH
  local r
  r="$(resolve "$NVM_BIN:$BASE_PATH" "$1")"
  DETAIL="expected $NVM_BIN/$1, resolves to '${r:-nothing}'"
  [[ "$(cat "$HOMEDIR/.nvm/alias/default" 2>/dev/null)" == "$NODE_VER" ]] &&
    is_stub "$NVM_BIN/$1" && [[ "$r" == "$NVM_BIN/$1" ]]
}

verify_resolution() {
  local t
  if [[ "$TARGET" == gitleaks-audit ]]; then
    for t in gitleaks osascript; do check "$t resolves to the stub" expect_stub "$t"; done
    for t in git jq shasum; do check "$t resolves under the system PATH" expect_system "$t"; done
    check "perl is /usr/bin/perl" test -x /usr/bin/perl
  else
    for t in uv osascript python3 poetry rustup xcrun; do check "$t resolves to the stub" expect_stub "$t"; done
    for t in orb docker; do check "$t does not resolve" expect_absent "$t"; done
    check "du resolves under the system PATH" expect_system du
    check "nvm default npm is the stub" expect_nvm_stub npm
    check "nvm default pnpm is the stub" expect_nvm_stub pnpm
  fi
}

write_plist() {
  local p="$ROOT/$LABEL.plist" k
  {
    printf '<?xml version="1.0" encoding="UTF-8"?>\n'
    printf '<!DOCTYPE plist PUBLIC "-//Apple//DTD PLIST 1.0//EN" "http://www.apple.com/DTDs/PropertyList-1.0.dtd">\n'
    printf '<plist version="1.0">\n<dict>\n'
    printf '  <key>Label</key>\n  <string>%s</string>\n' "$(xml "$LABEL")"
    printf '  <key>ProgramArguments</key>\n  <array>\n'
    printf '    <string>/bin/bash</string>\n    <string>%s</string>\n    <string>%s</string>\n' \
      "$(xml "$TARGET_SCRIPT")" "$JOB_ARG"
    printf '  </array>\n  <key>RunAtLoad</key>\n  <false/>\n'
    [[ -n "$EXIT_TIMEOUT" ]] && printf '  <key>ExitTimeOut</key>\n  <integer>%s</integer>\n' "$EXIT_TIMEOUT"
    printf '  <key>EnvironmentVariables</key>\n  <dict>\n'
    for k in "HOME=$HOMEDIR" "PATH=$SYSTEM_PATH" "GITLEAKS_AUDIT_BASE_PATH=$BASE_PATH" \
      "CACHE_PRUNE_BASE_PATH=$BASE_PATH" "GITLEAKS_AUDIT_TIMEOUT=3600" "SHUTDOWN_FIXTURE=$FX"; do
      printf '    <key>%s</key>\n    <string>%s</string>\n' "${k%%=*}" "$(xml "${k#*=}")"
    done
    printf '  </dict>\n'
    printf '  <key>StandardOutPath</key>\n  <string>%s</string>\n' "$(xml "$ROOT/launchd.log")"
    printf '  <key>StandardErrorPath</key>\n  <string>%s</string>\n' "$(xml "$ROOT/launchd.log")"
    printf '  <key>ProcessType</key>\n  <string>Background</string>\n'
    printf '</dict>\n</plist>\n'
  } >"$p" || return 1
  /usr/bin/plutil -lint "$p" >/dev/null || return 1
  PLIST="$p"
}

# --- per-attempt observations --------------------------------------------------------

LOCK_PATH=""
STATE_SNAPSHOT=""
LOG_FILE=""
PRE_SNAP=""
PRE_LOG=0

snap_hash() {
  if [[ -f "$STATE_SNAPSHOT" ]]; then
    shasum -a 256 <"$STATE_SNAPSHOT" | cut -d' ' -f1
  else
    echo absent
  fi
}
log_size() { if [[ -f "$LOG_FILE" ]]; then wc -c <"$LOG_FILE" | tr -d ' '; else echo 0; fi; }
log_since() { [[ -f "$LOG_FILE" ]] && tail -c "+$(($1 + 1))" "$LOG_FILE"; }

start_attempt() { # <n> <hang|normal>
  echo
  echo "== attempt $1 ($2)"
  PRE_SNAP="$(snap_hash)"
  PRE_LOG="$(log_size)"
  printf '%s\n' "$1" >"$FX/attempt"
  if [[ "$2" == hang ]]; then : >"$FX/hang"; else rm -f "$FX/hang"; fi
  if ! "$LAUNCHCTL" kickstart "$SERVICE" >/dev/null 2>&1; then
    fail "launchctl kickstart $SERVICE (attempt $1)"
    finish
  fi
}

M_PID=""
M_PGID=""
M_CHILD=""
# wait_ready <n>: the fresh marker of attempt <n>, or a readiness failure.
wait_ready() {
  local n="$1" i=0 limit=$((READY_TIMEOUT * 10)) line f
  while [[ ! -s "$FX/marker.$n" ]]; do
    if [[ $i -ge $limit ]]; then
      fail "readiness timeout: attempt $n wrote no marker within ${READY_TIMEOUT}s"
      finish
    fi
    sleep 0.1
    i=$((i + 1))
  done
  line="$(cat "$FX/marker.$n" 2>/dev/null)"
  M_PID="" M_PGID="" M_CHILD=""
  local fix=""
  for f in $line; do
    case "$f" in
      pid=*) M_PID="${f#pid=}" ;;
      pgid=*) M_PGID="${f#pgid=}" ;;
      fixture=*) fix="${f#fixture=}" ;;
      child=*) M_CHILD="${f#child=}" ;;
    esac
  done
  if [[ "$fix" != "$n" || ! "$M_PID" =~ ^[0-9]+$ || ! "$M_PGID" =~ ^[0-9]+$ ]]; then
    fail "attempt $n marker is malformed: '$line'"
    finish
  fi
  if [[ "$M_PGID" -le 1 || "$M_PGID" == "$(/bin/ps -o pgid= -p $$ | tr -d ' ')" ]]; then
    fail "attempt $n runs in an unexpected process group ($M_PGID)"
    finish
  fi
  PGIDS="$PGIDS $M_PGID"
  pass "attempt $n is ready (stub pid $M_PID, process group $M_PGID)"
}

stub_alive() {
  local rc
  alive "$M_PID"
  rc=$?
  [[ $rc -eq 2 ]] && DETAIL="$PS_ERR" || DETAIL="pid $M_PID is gone"
  [[ $rc -eq 0 ]]
}
child_alive() {
  local rc
  DETAIL="descendant '${M_CHILD}' is gone"
  [[ "$M_CHILD" =~ ^[0-9]+$ ]] || return 1
  alive "$M_CHILD"
  rc=$?
  [[ $rc -eq 2 ]] && DETAIL="$PS_ERR"
  [[ $rc -eq 0 ]]
}

# job_identity: the launchd job's own pid and process group (the audit's
# watchdog and the script itself live there, outside the step's group).
JOB_PID=""
JOB_PGID=""
job_identity() {
  local out
  out="$("$LAUNCHCTL" print "$SERVICE" 2>/dev/null)"
  JOB_PID="$(sed -n 's/^[[:space:]]*pid = //p' <<<"$out" | head -n1)"
  DETAIL="launchctl print shows no running pid"
  [[ "$JOB_PID" =~ ^[1-9][0-9]*$ ]] || return 1
  JOB_PGID="$("$PS" -o pgid= -p "$JOB_PID" 2>/dev/null | tr -d ' ')"
  DETAIL="cannot observe the process group of job pid $JOB_PID"
  [[ "$JOB_PGID" =~ ^[0-9]+$ && "$JOB_PGID" -gt 1 && "$JOB_PGID" != "$(/bin/ps -o pgid= -p $$ | tr -d ' ')" ]] || return 1
  PGIDS="$PGIDS $JOB_PGID"
}

# group_empties <pgid>: true once no process is left in it, within
# STOP_TIMEOUT seconds of the stop REQUEST (STOP_START_MS, taken before the
# synchronous launchctl call). A failed observation is a failure.
STOP_START_MS=0
group_empties() {
  local pg="$1" left rc
  while :; do
    left="$(pgid_members "$pg")"
    rc=$?
    if [[ $rc -ne 0 ]]; then
      DETAIL="$left"
      return 1
    fi
    [[ -z "$left" ]] && return 0
    if [[ $(($(now_ms) - STOP_START_MS)) -ge $((STOP_TIMEOUT * 1000)) ]]; then
      DETAIL="still alive: $left"
      return 1
    fi
    sleep 0.1
  done
}

lock_released() {
  local pid="" rc
  [[ -e "$LOCK_PATH" || -L "$LOCK_PATH" ]] || return 0
  pid="$(sed -n 's/^pid=//p' "$LOCK_PATH/owner" 2>/dev/null)"
  DETAIL="$LOCK_PATH is still held (owner pid '${pid}')"
  [[ "$pid" =~ ^[1-9][0-9]*$ ]] || return 1
  alive "$pid"
  rc=$?
  if [[ $rc -eq 2 ]]; then
    DETAIL="$PS_ERR"
    return 1
  fi
  [[ $rc -eq 1 ]]
}

snapshot_not_advanced() {
  local now
  now="$(snap_hash)"
  DETAIL="snapshot $PRE_SNAP -> $now and no publishing marker"
  [[ "$now" == "$PRE_SNAP" || -e "$(dirname "$STATE_SNAPSHOT")/publishing" ]]
}

log_has_no_finished_ok() {
  DETAIL="this attempt's log segment says finished OK"
  ! log_since "$PRE_LOG" | grep -q 'finished OK'
}
log_has_finished_ok() {
  DETAIL="no 'finished OK' in this attempt's log segment"
  log_since "$PRE_LOG" | grep -q 'finished OK'
}

still_registered() { "$LAUNCHCTL" print "$SERVICE" >/dev/null 2>&1; }

after_stop_checks() { # <n> <how>
  check "no surviving processes in step process group $M_PGID within ${STOP_TIMEOUT}s of the $2 request" group_empties "$M_PGID"
  if [[ "$JOB_PGID" != "$M_PGID" ]]; then
    check "no surviving processes in job process group $JOB_PGID within ${STOP_TIMEOUT}s of the $2 request" group_empties "$JOB_PGID"
  fi
  check "lock released or reclaimable after $2" lock_released
  if [[ "$TARGET" == gitleaks-audit ]]; then
    check "repo snapshot not advanced (or publication unsettled) after $2" snapshot_not_advanced
  else
    check "attempt $1 log has no 'finished OK' after $2" log_has_no_finished_ok
  fi
}

# wait_done <n>: attempt <n> finished (launchd: not running, an exit code).
LAST_EXIT=""
run_finished() {
  local out i=0 limit=$((RUN_TIMEOUT * 5))
  while :; do
    out="$("$LAUNCHCTL" print "$SERVICE" 2>/dev/null)"
    if [[ "$out" != *"state = running"* ]]; then
      LAST_EXIT="$(sed -n 's/^[[:space:]]*last exit code = //p' <<<"$out" | head -n1)"
      [[ "$LAST_EXIT" =~ ^-?[0-9]+$ ]] && return 0
    fi
    if [[ $i -ge $limit ]]; then
      DETAIL="not finished within ${RUN_TIMEOUT}s"
      return 1
    fi
    sleep 0.2
    i=$((i + 1))
  done
}
exited_zero() {
  DETAIL="last exit code $LAST_EXIT"
  [[ "$LAST_EXIT" == 0 ]]
}

normal_run() { # <n>
  start_attempt "$1" normal
  wait_ready "$1"
  check "attempt $1 finished" run_finished
  check "attempt $1 exits 0" exited_zero
  [[ "$TARGET" == cache-prune ]] && check "attempt $1 logs finished OK" log_has_finished_ok
  gate
}

bootstrap() {
  if ! "$LAUNCHCTL" bootstrap "$DOMAIN" "$PLIST" >/dev/null 2>&1; then
    fail "launchctl bootstrap $DOMAIN $PLIST"
    finish
  fi
  BOOTSTRAPPED=1
}

real_unchanged() { # <agent>
  DETAIL="launchctl print output differs (see before/after)"
  cmp -s "$ROOT/real.before.$1" "$ROOT/real.after.$1"
}

# --- the exercise ------------------------------------------------------------------

# Refuse a label that exists, before anything is created.
if "$LAUNCHCTL" print "$SERVICE" >/dev/null 2>&1; then
  die "label $LABEL already exists in $DOMAIN; refusing (nothing was created or changed)"
fi
ROOT="$(mktemp -d "${TMPDIR:-/tmp}"/launchd-shutdown-check.XXXXXX)" || die "cannot create a temp dir"
ROOT="${ROOT%/}"
chmod 700 "$ROOT" || die "cannot chmod $ROOT"
HOMEDIR="$ROOT/home"
STUBDIR="$ROOT/stubs"
FX="$ROOT/fixture"
NVM_BIN="$HOMEDIR/.nvm/versions/node/v$NODE_VER/bin"
BASE_PATH="$STUBDIR:$SYSTEM_PATH"
LOCK_PATH="$HOMEDIR/Library/Caches/$LOCK_NAME"
STATE_SNAPSHOT="$HOMEDIR/Library/Application Support/gitleaks-audit/repos/$(printf '%s' "$FIXTURE_REPO" | shasum -a 256 | cut -c1-16)/snapshot"
LOG_FILE="$HOMEDIR/Library/Logs/cache-prune.log"
PLIST=""

echo "launchd-shutdown-check: target $TARGET, service $SERVICE, temp $ROOT"
capture_real before
build_stubs || die "cannot build the fixture under $ROOT"

echo
echo "== command resolution (PATH=$BASE_PATH)"
verify_resolution
gate

if [[ "$TARGET" == gitleaks-audit ]]; then
  mkdir -p "$HOMEDIR/code/$FIXTURE_REPO"
  if ! fixture_git init -q || ! fixture_git commit -q --no-verify --allow-empty -m init; then
    fail "fixture repo $HOMEDIR/code/$FIXTURE_REPO could not be created"
    finish
  fi
fi
write_plist || {
  fail "the throwaway plist does not lint"
  finish
}
bootstrap

# Stop (a): bootout while the stubbed step runs.
start_attempt 1 hang
wait_ready 1
check "attempt 1 stub is alive before the stop" stub_alive
check "attempt 1 descendant is alive before the stop" child_alive
check "attempt 1 job pid and process group observed" job_identity
gate
STOP_START_MS="$(now_ms)"
if "$LAUNCHCTL" bootout "$SERVICE" >/dev/null 2>&1; then
  BOOTSTRAPPED=0
  pass "launchctl bootout $SERVICE"
else
  fail "launchctl bootout $SERVICE"
fi
after_stop_checks 1 "bootout"
gate
bootstrap
normal_run 2

# Stop (b): kill TERM; the service stays registered.
[[ "$TARGET" == gitleaks-audit ]] && fixture_git commit -q --no-verify --allow-empty -m "attempt 3"
start_attempt 3 hang
wait_ready 3
check "attempt 3 stub is alive before the stop" stub_alive
check "attempt 3 descendant is alive before the stop" child_alive
check "attempt 3 job pid and process group observed" job_identity
gate
STOP_START_MS="$(now_ms)"
if "$LAUNCHCTL" kill TERM "$SERVICE" >/dev/null 2>&1; then
  pass "launchctl kill TERM $SERVICE"
else
  fail "launchctl kill TERM $SERVICE"
fi
after_stop_checks 3 "kill TERM"
check "service still registered after kill TERM" still_registered
gate
normal_run 4

echo
if "$LAUNCHCTL" bootout "$SERVICE" >/dev/null 2>&1; then
  BOOTSTRAPPED=0
  pass "final launchctl bootout $SERVICE"
else
  fail "final launchctl bootout $SERVICE"
fi
capture_real after
for agent in $REAL_AGENTS; do
  check "real agent $agent unchanged" real_unchanged "$agent"
done
finish
