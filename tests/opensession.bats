#!/usr/bin/env bats
bats_require_minimum_version 1.5.0
# CLI tests for personal/opensession.sh
#
# opensession is a thin orchestrator over openweb + openattach. Tests stub
# both sibling wrappers (via OPENSESSION_OPENWEB_BIN / OPENSESSION_OPENATTACH_BIN)
# and the system tools the shared helper uses (lsof, ps, pgrep). Calls are
# logged to $STATEFILE for assertion. The real lib/opencode-daemon.sh is
# sourced — we test the integrated behavior, not a mocked helper.

setup() {
  load 'test_helper/bats-support/load'
  load 'test_helper/bats-assert/load'
  SCRIPT="$BATS_TEST_DIRNAME/../personal/opensession.sh"

  STUBDIR="$(mktemp -d)"
  STATEFILE="$STUBDIR/calls.log"
  : >"$STATEFILE"
  # Keep coreutils available; prepend stub dir so our stubs win.
  export PATH="$STUBDIR:$PATH"
  export STATEFILE

  # Pin sidecar + config locations so we never touch the user's real
  # ~/.local/share/opencode or read the live config.
  export OPENCODE_CONFIG_DIR="$STUBDIR/config"
  export OPENCODE_DAEMON_STATE_DIR="$STUBDIR/state"
  mkdir -p "$OPENCODE_CONFIG_DIR" "$OPENCODE_DAEMON_STATE_DIR"
  echo '{}' >"$OPENCODE_CONFIG_DIR/opencode.json"

  # Test-only injection point for the sibling wrappers.
  export OPENSESSION_OPENWEB_BIN="$STUBDIR/opencode-web.sh"
  export OPENSESSION_OPENATTACH_BIN="$STUBDIR/opencode-attach.sh"
}

teardown() {
  [[ -d "$STUBDIR" ]] && rm -rf "$STUBDIR"
}

# --- stub factories ---------------------------------------------------------

# openweb stub. Logs the invocation and the exit code env var. Tests that
# need to simulate failure set OPENWEB_EXIT=1 (etc.) before invoking SCRIPT.
write_openweb_stub() {
  cat >"$STUBDIR/opencode-web.sh" <<'EOF'
#!/usr/bin/env bash
echo "openweb $*" >>"$STATEFILE"
exit "${OPENWEB_EXIT:-0}"
EOF
  chmod +x "$STUBDIR/opencode-web.sh"
}

# openattach stub. Because opensession `exec`s into it, this stub is the
# tail of the wrapper's process tree — its exit code becomes the test's
# exit code. Logs argv so tests can assert pass-through.
write_openattach_stub() {
  cat >"$STUBDIR/opencode-attach.sh" <<'EOF'
#!/usr/bin/env bash
echo "openattach $*" >>"$STATEFILE"
exit "${OPENATTACH_EXIT:-0}"
EOF
  chmod +x "$STUBDIR/opencode-attach.sh"
}

# openweb stub for the listener/sidecar race: the lsof stub reports the
# listener as bound before this stub writes the sidecar, matching real openweb's
# ordering. Tests pair it with write_sidecar_asserting_openattach_stub.
write_delayed_sidecar_openweb_stub() {
  cat >"$STUBDIR/opencode-web.sh" <<'EOF'
#!/usr/bin/env bash
echo "openweb $*" >>"$STATEFILE"
port="${OPENCODE_WEB_PORT:-4096}"
pid="${DELAYED_SIDECAR_PID:-99999}"
sidecar="$OPENCODE_DAEMON_STATE_DIR/daemon-config-hash-${port}-${pid}"
sleep "${DELAYED_SIDECAR_SLEEP:-1}"
mkdir -p "$(dirname "$sidecar")"
printf '%s\n' "0000000000000000000000000000000000000000000000000000000000000000" >"$sidecar"
echo "sidecar-written $sidecar" >>"$STATEFILE"
exit "${OPENWEB_EXIT:-0}"
EOF
  chmod +x "$STUBDIR/opencode-web.sh"
}

