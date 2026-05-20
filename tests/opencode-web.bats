#!/usr/bin/env bats
# CLI tests for personal/opencode-web.sh
#
# All external binaries (opencode, caffeinate, security, tailscale, python3)
# are stubbed via PATH override; calls are logged to STATEFILE for assertion.

setup() {
  load 'test_helper/bats-support/load'
  load 'test_helper/bats-assert/load'
  SCRIPT="$BATS_TEST_DIRNAME/../personal/opencode-web.sh"

  STUBDIR="$(mktemp -d)"
  STATEFILE="$STUBDIR/calls.log"
  : >"$STATEFILE"
  # Keep coreutils available; prepend stub dir so our stubs win.
  export PATH="$STUBDIR:$PATH"
  export STATEFILE

  # Pin sidecar + config locations under the per-test sandbox so we never
  # touch the user's real ~/.local/share/opencode or read the live config.
  export OPENCODE_CONFIG_DIR="$STUBDIR/config"
  export OPENCODE_DAEMON_STATE_DIR="$STUBDIR/state"
  mkdir -p "$OPENCODE_CONFIG_DIR" "$OPENCODE_DAEMON_STATE_DIR"
  # Minimal fixture so the content-hash function has something deterministic.
  echo '{}' >"$OPENCODE_CONFIG_DIR/opencode.json"
}

teardown() {
  [[ -d "$STUBDIR" ]] && rm -rf "$STUBDIR"
}

# --- stub factories ---------------------------------------------------------

# Stub `security find-generic-password -s NAME -a ACCT -w` — returns the
# value held in $KEYCHAIN_VALUE, or fails (rc=44, matching real `security`'s
# "item not found") if KEYCHAIN_VALUE is unset.
write_security_stub() {
  cat >"$STUBDIR/security" <<'EOF'
#!/usr/bin/env bash
echo "security $*" >>"$STATEFILE"
if [[ "${KEYCHAIN_VALUE+set}" != "set" ]]; then
  echo "security: SecKeychainSearchCopyNext: The specified item could not be found in the keychain." >&2
  exit 44
fi
printf '%s' "$KEYCHAIN_VALUE"
EOF
  chmod +x "$STUBDIR/security"
}

# Stub `caffeinate` so it does NOT actually exec opencode. It must stay alive
# long enough that the wrapper's `kill -0 $CAFFEINATE_PID` check passes after
# the (also-stubbed) listener-wait. A short sleep is sufficient; the wrapper
# exits as soon as the sidecar is written.
write_caffeinate_stub() {
  cat >"$STUBDIR/caffeinate" <<'EOF'
#!/usr/bin/env bash
echo "caffeinate $*" >>"$STATEFILE"
# Also log relevant exported env vars so tests can assert they were set.
echo "env OPENCODE_SERVER_USERNAME=${OPENCODE_SERVER_USERNAME-}" >>"$STATEFILE"
echo "env OPENCODE_SERVER_PASSWORD_LEN=${#OPENCODE_SERVER_PASSWORD}" >>"$STATEFILE"
echo "env PATH_HEAD=${PATH%%:*}" >>"$STATEFILE"
# Stay alive past the wrapper's wait-for-listener window so the post-wait
# `kill -0 $CAFFEINATE_PID` premature-exit diagnostic doesn't fire.
sleep 2
exit 0
EOF
  chmod +x "$STUBDIR/caffeinate"
}

# Stub `opencode` — should never actually be invoked because caffeinate is
# stubbed before exec, but provide it so `require_cmd opencode` passes.
write_opencode_stub() {
  cat >"$STUBDIR/opencode" <<'EOF'
#!/usr/bin/env bash
echo "opencode $*" >>"$STATEFILE"
exit 0
EOF
  chmod +x "$STUBDIR/opencode"
}

