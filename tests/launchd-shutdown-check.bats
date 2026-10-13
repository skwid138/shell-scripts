#!/usr/bin/env bats
bats_require_minimum_version 1.5.0
# Tests for agent/launchd-shutdown-check.sh, the opt-in manual exercise of
# launchd stopping a gitleaks-audit / cache-prune run.
#
# launchctl is a stub (LAUNCHD_CHECK_LAUNCHCTL) that simulates just enough
# of launchd for the harness: bootstrap registers the throwaway job,
# kickstart starts a simulated job in its own process group that runs the
# harness's own stub (gitleaks git / uv cache prune) after a short startup
# delay, bootout and kill TERM signal that group, and print reports the
# state and last exit code. ps is a recording wrapper around /bin/ps
# (LAUNCHD_CHECK_PS). Nothing here talks to the real launchd, and the real
# agents' `launchctl print` output is a fixture.
#
# macOS-only (launchctl/plutil semantics). Skipped elsewhere.

setup() {
  load 'test_helper/bats-support/load'
  load 'test_helper/bats-assert/load'

  [[ "$(uname -s)" == "Darwin" ]] || skip "launchd-shutdown-check is macOS-only"

  SCRIPT="$BATS_TEST_DIRNAME/../agent/launchd-shutdown-check.sh"
  T="$BATS_TEST_TMPDIR"
  FAKE_HOME="$T/home"
  STUBS="$T/stubs"
  SIM="$T/sim"
  TMPD="$T/tmp"
  CALLS="$T/calls.log"
  mkdir -p "$FAKE_HOME" "$STUBS" "$SIM" "$TMPD"
  : >"$CALLS"
  MYUID="$(id -u)"
  printf 'gui/%s/com.skwid138.gitleaks-audit = {\n\tstate = not running\n}\n' "$MYUID" >"$SIM/real.com.skwid138.gitleaks-audit"
  printf 'gui/%s/com.skwid138.cache-prune = {\n\tstate = not running\n}\n' "$MYUID" >"$SIM/real.com.skwid138.cache-prune"
  write_stubs
}