# openattach stub that makes the race observable through public behavior:
# attaching before the sidecar exists exits non-zero; attaching after it exists
# succeeds and logs the normal openattach invocation.
write_sidecar_asserting_openattach_stub() {
  cat >"$STUBDIR/opencode-attach.sh" <<'EOF'
#!/usr/bin/env bash
port="${OPENCODE_WEB_PORT:-4096}"
pid="${DELAYED_SIDECAR_PID:-99999}"
sidecar="$OPENCODE_DAEMON_STATE_DIR/daemon-config-hash-${port}-${pid}"
if [[ ! -f "$sidecar" ]]; then
  echo "openattach-sidecar missing" >>"$STATEFILE"
  echo "sidecar missing before openattach: $sidecar" >&2
  exit 42
fi
echo "openattach-sidecar present" >>"$STATEFILE"
echo "openattach $*" >>"$STATEFILE"
exit "${OPENATTACH_EXIT:-0}"
EOF
  chmod +x "$STUBDIR/opencode-attach.sh"
}

# lsof stub: 3-phase model lifted from tests/opencode-web.bats. opensession
# uses lsof transitively via opencode_daemon_pid_for_port,
# opencode_port_listener_pid, and opencode_wait_for_opencode_listener.
write_lsof_stub() {
  cat >"$STUBDIR/lsof" <<'EOF'
#!/usr/bin/env bash
echo "lsof $*" >>"$STATEFILE"
port=""
for arg in "$@"; do
  case "$arg" in
    tcp:*) port="${arg#tcp:}" ;;
  esac
done
COUNTER_FILE="$(dirname "$0")/lsof-count"
counter=$(cat "$COUNTER_FILE" 2>/dev/null || echo 0)
counter=$((counter + 1))
echo "$counter" >"$COUNTER_FILE"
phase_free_after=$(cat "$(dirname "$0")/lsof-phase-after" 2>/dev/null || echo 999999)
phase_bound_after=$(cat "$(dirname "$0")/lsof-phase-bound-after" 2>/dev/null || echo "$phase_free_after")
state="$(dirname "$0")/lsof-state"
if (( counter > phase_bound_after )); then
  state="$(dirname "$0")/lsof-state-after"
elif (( counter > phase_free_after )); then
  state="$(dirname "$0")/lsof-state-free"
fi
if [[ -n "$port" && -r "$state" ]]; then
  awk -F '\t' -v p="$port" '$1==p {print $2; found=1} END {exit !found}' \
    "$state" && exit 0
fi
exit 1
EOF
  chmod +x "$STUBDIR/lsof"
}

set_lsof_port() {
  printf '%s\t%s\n' "$1" "$2" >>"$STUBDIR/lsof-state"
}
set_lsof_port_after() {
  printf '%s\t%s\n' "$1" "$2" >>"$STUBDIR/lsof-state-after"
}
set_lsof_phase_after() {
  printf '%s\n' "$1" >"$STUBDIR/lsof-phase-after"
  printf '%s\n' "$1" >"$STUBDIR/lsof-phase-bound-after"
}

# ps stub: drives pid → comm. Falls through to /bin/ps for unrelated shapes.
write_ps_stub() {
  cat >"$STUBDIR/ps" <<'EOF'
#!/usr/bin/env bash
echo "ps $*" >>"$STATEFILE"
if [[ "$1" == "-o" && "$2" == "comm=" && "$3" == "-p" ]]; then
  pid="$4"
  if [[ -r "$(dirname "$0")/ps-comm-map" ]]; then
    awk -F '\t' -v p="$pid" '$1==p {print $2; found=1} END {exit !found}' \
      "$(dirname "$0")/ps-comm-map" && exit 0
  fi
  exit 1
fi
exec /bin/ps "$@"
EOF
  chmod +x "$STUBDIR/ps"
}

set_ps_comm() {
  printf '%s\t%s\n' "$1" "$2" >>"$STUBDIR/ps-comm-map"
}

# Pgrep stub: not consulted directly but `require_cmd pgrep` runs at helper
# source-time. Passthrough.
write_pgrep_stub() {
  cat >"$STUBDIR/pgrep" <<'EOF'
#!/usr/bin/env bash
exec /usr/bin/pgrep "$@"
EOF
  chmod +x "$STUBDIR/pgrep"
}