# Stub `tailscale` so the banner-FQDN lookup has something to consume.
write_tailscale_stub() {
  cat >"$STUBDIR/tailscale" <<'EOF'
#!/usr/bin/env bash
echo "tailscale $*" >>"$STATEFILE"
if [[ "$1" == "status" && "$2" == "--json" ]]; then
  printf '{"Self":{"DNSName":"glitch.example.ts.net."}}'
  exit 0
fi
exit 0
EOF
  chmod +x "$STUBDIR/tailscale"
}

# --- daemon-helper stubs ---------------------------------------------------
#
# The wrapper now consults lib/opencode-daemon.sh which uses lsof + ps to
# verify port state, listener identity, and pid → comm. The default stub
# behavior models the happy path: port is free pre-spawn, becomes bound by
# opencode-web after the (stubbed) caffeinate is backgrounded.
#
# Tests that want "port already bound" / "port held by other process" / etc.
# manipulate the state files directly via the setters below.

# lsof stub: drives port-listener detection. Supports a 3-phase model:
#   phase 1 (calls 1..PHASE_FREE_AFTER):  reads $STUBDIR/lsof-state
#   phase 2 (calls PHASE_FREE_AFTER+1..PHASE_BOUND_AFTER):
#                                          reads $STUBDIR/lsof-state-free
#   phase 3 (calls PHASE_BOUND_AFTER+1..): reads $STUBDIR/lsof-state-after
# Tests that don't care about phase 2 just leave PHASE_FREE_AFTER ==
# PHASE_BOUND_AFTER (or PHASE_BOUND_AFTER unset), collapsing back to a
# 2-phase initial/after model.
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
# Phase 2 = "port free" (no entries; awk fails to match → stub exits 1).
# Tests that need the kill-poll-then-respawn sequence use this.
set_lsof_phase_free_after() {
  printf '%s\n' "$1" >"$STUBDIR/lsof-phase-after"
}
set_lsof_phase_bound_after() {
  printf '%s\n' "$1" >"$STUBDIR/lsof-phase-bound-after"
}
# Back-compat shim used by the simple 2-phase tests.
set_lsof_phase_after() {
  printf '%s\n' "$1" >"$STUBDIR/lsof-phase-after"
  # Collapse phase 2 = phase 3 so a 2-phase test stays 2-phase.
  printf '%s\n' "$1" >"$STUBDIR/lsof-phase-bound-after"
}

# ps stub: drives pid → comm lookup (and falls through to /bin/ps for any
# other shape, e.g. `ps -o lstart= -p PID` used in the human-readable
# "daemon started at …" message).
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

# Pgrep stub: not strictly required by the wrapper (the helper uses lsof+ps),
# but `require_cmd pgrep` runs at helper source-time. Provide a passthrough.
write_pgrep_stub() {
  cat >"$STUBDIR/pgrep" <<'EOF'
#!/usr/bin/env bash
exec /usr/bin/pgrep "$@"
EOF
  chmod +x "$STUBDIR/pgrep"
}

# Convenience: model "happy path" — port is initially free, then becomes
# bound by opencode-web (fake pid 99999) after a few lsof calls so that
# opencode_wait_for_opencode_listener returns 99999.
arm_happy_path_daemon_spawn() {
  local port="${OPENCODE_WEB_PORT:-4096}"
  local fake_pid=99999
  # Pre-spawn lsof calls (2 of them: opencode_daemon_pid_for_port + opencode_port_listener_pid)
  # must report port-free. Post-spawn, opencode_wait_for_opencode_listener polls
  # until lsof returns a pid; setting phase_after=2 means lsof call #3 onward
  # sees the (fake) listener bound.
  set_lsof_phase_after 2
  set_lsof_port_after "$port" "$fake_pid"
  set_ps_comm "$fake_pid" "/opt/homebrew/bin/opencode"
}