teardown() {
  # Nothing to clean when setup skipped (off macOS) before TMPD was set: an
  # empty TMPD would turn the pkill pattern into one that matches this very
  # bats run (its argv names tests/launchd-shutdown-check.bats).
  [[ -n "${TMPD:-}" && "$TMPD" == "$BATS_TEST_TMPDIR"/* ]] || return 0
  # Never leave a simulated job behind (they live in their own groups).
  local pg
  for pg in "$SIM"/pgid.*; do
    [[ -f "$pg" ]] && kill -KILL -- "-$(cat "$pg")" 2>/dev/null
  done
  pkill -KILL -f "$TMPD/launchd-shutdown-check" 2>/dev/null
  return 0
}

write_stubs() {
  # The simulated job: what launchd would run, reduced to the stubbed step
  # the harness waits on (the harness's own gitleaks / uv stub, with the
  # plist's environment).
  cat >"$STUBS/simjob" <<'EOF'
#!/bin/bash
plist="$(cat "$SIM/plist.path")"
get() { /usr/bin/plutil -extract "$1" raw -o - "$plist"; }
export HOME SHUTDOWN_FIXTURE
HOME="$(get EnvironmentVariables.HOME)"
SHUTDOWN_FIXTURE="$(get EnvironmentVariables.SHUTDOWN_FIXTURE)"
stubs="${SHUTDOWN_FIXTURE%/fixture}/stubs"
if [[ -f "$SIM/no_marker" ]]; then
  sleep 600
  exit 0
fi
sleep 0.4
arg="$(get ProgramArguments.2)"
hang=0
[[ -e "$SHUTDOWN_FIXTURE/hang" ]] && hang=1
if [[ $hang -eq 1 ]]; then
  if [[ -f "$SIM/lock_owner" ]]; then
    case "$arg" in --run) lk=gitleaks-audit.lock ;; *) lk=cache-prune.lock ;; esac
    mkdir -p "$HOME/Library/Caches/$lk"
    echo "pid=$(cat "$SIM/lock_owner")" >"$HOME/Library/Caches/$lk/owner"
  fi
  if [[ -f "$SIM/snapshot_advance" ]]; then
    sd="$HOME/Library/Application Support/gitleaks-audit/repos/$(printf '%s' shutdowntest-repo | shasum -a 256 | cut -c1-16)"
    mkdir -p "$sd"
    echo "advanced $RANDOM" >"$sd/snapshot"
  fi
  # A watchdog-like process in the job's group, outside the step's group.
  if [[ -f "$SIM/job_survivor" ]]; then
    (trap "" TERM; exec "$stubs/shutdowntest-sleep" 600) </dev/null >/dev/null 2>&1 &
  fi
fi
case "$arg" in
  --run)
    # Like the audit's run_group: the step gets its own process group.
    /usr/bin/perl -e 'setpgrp(0, 0) or die; exec @ARGV or die' \
      "$stubs/gitleaks" git --report-path="$HOME/report.json" . &
    sp=$!
    echo "$sp" >"$SIM/step"
    echo "$sp" >"$SIM/pgid.$sp"
    wait "$sp"
    rc=$?
    ;;
  --apply)
    "$stubs/uv" cache prune
    rc=$?
    if [[ $rc -eq 0 ]]; then
      mkdir -p "$HOME/Library/Logs"
      echo "[t] cache-prune apply finished OK" >>"$HOME/Library/Logs/cache-prune.log"
    fi
    ;;
  *) rc=78 ;;
esac
echo "$rc" >"$SIM/last_exit"
rm -f "$SIM/running"
exit "$rc"
EOF
  cat >"$STUBS/launchctl" <<'EOF'
#!/bin/bash
printf 'launchctl %s\n' "$*" >>"$CALLS"
stop_job() {
  local pg sp=""
  [[ -f "$SIM/running" ]] || return 0
  pg="$(cat "$SIM/running")"
  [[ -f "$SIM/step" ]] && sp="$(cat "$SIM/step")"
  # A slow stop: the request itself takes 2s, and the step's group only
  # empties 2s after that.
  [[ -f "$SIM/slow_stop" ]] && sleep 2
  if [[ -f "$SIM/slow_stop_empty" ]]; then
    # Over budget inside the synchronous call, but everything is gone by
    # the time it returns.
    kill -KILL -- "-$pg" 2>/dev/null
    [[ -n "$sp" ]] && kill -KILL -- "-$sp" 2>/dev/null
    sleep 4
    echo 143 >"$SIM/last_exit"
    rm -f "$SIM/running" "$SIM/step"
    return 0
  fi
  kill -TERM -- "-$pg" 2>/dev/null
  [[ -n "$sp" ]] && kill -TERM -- "-$sp" 2>/dev/null
  sleep 0.3
  if [[ ! -f "$SIM/survive" && -n "$sp" ]]; then
    if [[ -f "$SIM/slow_stop" ]]; then
      (sleep 2; kill -KILL -- "-$sp") </dev/null >/dev/null 2>&1 &
    else
      kill -KILL -- "-$sp" 2>/dev/null
    fi
  fi
  [[ -f "$SIM/survive" || -f "$SIM/job_survivor" ]] || kill -KILL -- "-$pg" 2>/dev/null
  echo 143 >"$SIM/last_exit"
  rm -f "$SIM/running" "$SIM/step"
}
sub="${1-}"
shift
case "$sub" in
  print)
    case "${1-}" in
      */com.skwid138.cache-prune | */com.skwid138.gitleaks-audit)
        name="${1##*/}"
        n=$(($(cat "$SIM/prints.$name" 2>/dev/null || echo 0) + 1))
        echo "$n" >"$SIM/prints.$name"
        [[ -f "$SIM/real.$name" ]] || exit 113
        cat "$SIM/real.$name"
        [[ -f "$SIM/real_changes" && $n -ge 2 ]] && echo "	runs = 1"
        exit 0
        ;;
      */com.skwid138.shutdowntest.*)
        if [[ -f "$SIM/preexisting" ]]; then
          echo "${1} = {"
          exit 0
        fi
        [[ -f "$SIM/registered" ]] || exit 113
        state="not running"
        [[ -f "$SIM/running" ]] && state=running
        echo "${1} = {"
        echo "	state = $state"
        if [[ -f "$SIM/running" ]]; then
          if [[ -f "$SIM/print_no_pid" ]]; then
            :
          elif [[ -f "$SIM/print_bad_pid" ]]; then
            echo "	pid = 12x"
          else
            echo "	pid = $(cat "$SIM/running")"
          fi
          [[ -f "$SIM/print_rc_running" ]] && {
            echo "}"
            exit 5
          }
        fi
        echo "	last exit code = $(cat "$SIM/last_exit" 2>/dev/null || echo '(never exited)')"
        echo "}"
        exit 0
        ;;
    esac
    exit 113
    ;;
  bootstrap)
    cp "$2" "$SIM/plist.copy.$(ls "$SIM" | grep -c '^plist.copy')"
    echo "$2" >"$SIM/plist.path"
    touch "$SIM/registered"
    rm -f "$SIM/last_exit"
    exit 0
    ;;
  kickstart)
    [[ -f "$SIM/registered" ]] || exit 113
    [[ -f "$SIM/running" ]] && exit 0
    rm -f "$SIM/last_exit"
    /usr/bin/perl -e 'setpgrp(0, 0) or die; exec @ARGV or die' "$STUBS/simjob" </dev/null >/dev/null 2>&1 3>&- &
    echo "$!" >"$SIM/running"
    echo "$!" >"$SIM/pgid.$!"
    exit 0
    ;;
  bootout)
    [[ -f "$SIM/registered" ]] || exit 113
    rm -f "$SIM/registered"
    stop_job
    exit 0
    ;;
  kill)
    [[ -f "$SIM/registered" ]] || exit 113
    stop_job
    exit 0
    ;;