write_all_stubs() {
  write_openweb_stub
  write_openattach_stub
  write_lsof_stub
  write_ps_stub
  write_pgrep_stub
}

# Convenience: model the various daemon states for the default decision tree.

# No daemon, port free. lsof returns empty (no state file rows).
arm_no_daemon() {
  : # state files unwritten → lsof exits 1 → port treated as free.
}

# Fresh daemon at $port (pid 99999) — opencode_daemon_pid_for_port returns 99999.
# A matching sidecar with the CURRENT config hash is written so a subsequent
# staleness check would be false. (opensession doesn't run that check itself,
# but tests that drive openattach can use it.)
arm_fresh_daemon() {
  local port="${OPENCODE_WEB_PORT:-4096}"
  local pid=99999
  set_lsof_port "$port" "$pid"
  set_ps_comm "$pid" "/opt/homebrew/bin/opencode"
  # Sidecar with current hash. We compute it via the real helper.
  local hash
  hash="$(
    # shellcheck source=/dev/null
    source "$BATS_TEST_DIRNAME/../lib/opencode-daemon.sh"
    opencode_config_content_hash
  )"
  printf '%s\n' "$hash" >"$OPENCODE_DAEMON_STATE_DIR/daemon-config-hash-${port}-${pid}"
}

# Port held by a NON-opencode process (pid 88888, comm caffeinate).
arm_foreign_listener() {
  local port="${OPENCODE_WEB_PORT:-4096}"
  set_lsof_port "$port" "88888"
  set_ps_comm "88888" "/usr/bin/caffeinate"
}

# Model the spawn-and-wait sequence: lsof first reports port free (pre-check),
# then after PHASE_AFTER calls reports the (fake) daemon bound at pid 99999.
arm_spawn_succeeds() {
  local port="${OPENCODE_WEB_PORT:-4096}"
  local fake_pid=99999
  # opensession's pre-spawn check: 2 lsof calls (opencode_daemon_pid_for_port +
  # opencode_port_listener_pid). After that, opencode_wait_for_opencode_listener
  # polls until lsof returns a pid; phase_after=2 means call #3 onward sees
  # the listener bound.
  set_lsof_phase_after 2
  set_lsof_port_after "$port" "$fake_pid"
  set_ps_comm "$fake_pid" "/opt/homebrew/bin/opencode"
}

# Spawn race: port becomes bound by a FOREIGN process between spawn and
# wait-for-listener. opencode_wait_for_opencode_listener fires die_upstream
# with the listener-identity message.
arm_spawn_race_foreign() {
  local port="${OPENCODE_WEB_PORT:-4096}"
  set_lsof_phase_after 2
  set_lsof_port_after "$port" "77777"
  set_ps_comm "77777" "/usr/sbin/nginx"
}

# Spawn timeout: pre-check sees port free; no listener ever binds. The
# wait_for_opencode_listener helper has a 5s wall-clock timeout — to keep
# the test fast we don't rely on the timeout, we just assert the exit path
# when the helper returns non-zero.  Achieved by leaving lsof-state-after
# empty so all post-phase-2 calls also return empty.
arm_spawn_timeout() {
  set_lsof_phase_after 2
  # No lsof-state-after rows → wait helper polls until timeout → returns 1.
}

# --- arg parsing tests ------------------------------------------------------

@test "opensession: --help exits 0 and prints Usage" {
  run "$SCRIPT" --help
  assert_success
  assert_output --partial "Usage: opensession"
  assert_output --partial "--restart"
  assert_output --partial "--force"
}

@test "opensession: -h exits 0 and prints Usage" {
  run "$SCRIPT" -h
  assert_success
  assert_output --partial "Usage: opensession"
}

@test "opensession: unknown flag exits 2" {
  run "$SCRIPT" --bogus
  assert_failure 2
  assert_output --partial "unknown flag"
}

@test "opensession: missing openweb wrapper exits 3" {
  write_all_stubs
  rm "$STUBDIR/opencode-web.sh"
  run "$SCRIPT"
  assert_failure 3
  assert_output --partial "openweb wrapper not found"
}