# Convenience: stub everything except KEYCHAIN_VALUE which the test sets.
# This models the happy-path: port free pre-spawn, opencode-web listener
# appears post-spawn (fake pid 99999), sidecar lands under $OPENCODE_DAEMON_STATE_DIR.
write_all_stubs() {
  write_security_stub
  write_caffeinate_stub
  write_opencode_stub
  write_tailscale_stub
  write_lsof_stub
  write_ps_stub
  write_pgrep_stub
  arm_happy_path_daemon_spawn
}

# --- arg parsing tests ------------------------------------------------------

@test "opencode-web: --help exits 0 and prints Usage" {
  run "$SCRIPT" --help
  assert_success
  assert_output --partial "Usage:"
  assert_output --partial "openweb"
}

@test "opencode-web: -h exits 0 and prints Usage" {
  run "$SCRIPT" -h
  assert_success
  assert_output --partial "Usage:"
}

@test "opencode-web: unknown flag exits 2" {
  run "$SCRIPT" --bogus-flag
  assert_failure 2
  assert_output --partial "unknown flag"
}

# --- dependency-check tests -------------------------------------------------

@test "opencode-web: missing opencode on PATH exits 3" {
  # Restrict PATH to system locations sufficient for the daemon-helper's
  # require_cmd lookups (lsof in /usr/sbin, pgrep/ps in /usr/bin, date/stat
  # via coreutils path stripping). DON'T provide an opencode stub so the
  # `require_cmd opencode` line is the first thing to fail.
  PATH="/usr/bin:/bin:/usr/sbin" run "$SCRIPT"
  assert_failure 3
  assert_output --partial "opencode"
}

@test "opencode-web: missing caffeinate exits 3" {
  write_opencode_stub
  # Build an isolated PATH containing $STUBDIR plus symlinks to the system
  # binaries the script + helper need before reaching `require_cmd caffeinate`:
  #   - bash, dirname:           wrapper bootstrap
  #   - pgrep, lsof, ps, date,
  #     stat, shasum:           require_cmd checks at the top of
  #                              lib/opencode-daemon.sh (which sources BEFORE
  #                              the wrapper's require_cmd caffeinate line).
  # caffeinate is intentionally NOT linked so require_cmd caffeinate fires.
  for bin in bash dirname pgrep lsof ps date stat shasum; do
    real="$(command -v "$bin")"
    [[ -n "$real" ]] || skip "host is missing required tool: $bin"
    ln -sf "$real" "$STUBDIR/$bin"
  done
  PATH="$STUBDIR" run "$SCRIPT"
  assert_failure 3
  assert_output --partial "caffeinate"
}

# --- keychain integration tests ---------------------------------------------

@test "opencode-web: missing keychain entry exits 1 with hint" {
  write_all_stubs
  # KEYCHAIN_VALUE intentionally unset → security stub returns rc=44.
  unset KEYCHAIN_VALUE
  run "$SCRIPT"
  assert_failure 1
  assert_output --partial "Secret not found"
  assert_output --partial "opencode-server-password"
}

@test "opencode-web: happy path execs caffeinate with opencode web args" {
  write_all_stubs
  export KEYCHAIN_VALUE="test-password-1234567890"
  run "$SCRIPT"
  assert_success
  run cat "$STATEFILE"
  # caffeinate must be invoked with the opencode web command tail.
  assert_output --partial "caffeinate -is opencode web --port 4096 --hostname 127.0.0.1"
}

@test "opencode-web: exports OPENCODE_SERVER_PASSWORD for the child process" {
  write_all_stubs
  # Use a marker value of known length so we can length-assert without ever
  # logging the value itself (security hygiene even in tests).
  export KEYCHAIN_VALUE="0123456789"
  run "$SCRIPT"
  assert_success
  run cat "$STATEFILE"
  assert_output --partial "env OPENCODE_SERVER_PASSWORD_LEN=10"
}