esac
exit 64
EOF
  cat >"$STUBS/ps" <<'EOF'
#!/bin/bash
printf 'ps %s\n' "$*" >>"$CALLS"
if [[ -f "$SIM/ps_error_axo" && "$*" == *-axo* ]]; then
  echo "ps: simulated failure" >&2
  exit 1
fi
if [[ -f "$SIM/ps_pgid_rc" && "$*" == "-o pgid= -p "* ]]; then
  /bin/ps "$@"
  exit 1
fi
if [[ -f "$SIM/ps_error_pid" && "$*" == *"-p $(cat "$SIM/ps_error_pid")"* ]]; then
  echo "ps: simulated failure" >&2
  exit 1
fi
exec /bin/ps "$@"
EOF
  chmod +x "$STUBS/simjob" "$STUBS/launchctl" "$STUBS/ps"
}

# run_check [VAR=val...] -- [args...]: the harness under env -i with the
# stubs, short timeouts, and TMPDIR inside the test dir.
run_check() {
  local -a envs=()
  while [[ $# -gt 0 && "$1" != "--" ]]; do
    envs+=("$1")
    shift
  done
  shift
  run --separate-stderr env -i HOME="$FAKE_HOME" TMPDIR="$TMPD" CALLS="$CALLS" SIM="$SIM" STUBS="$STUBS" \
    PATH=/usr/bin:/bin:/usr/sbin:/sbin \
    LAUNCHD_CHECK_LAUNCHCTL="$STUBS/launchctl" LAUNCHD_CHECK_PS="$STUBS/ps" \
    LAUNCHD_CHECK_READY_TIMEOUT=6 LAUNCHD_CHECK_STOP_TIMEOUT=3 LAUNCHD_CHECK_RUN_TIMEOUT=10 \
    ${envs[@]+"${envs[@]}"} /bin/bash "$SCRIPT" "$@" </dev/null 3>&-
}

lc_calls() { grep '^launchctl ' "$CALLS" || true; }
plist_get() { /usr/bin/plutil -extract "$2" "${3:-raw}" -o - "$SIM/plist.copy.$1"; }
roots_left() { find "$TMPD" -maxdepth 1 -name 'launchd-shutdown-check.*' ! -name '*.keep' 2>/dev/null; }

# assert_exact_targets: every service-level call names the one throwaway
# service gui/<uid>/com.skwid138.shutdowntest.<n> exactly; bootstrap names
# the domain plus a plist; the real agents are only ever printed.
assert_exact_targets() {
  local line svc="" re="^gui/$MYUID/com\\.skwid138\\.shutdowntest\\.[0-9]+$"
  while IFS= read -r line; do
    # shellcheck disable=SC2086 # split the recorded argv into words
    set -- $line
    case "$2" in
      bootout | kickstart)
        [[ $# -eq 3 && "$3" =~ $re ]] || {
          echo "not an exact service target: $line" >&2
          return 1
        }
        ;;
      kill)
        [[ $# -eq 4 && "$3" == TERM && "$4" =~ $re ]] || {
          echo "not an exact kill target: $line" >&2
          return 1
        }
        ;;
      bootstrap)
        [[ $# -eq 4 && "$3" == "gui/$MYUID" && "$4" == /*.plist ]] || {
          echo "unexpected bootstrap: $line" >&2
          return 1
        }
        ;;
      print)
        [[ $# -eq 3 ]] || return 1
        ;;
      *)
        echo "unexpected launchctl call: $line" >&2
        return 1
        ;;
    esac
    case "$2" in
      bootout | kickstart | kill)
        local s="${!#}"
        [[ -z "$svc" || "$s" == "$svc" ]] || {
          echo "more than one throwaway service: $svc vs $s" >&2
          return 1
        }
        svc="$s"
        ;;
    esac
  done < <(lc_calls)
  # Never a domain-only bootout, and never anything but print for the real agents.
  if grep -qE "^launchctl bootout gui/$MYUID/?\$" "$CALLS"; then
    echo "domain-only bootout" >&2
    return 1
  fi
  if grep -E 'com\.skwid138\.(cache-prune|gitleaks-audit)' "$CALLS" | grep -qv '^launchctl print '; then
    echo "a real agent was touched beyond print" >&2
    return 1
  fi
}

# --- help / usage ----------------------------------------------------------------

@test "launchd-shutdown-check: --help exits 0 and documents the manual opt-in run" {
  run_check -- --help
  assert_success
  assert_output --partial "--target"
  assert_output --partial "--run"
  assert_output --partial "manual"
  assert_output --partial "launchctl bootout gui/<uid>/<label>"
  assert_output --partial "launchctl kill TERM"
  [[ ! -s "$CALLS" ]]
}

@test "launchd-shutdown-check: without --run it only describes the exercise (no launchctl calls)" {
  run_check -- --target gitleaks-audit
  assert_success
  assert_output --partial "--run"
  [[ ! -s "$CALLS" ]]
  [[ -z "$(roots_left)" ]]
}

@test "launchd-shutdown-check: usage errors (no target, unknown target, unknown argument)" {
  run_check -- --run
  assert_failure 2
  run_check -- --target other --run
  assert_failure 2
  run_check -- --target cache-prune --bogus
  assert_failure 2
  [[ ! -s "$CALLS" ]]
}

# --- safety ----------------------------------------------------------------------

@test "launchd-shutdown-check: a pre-existing label is refused before anything is created" {
  touch "$SIM/preexisting"
  run_check -- --target gitleaks-audit --run
  assert_failure 1
  grep -q "already exists" <<<"$output$stderr"
  run lc_calls
  assert_output --regexp "^launchctl print gui/$MYUID/com\.skwid138\.shutdowntest\.[0-9]+$"
  [[ "${#lines[@]}" -eq 1 ]]
  [[ -z "$(roots_left)" ]]
}

@test "launchd-shutdown-check: gitleaks-audit exercise passes with exact service targets and a production-like plist" {
  run_check -- --target gitleaks-audit --run
  assert_success
  assert_output --partial "result: PASS"
  refute_output --partial "FAIL"
  assert_exact_targets
  # Both stops ran: bootout + re-bootstrap, then kill TERM + kickstart.
  [[ "$(grep -c '^launchctl bootstrap ' "$CALLS")" -eq 2 ]]
  [[ "$(grep -c '^launchctl kickstart ' "$CALLS")" -eq 4 ]]
  [[ "$(grep -c '^launchctl kill TERM ' "$CALLS")" -eq 1 ]]
  [[ "$(grep -c '^launchctl bootout ' "$CALLS")" -eq 2 ]]
  # The throwaway plist.
  local h
  h="$(plist_get 0 EnvironmentVariables.HOME)"
  [[ "$h" == "$TMPD"/launchd-shutdown-check.*/home ]]
  [[ "$(plist_get 0 EnvironmentVariables.GITLEAKS_AUDIT_BASE_PATH)" == "${h%/home}/stubs:/usr/bin:/bin:/usr/sbin:/sbin" ]]
  [[ "$(plist_get 0 EnvironmentVariables.CACHE_PRUNE_BASE_PATH)" == "${h%/home}/stubs:/usr/bin:/bin:/usr/sbin:/sbin" ]]
  [[ "$(plist_get 0 EnvironmentVariables.GITLEAKS_AUDIT_TIMEOUT)" -ge 3600 ]]
  [[ "$(plist_get 0 ExitTimeOut)" == 30 ]]
  [[ "$(plist_get 0 ProgramArguments.1)" == */personal/gitleaks-audit.sh ]]
  [[ "$(plist_get 0 ProgramArguments.2)" == --run ]]
  [[ "$(plist_get 0 RunAtLoad)" == false ]]
  # The real agents were captured before and after.
  [[ "$(cat "$SIM/prints.com.skwid138.gitleaks-audit")" -eq 2 && "$(cat "$SIM/prints.com.skwid138.cache-prune")" -eq 2 ]]
  [[ -z "$(roots_left)" ]]
}

@test "launchd-shutdown-check: cache-prune exercise passes; its plist mirrors production (no ExitTimeOut)" {
  run_check -- --target cache-prune --run
  assert_success
  assert_output --partial "result: PASS"
  assert_output --partial "finished OK"
  assert_exact_targets
  run plist_get 0 ExitTimeOut
  assert_failure
  [[ "$(plist_get 0 ProgramArguments.2)" == --apply ]]
  local h
  h="$(plist_get 0 EnvironmentVariables.HOME)"
  [[ "$(plist_get 0 EnvironmentVariables.CACHE_PRUNE_BASE_PATH)" == "${h%/home}/stubs:/usr/bin:/bin:/usr/sbin:/sbin" ]]
  [[ -z "$(roots_left)" ]]
}

@test "launchd-shutdown-check: command resolution is verified explicitly before bootstrap" {
  run_check -- --target gitleaks-audit --run
  assert_success
  assert_output --partial "PASS: gitleaks resolves to the stub"
  assert_output --partial "PASS: git resolves under the system PATH"
  run_check -- --target cache-prune --run
  assert_success
  assert_output --partial "PASS: uv resolves to the stub"
  assert_output --partial "PASS: nvm default npm is the stub"
  assert_output --partial "PASS: nvm default pnpm is the stub"
  assert_output --partial "PASS: orb does not resolve"
  # A system PATH that would let OrbStack's orb in fails before bootstrap.
  mkdir -p "$T/sysbin"
  printf '#!/bin/bash\nexit 0\n' >"$T/sysbin/orb"
  chmod +x "$T/sysbin/orb"
  : >"$CALLS"
  run_check LAUNCHD_CHECK_SYSTEM_PATH="$T/sysbin:/usr/bin:/bin:/usr/sbin:/sbin" -- --target cache-prune --run
  assert_failure 1
  assert_output --partial "FAIL: orb does not resolve"
  run grep -c '^launchctl bootstrap' "$CALLS"
  assert_output "0"
  # A system PATH without git/jq fails the audit target the same way.
  mkdir -p "$T/empty"
  : >"$CALLS"
  run_check LAUNCHD_CHECK_SYSTEM_PATH="$T/empty" -- --target gitleaks-audit --run
  assert_failure 1
  assert_output --partial "FAIL: git resolves under the system PATH"
  run grep -c '^launchctl bootstrap' "$CALLS"
  assert_output "0"
  [[ -z "$(roots_left)" ]]
}

@test "launchd-shutdown-check: a readiness timeout is a failure (and the service is booted out by its exact name)" {
  touch "$SIM/no_marker"
  run_check -- --target gitleaks-audit --run
  assert_failure 1
  assert_output --partial "FAIL: readiness timeout"
  refute_output --partial "result: PASS"
  run grep '^launchctl bootout ' "$CALLS"
  assert_output --regexp "^launchctl bootout gui/$MYUID/com\.skwid138\.shutdowntest\.[0-9]+$"
  assert_exact_targets
  [[ -z "$(roots_left)" ]]
}

@test "launchd-shutdown-check: assertions run before rescue cleanup (a survivor is reported, then killed)" {
  touch "$SIM/survive"
  run_check -- --target gitleaks-audit --run
  assert_failure 1
  local fail_at rescue_at
  fail_at="$(grep -n '^FAIL: no surviving processes' <<<"$output" | head -n1 | cut -d: -f1)"
  rescue_at="$(grep -n '^rescue: killing' <<<"$output" | head -n1 | cut -d: -f1)"
  [[ -n "$fail_at" && -n "$rescue_at" && "$fail_at" -lt "$rescue_at" ]]
  # ...and afterwards nothing of this run survives.
  run pgrep -f "$TMPD/launchd-shutdown-check"
  assert_failure
  assert_exact_targets
  [[ -z "$(roots_left)" ]]
}

@test "launchd-shutdown-check: the trap removes only this run's artifacts" {
  mkdir -p "$TMPD/launchd-shutdown-check.keep" "$FAKE_HOME/Library/LaunchAgents"
  printf 'x\n' >"$TMPD/launchd-shutdown-check.keep/file"
  printf '<plist/>\n' >"$FAKE_HOME/Library/LaunchAgents/com.skwid138.gitleaks-audit.plist"
  printf 'other\n' >"$TMPD/unrelated"
  run_check -- --target cache-prune --run
  assert_success
  touch "$SIM/no_marker"
  run_check -- --target gitleaks-audit --run
  assert_failure 1
  [[ -f "$TMPD/launchd-shutdown-check.keep/file" && -f "$TMPD/unrelated" ]]
  [[ -f "$FAKE_HOME/Library/LaunchAgents/com.skwid138.gitleaks-audit.plist" ]]
  [[ -z "$(roots_left)" ]]
}

@test "launchd-shutdown-check: a change in the real agents' launchctl print output is a failure" {
  touch "$SIM/real_changes"
  run_check -- --target cache-prune --run
  assert_failure 1
  assert_output --partial "FAIL: real agent com.skwid138.cache-prune unchanged"
}

@test "launchd-shutdown-check: every bootout/kill/kickstart in the source targets the exact service" {
  run grep -nE '"\$LAUNCHCTL" (bootout|kill|kickstart)' "$SCRIPT"
  assert_success
  local line
  while IFS= read -r line; do
    [[ "$line" == *'"$SERVICE"'* ]] || {
      echo "not the exact service: $line" >&2
      return 1
    }
  done <<<"$output"
  run grep -nE 'bootout +"?\$DOMAIN"?( |$)|bootout +gui/[^/]*$' "$SCRIPT"
  assert_failure
}

# --- observation errors and the remaining oracles ----------------------------

@test "launchd-shutdown-check: a ps failure while listing process groups is a FAIL, never an empty group" {
  touch "$SIM/ps_error_axo"
  run_check -- --target gitleaks-audit --run
  assert_failure 1
  assert_output --regexp "FAIL: no surviving processes in (job|step) process group [0-9]+ .*cannot observe"
  refute_output --partial "PASS: no surviving processes"
  refute_output --partial "result: PASS"
}

@test "launchd-shutdown-check: a ps failure while checking the lock owner is a FAIL, never reclaimable" {
  sleep 300 &
  local holder=$!
  echo "$holder" >"$SIM/lock_owner"
  echo "$holder" >"$SIM/ps_error_pid"
  run_check -- --target cache-prune --run
  kill "$holder" 2>/dev/null
  assert_failure 1
  assert_output --regexp "FAIL: lock released or reclaimable after bootout: .*cannot observe"
}

@test "launchd-shutdown-check: a lock left with a live owner fails the lock check" {
  sleep 300 &
  local holder=$!
  echo "$holder" >"$SIM/lock_owner"
  run_check -- --target gitleaks-audit --run
  kill "$holder" 2>/dev/null
  assert_failure 1
  assert_output --partial "FAIL: lock released or reclaimable after bootout"
}

@test "launchd-shutdown-check: an advanced repo snapshot fails the publication check" {
  touch "$SIM/snapshot_advance"
  run_check -- --target gitleaks-audit --run
  assert_failure 1
  assert_output --partial "FAIL: repo snapshot not advanced (or publication unsettled) after bootout"
}

@test "launchd-shutdown-check: a watchdog-like survivor in the job's group (outside the step's group) fails" {
  touch "$SIM/job_survivor"
  run_check -- --target gitleaks-audit --run
  assert_failure 1
  assert_output --partial "PASS: no surviving processes in step process group"
  assert_output --regexp "FAIL: no surviving processes in job process group [0-9]+ "
  run pgrep -f "$TMPD/launchd-shutdown-check"
  assert_failure
}

@test "launchd-shutdown-check: the stop deadline counts from the request (a slow synchronous bootout uses it up)" {
  touch "$SIM/slow_stop"
  run_check -- --target gitleaks-audit --run
  assert_failure 1
  assert_output --regexp "FAIL: no surviving processes in step process group [0-9]+ within 3s of the bootout request"
}

@test "launchd-shutdown-check: a stop request that overruns the budget fails even if the groups are empty when it returns" {
  touch "$SIM/slow_stop_empty"
  run_check -- --target gitleaks-audit --run
  assert_failure 1
  assert_output --regexp "FAIL: no surviving processes in step process group [0-9]+ within 3s of the bootout request: .*after [0-9]+ms"
  refute_output --partial "PASS: no surviving processes in step process group"
}

# fails_before_stop: the job-identity check failed and no stop request
# (bootout/kill) was issued before it; only the trap's rescue bootout.
fails_before_stop() {
  assert_failure 1
  assert_output --regexp "FAIL: attempt 1 job pid and process group observed: $1"
  refute_output --partial "PASS: launchctl bootout"
  run grep -c '^launchctl kill ' "$CALLS"
  assert_output "0"
  run grep -c '^launchctl bootout ' "$CALLS"
  assert_output "1"
}

@test "launchd-shutdown-check: a missing or malformed job pid in launchctl print fails before any stop request" {
  touch "$SIM/print_no_pid"
  run_check -- --target gitleaks-audit --run
  fails_before_stop ".*no running pid"
  rm "$SIM/print_no_pid"
  touch "$SIM/print_bad_pid"
  : >"$CALLS"
  run_check -- --target gitleaks-audit --run
  fails_before_stop ".*no running pid"
}

@test "launchd-shutdown-check: a failing launchctl print or ps fails the job identity even with parseable output" {
  touch "$SIM/print_rc_running"
  run_check -- --target gitleaks-audit --run
  fails_before_stop "launchctl print .* failed \\(exit 5\\)"
  rm "$SIM/print_rc_running"
  touch "$SIM/ps_pgid_rc"
  : >"$CALLS"
  run_check -- --target gitleaks-audit --run
  fails_before_stop "cannot observe the process group of job pid [0-9]+ \\(ps exit 1"
}