@test "opensession: missing openattach wrapper exits 3" {
  write_all_stubs
  rm "$STUBDIR/opencode-attach.sh"
  run "$SCRIPT"
  assert_failure 3
  assert_output --partial "openattach wrapper not found"
}

# --- default-path tests (no-flag invocation) --------------------------------

@test "opensession: no daemon → spawns openweb then execs openattach" {
  write_all_stubs
  arm_spawn_succeeds
  run "$SCRIPT"
  assert_success
  # openweb was spawned (background, via nohup) — argv recorded with no args.
  grep -q "^openweb $" "$STATEFILE" || grep -q "^openweb \$" "$STATEFILE" || {
    # nohup form passes no args; the stub logs `openweb ` (with trailing space).
    grep -q "^openweb" "$STATEFILE"
  }
  # openattach was exec'd. No --force passthrough on default path.
  grep -qE "^openattach\b" "$STATEFILE"
  if grep -q "^openattach.*--force" "$STATEFILE"; then
    echo "unexpected --force in openattach call" >&2
    return 1
  fi
  # The info banner mentions starting the daemon.
  assert_output --partial "starting one"
}

@test "opensession: no daemon → waits for sidecar before execing openattach" {
  write_all_stubs
  write_delayed_sidecar_openweb_stub
  write_sidecar_asserting_openattach_stub
  arm_spawn_succeeds

  DELAYED_SIDECAR_SLEEP=1 run "$SCRIPT"

  assert_success
  grep -q "^sidecar-written " "$STATEFILE"
  grep -q "^openattach-sidecar present$" "$STATEFILE"
  if grep -q "^openattach-sidecar missing$" "$STATEFILE"; then
    echo "openattach ran before the sidecar existed" >&2
    return 1
  fi
}

@test "opensession: fresh daemon → execs openattach silently (no spawn)" {
  write_all_stubs
  arm_fresh_daemon
  run "$SCRIPT"
  assert_success
  # No openweb spawn.
  if grep -q "^openweb" "$STATEFILE"; then
    echo "unexpected openweb spawn on fresh-daemon path" >&2
    return 1
  fi
  # openattach was exec'd.
  grep -qE "^openattach\b" "$STATEFILE"
  # No "starting one" banner — silent attach.
  [[ "$output" != *"starting one"* ]]
}

@test "opensession: stale daemon → delegates to openattach (no prompt logic in opensession)" {
  # "Stale" here means: opencode_daemon_pid_for_port returns a pid (the daemon
  # is up), but its sidecar hash differs from the current config. opensession
  # MUST NOT inspect that — it just execs openattach and lets openattach handle
  # the prompt. We assert by setting up a stale state and checking that
  # opensession produced no staleness-related output of its own.
  write_all_stubs
  local port="${OPENCODE_WEB_PORT:-4096}"
  local pid=99999
  set_lsof_port "$port" "$pid"
  set_ps_comm "$pid" "/opt/homebrew/bin/opencode"
  # Sidecar with a hash that won't match current config.
  printf '%s\n' "0000000000000000000000000000000000000000000000000000000000000000" \
    >"$OPENCODE_DAEMON_STATE_DIR/daemon-config-hash-${port}-${pid}"
  run "$SCRIPT"
  assert_success
  # openattach was exec'd.
  grep -qE "^openattach\b" "$STATEFILE"
  # No staleness-related output from opensession itself.
  [[ "$output" != *"stale"* && "$output" != *"Stale"* ]]
  [[ "$output" != *"Continue attaching"* ]]
}

@test "opensession: foreign listener on port → exit 5 with listener-identity error" {
  write_all_stubs
  arm_foreign_listener
  run "$SCRIPT"
  assert_failure 5
  assert_output --partial "not opencode"
  assert_output --partial "caffeinate"
  # Crucially, no spawn attempt.
  if grep -q "^openweb" "$STATEFILE"; then
    echo "unexpected openweb spawn on foreign-listener path" >&2
    return 1
  fi
}