@test "opencode-web: exports default OPENCODE_SERVER_USERNAME=opencode" {
  write_all_stubs
  export KEYCHAIN_VALUE="x"
  run "$SCRIPT"
  assert_success
  run cat "$STATEFILE"
  assert_output --partial "env OPENCODE_SERVER_USERNAME=opencode"
}

@test "opencode-web: respects OPENCODE_SERVER_USERNAME override" {
  write_all_stubs
  export KEYCHAIN_VALUE="x"
  export OPENCODE_SERVER_USERNAME="hunter"
  run "$SCRIPT"
  assert_success
  run cat "$STATEFILE"
  assert_output --partial "env OPENCODE_SERVER_USERNAME=hunter"
}

# --- env-override tests -----------------------------------------------------

@test "opencode-web: OPENCODE_WEB_PORT override propagates to opencode args" {
  export OPENCODE_WEB_PORT="5555"
  write_all_stubs
  export KEYCHAIN_VALUE="x"
  run "$SCRIPT"
  assert_success
  run cat "$STATEFILE"
  assert_output --partial "--port 5555"
}

@test "opencode-web: OPENCODE_WEB_HOSTNAME override propagates to opencode args" {
  write_all_stubs
  export KEYCHAIN_VALUE="x"
  export OPENCODE_WEB_HOSTNAME="0.0.0.0"
  run "$SCRIPT"
  assert_success
  run cat "$STATEFILE"
  assert_output --partial "--hostname 0.0.0.0"
}

# --- banner tests -----------------------------------------------------------

@test "opencode-web: banner includes localhost URL" {
  write_all_stubs
  export KEYCHAIN_VALUE="x"
  run "$SCRIPT"
  assert_success
  assert_output --partial "http://127.0.0.1:4096"
}

@test "opencode-web: banner includes tailnet URL when tailscale is available" {
  write_all_stubs
  export KEYCHAIN_VALUE="x"
  run "$SCRIPT"
  assert_success
  assert_output --partial "https://glitch.example.ts.net"
}

@test "opencode-web: banner gracefully omits tailnet URL when tailscale is missing" {
  # Provide everything EXCEPT tailscale. Include /usr/sbin in PATH so the
  # helper's `require_cmd lsof` finds /usr/sbin/lsof (lsof isn't in /usr/bin
  # or /bin on macOS).
  write_security_stub
  write_caffeinate_stub
  write_opencode_stub
  write_lsof_stub
  write_ps_stub
  write_pgrep_stub
  arm_happy_path_daemon_spawn
  export KEYCHAIN_VALUE="x"
  PATH="$STUBDIR:/usr/bin:/bin:/usr/sbin" run "$SCRIPT"
  assert_success
  assert_output --partial "http://127.0.0.1:4096"
  refute_output --partial "Tailnet:"
}

@test "opencode-web: never prints the password to stdout/stderr" {
  write_all_stubs
  export KEYCHAIN_VALUE="THIS_PASSWORD_MUST_NEVER_LEAK"
  run "$SCRIPT"
  assert_success
  refute_output --partial "THIS_PASSWORD_MUST_NEVER_LEAK"
}

# --- Option Y / port-state / sidecar tests (Ship 1, plan §test plan) -------
#
# These tests pin the design shift from `exec caffeinate …` to
# spawn-and-monitor. Each asserts one observable property of the new
# behavior: the wrapper exits in bounded time (no foreground caffeinate
# regression), the sidecar is written with the listener's pid (not $$),
# port-bound refusals fire with the right message for the right cause, etc.

@test "opencode-web: refuses when port is held by an opencode-web daemon (with --restart hint)" {
  write_all_stubs
  export KEYCHAIN_VALUE="x"
  # Override happy-path arming: make the port already bound by an opencode
  # process from the FIRST lsof call onward by replacing lsof-state-after
  # (which arm_happy_path populated) and setting phases to skip phase 1.
  : >"$STUBDIR/lsof-state-after"
  set_lsof_port_after 4096 80001
  set_lsof_phase_free_after 0  # phase 1 ends immediately
  set_lsof_phase_bound_after 0 # phase 2 also empty → ALL calls hit phase 3
  set_ps_comm 80001 "opencode"
  run "$SCRIPT"
  assert_failure 5
  assert_output --partial "daemon already on :4096"
  assert_output --partial "pid 80001"
  assert_output --partial "--restart"
}

@test "opencode-web: refuses with distinct message when port is held by a non-opencode process" {
  write_all_stubs
  export KEYCHAIN_VALUE="x"
  : >"$STUBDIR/lsof-state-after"
  set_lsof_port_after 4096 80002
  set_lsof_phase_free_after 0
  set_lsof_phase_bound_after 0
  set_ps_comm 80002 "/usr/sbin/httpd"
  run "$SCRIPT"
  assert_failure 5
  assert_output --partial "port :4096 taken by pid 80002"
  assert_output --partial "httpd"
  assert_output --partial "not opencode"
  # The two refusals MUST differ so the user can tell them apart.
  refute_output --partial "daemon already on"
}

@test "opencode-web: port-free happy path proceeds normally" {
  write_all_stubs
  export KEYCHAIN_VALUE="x"
  run "$SCRIPT"
  assert_success
  run cat "$STATEFILE"
  assert_output --partial "caffeinate -is opencode web --port 4096 --hostname 127.0.0.1"
}

@test "opencode-web: --restart kills running daemon then starts fresh" {
  export KEYCHAIN_VALUE="x"
  # Avoid write_all_stubs's happy-path arming so we can build a custom
  # 3-phase lsof state from scratch.
  write_security_stub
  write_caffeinate_stub
  write_opencode_stub
  write_tailscale_stub
  write_lsof_stub
  write_ps_stub
  write_pgrep_stub
  # 3-phase lsof model:
  #   call 1     → port held by OLD daemon (pid 80003)        → pre-spawn EXISTING_PID check
  #   call 2..3  → port FREE                                   → kill-poll loop succeeds
  #   call 4+    → port held by NEW daemon (pid 99999)         → wait_for_listener returns 99999
  set_lsof_port 4096 80003
  set_ps_comm 80003 "opencode"
  set_lsof_phase_free_after 1
  set_lsof_phase_bound_after 3
  : >"$STUBDIR/lsof-state-free"  # phase 2: empty = port free
  set_lsof_port_after 4096 99999 # phase 3: new listener
  set_ps_comm 99999 "opencode"
  run "$SCRIPT" --restart
  assert_success
  assert_output --partial "Restarting"
  assert_output --partial "pid 80003"
  assert_output --partial "daemon started on :4096"
}

@test "opencode-web: --restart with no existing daemon prints info and starts fresh" {
  write_all_stubs
  export KEYCHAIN_VALUE="x"
  run "$SCRIPT" --restart
  assert_success
  assert_output --partial "no daemon to kill"
  assert_output --partial "daemon started on :4096"
}

@test "opencode-web: --force bypasses port-bound refusal" {
  export KEYCHAIN_VALUE="x"
  # Build custom 3-phase state — --force should kill the existing daemon
  # and spawn fresh, just like --restart, NOT silently adopt the holder.
  write_security_stub
  write_caffeinate_stub
  write_opencode_stub
  write_tailscale_stub
  write_lsof_stub
  write_ps_stub
  write_pgrep_stub
  # Phase 1: existing opencode daemon holds the port.
  # Phase 2: port free (post-kill).
  # Phase 3: new opencode daemon bound.
  set_lsof_port 4096 80004
  set_ps_comm 80004 "opencode"
  set_lsof_phase_free_after 1
  set_lsof_phase_bound_after 3
  : >"$STUBDIR/lsof-state-free"
  set_lsof_port_after 4096 99999
  set_ps_comm 99999 "opencode"
  # Pre-create sidecar for old daemon — kill flow must remove it.
  echo "0000000000000000000000000000000000000000000000000000000000000000" \
    >"$OPENCODE_DAEMON_STATE_DIR/daemon-config-hash-4096-80004"
  run "$SCRIPT" --force
  assert_success
  assert_output --partial "Force: killing opencode daemon"
  assert_output --partial "pid 80004"
  assert_output --partial "daemon started on :4096"
  # New sidecar at NEW pid, not old pid.
  [[ -f "$OPENCODE_DAEMON_STATE_DIR/daemon-config-hash-4096-99999" ]]
  [[ ! -e "$OPENCODE_DAEMON_STATE_DIR/daemon-config-hash-4096-80004" ]]
}