@test "opensession: spawn race — port grabbed by foreign process during spawn → exit 5" {
  write_all_stubs
  arm_spawn_race_foreign
  run "$SCRIPT"
  assert_failure 5
  # opencode_wait_for_opencode_listener emits the listener-identity message.
  assert_output --partial "not opencode"
  assert_output --partial "nginx"
}

@test "opensession: spawn timeout → exit 5 with log path" {
  write_all_stubs
  arm_spawn_timeout
  # Speed up the test: opencode_wait_for_opencode_listener has a 5s timeout.
  # Setting OPENCODE_WEB_PORT to something the lsof stub will report as free
  # for all phases means the helper polls for the full 5s before returning.
  # We accept that delay rather than reaching into the helper; the assertion
  # is on the exit path, not the duration.
  run "$SCRIPT"
  assert_failure 5
  assert_output --partial "failed to bind"
  assert_output --partial "$OPENCODE_DAEMON_STATE_DIR/log/opensession-"
}

# --- --restart flag ---------------------------------------------------------

@test "opensession: --restart calls openweb --restart then execs openattach" {
  write_all_stubs
  run "$SCRIPT" --restart
  assert_success
  grep -qE "^openweb --restart\$" "$STATEFILE"
  grep -qE "^openattach\b" "$STATEFILE"
  assert_output --partial "Restarting opencode daemon"
}

@test "opensession: -r is alias for --restart" {
  write_all_stubs
  run "$SCRIPT" -r
  assert_success
  grep -qE "^openweb --restart\$" "$STATEFILE"
  grep -qE "^openattach\b" "$STATEFILE"
}

@test "opensession: --restart with openweb failure → exit 5" {
  write_all_stubs
  OPENWEB_EXIT=5 run "$SCRIPT" --restart
  assert_failure 5
  assert_output --partial "openweb --restart failed"
  # openattach was NOT exec'd — we bailed before that.
  if grep -q "^openattach" "$STATEFILE"; then
    echo "unexpected openattach exec after openweb failure" >&2
    return 1
  fi
}

# --- --force flag passthrough -----------------------------------------------

@test "opensession: --force passes --force to openattach" {
  write_all_stubs
  arm_fresh_daemon
  run "$SCRIPT" --force
  assert_success
  grep -qE "^openattach --force\$" "$STATEFILE"
}

@test "opensession: -f is alias for --force" {
  write_all_stubs
  arm_fresh_daemon
  run "$SCRIPT" -f
  assert_success
  grep -qE "^openattach --force\$" "$STATEFILE"
}

@test "opensession: --force + --restart both pass through" {
  write_all_stubs
  run "$SCRIPT" --restart --force
  assert_success
  grep -qE "^openweb --restart\$" "$STATEFILE"
  grep -qE "^openattach --force\$" "$STATEFILE"
}

# --- bash 3.2 regression ----------------------------------------------------

@test "opensession: runs cleanly under /bin/bash (3.2) — pinned form for nohup/disown" {
  # Pinned by plan §"Implementation gotchas": the
  #   nohup … & DAEMON_PID=$!; disown "$DAEMON_PID"
  # form must round-trip through bash 3.2 (macOS /bin/bash) without `set -u`
  # tripping on the (possibly empty) ATTACH_ARGS array.
  write_all_stubs
  arm_spawn_succeeds
  # Run via /bin/bash explicitly, regardless of what the shebang resolves to.
  STATEFILE_BEFORE=$(wc -l <"$STATEFILE")
  run /bin/bash "$SCRIPT"
  assert_success
  # openweb was spawned, openattach exec'd — full pipeline ran under bash 3.2.
  grep -qE "^openweb\b" "$STATEFILE"
  grep -qE "^openattach\b" "$STATEFILE"
}

@test "opensession: --force runs cleanly under /bin/bash (empty array safe)" {
  # ATTACH_ARGS array carries the --force flag. Empty-array path is exercised
  # in the no-flag tests; this one exercises the populated path under 3.2.
  write_all_stubs
  arm_fresh_daemon
  run /bin/bash "$SCRIPT" --force
  assert_success
  grep -qE "^openattach --force\$" "$STATEFILE"
}