@test "opencode-web: --force kills a foreign listener and spawns fresh" {
  # The defect this catches: previously --force just skipped the refusal and
  # let opencode try to bind-and-fail; the wrapper then silently adopted the
  # pre-existing listener. With the fix, --force must kill the foreign holder
  # and confirm the port freed before spawning.
  export KEYCHAIN_VALUE="x"
  write_security_stub
  write_caffeinate_stub
  write_opencode_stub
  write_tailscale_stub
  write_lsof_stub
  write_ps_stub
  write_pgrep_stub
  # Phase 1: foreign process (e.g. nginx) holds :4096 — NOT opencode.
  # Phase 2: port free (post-kill).
  # Phase 3: new opencode daemon bound.
  set_lsof_port 4096 70001
  set_ps_comm 70001 "nginx"
  set_lsof_phase_free_after 2
  set_lsof_phase_bound_after 4
  : >"$STUBDIR/lsof-state-free"
  set_lsof_port_after 4096 99999
  set_ps_comm 99999 "opencode"
  run "$SCRIPT" --force
  assert_success
  assert_output --partial "Force: killing foreign listener"
  assert_output --partial "pid 70001"
  assert_output --partial "nginx"
  assert_output --partial "daemon started on :4096"
  [[ -f "$OPENCODE_DAEMON_STATE_DIR/daemon-config-hash-4096-99999" ]]
}

@test "opencode-web: --force fails loudly if the port does not free in time" {
  # Defense: if our kill doesn't free the port within the timeout, we MUST NOT
  # proceed to spawn (and silently adopt the still-bound holder). die_upstream.
  export KEYCHAIN_VALUE="x"
  write_security_stub
  write_caffeinate_stub
  write_opencode_stub
  write_tailscale_stub
  write_lsof_stub
  write_ps_stub
  write_pgrep_stub
  # Foreign listener that refuses to die — port stays bound across all phases.
  set_lsof_port 4096 70002
  set_ps_comm 70002 "stubborn"
  # No phase boundaries: every lsof call returns the same bound state.
  set_lsof_phase_free_after 999
  set_lsof_phase_bound_after 999
  run "$SCRIPT" --force
  assert_failure
  assert_output --partial "failed to free :4096"
  assert_output --partial "stubborn"
}

@test "opencode-web: OPENCODE_WEB_FORCE=1 also bypasses port-bound refusal" {
  export OPENCODE_WEB_FORCE=1
  export KEYCHAIN_VALUE="x"
  # Same 3-phase realistic state as --force test.
  write_security_stub
  write_caffeinate_stub
  write_opencode_stub
  write_tailscale_stub
  write_lsof_stub
  write_ps_stub
  write_pgrep_stub
  set_lsof_port 4096 80005
  set_ps_comm 80005 "opencode"
  set_lsof_phase_free_after 1
  set_lsof_phase_bound_after 3
  : >"$STUBDIR/lsof-state-free"
  set_lsof_port_after 4096 99999
  set_ps_comm 99999 "opencode"
  run "$SCRIPT"
  assert_success
  assert_output --partial "Force: killing opencode daemon"
  [[ -f "$OPENCODE_DAEMON_STATE_DIR/daemon-config-hash-4096-99999" ]]
}

@test "opencode-web: sidecar written on start with the LISTENER pid (not wrapper \$\$)" {
  write_all_stubs
  export KEYCHAIN_VALUE="x"
  run "$SCRIPT"
  assert_success
  # The fake listener pid from arm_happy_path_daemon_spawn is 99999.
  # The sidecar MUST be at daemon-config-hash-4096-99999, NOT at any
  # path containing the wrapper's pid — this is the regression caught
  # by the 2026-05-10 $$-verification experiment.
  [[ -f "$OPENCODE_DAEMON_STATE_DIR/daemon-config-hash-4096-99999" ]]
  body="$(<"$OPENCODE_DAEMON_STATE_DIR/daemon-config-hash-4096-99999")"
  [[ "$body" =~ ^[0-9a-f]{64}$ ]]
  # Defensive: no stray sidecars whose pid component looks like a typical
  # bash pid range (the wrapper's actual $$).
  found_count=$(ls "$OPENCODE_DAEMON_STATE_DIR" | grep -c '^daemon-config-hash-4096-' || true)
  [[ "$found_count" == "1" ]]
}

@test "opencode-web: wrapper exits in bounded time (no foreground caffeinate regression)" {
  write_all_stubs
  export KEYCHAIN_VALUE="x"
  # If a regression re-introduced `exec caffeinate …`, the stub's `sleep 2`
  # would make the wrapper block on the exec'd caffeinate for 2 seconds at
  # minimum (or forever in production). The post-spawn / sidecar-write path
  # should return in well under 1s on stubs alone.
  start="$(date +%s)"
  run "$SCRIPT"
  end="$(date +%s)"
  assert_success
  elapsed=$((end - start))
  # 10s upper bound per plan §test plan.
  [[ "$elapsed" -lt 10 ]]
}

@test "opencode-web: sidecar removed when --restart kills the old daemon" {
  export KEYCHAIN_VALUE="x"
  # Build custom state (don't use arm_happy_path).
  write_security_stub
  write_caffeinate_stub
  write_opencode_stub
  write_tailscale_stub
  write_lsof_stub
  write_ps_stub
  write_pgrep_stub
  set_lsof_port 4096 80006 # old daemon
  set_ps_comm 80006 "opencode"
  set_lsof_phase_free_after 1
  set_lsof_phase_bound_after 3
  : >"$STUBDIR/lsof-state-free"
  set_lsof_port_after 4096 99999 # new daemon post-spawn
  set_ps_comm 99999 "opencode"
  # Pre-create a sidecar for the OLD daemon — the kill flow should remove it.
  echo "0000000000000000000000000000000000000000000000000000000000000000" \
    >"$OPENCODE_DAEMON_STATE_DIR/daemon-config-hash-4096-80006"
  run "$SCRIPT" --restart
  assert_success
  # Old sidecar gone.
  [[ ! -e "$OPENCODE_DAEMON_STATE_DIR/daemon-config-hash-4096-80006" ]]
  # New sidecar present.
  [[ -f "$OPENCODE_DAEMON_STATE_DIR/daemon-config-hash-4096-99999" ]]
}

@test "opencode-web: caffeinate child receives PATH with open-shim prepended" {
  write_all_stubs
  export KEYCHAIN_VALUE="x"
  run "$SCRIPT"
  assert_success
  # The caffeinate stub logs PATH_HEAD=<first PATH component>.
  # That component must be a temp dir containing an executable `open` shim.
  run grep "^env PATH_HEAD=" "$STATEFILE"
  assert_success
  shim_dir="${output#env PATH_HEAD=}"
  # The shim dir should exist and contain an executable `open`.
  [[ -d "$shim_dir" ]]
  [[ -x "$shim_dir/open" ]]
  # Verify shim is actually a no-op (exits 0, does nothing).
  run cat "$shim_dir/open"
  assert_line --index 0 '#!/usr/bin/env bash'
  assert_line --index 1 'exit 0'
}
