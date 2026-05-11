#!/usr/bin/env bats
# CLI tests for personal/opencode-attach.sh
#
# Stubs `opencode`, `security` via PATH override and asserts argument shape,
# exit codes, and that the Keychain password is exported into the child env.

setup() {
  load 'test_helper/bats-support/load'
  load 'test_helper/bats-assert/load'
  SCRIPT="$BATS_TEST_DIRNAME/../personal/opencode-attach.sh"

  STUBDIR="$(mktemp -d)"
  STATEFILE="$STUBDIR/calls.log"
  : >"$STATEFILE"
  export PATH="$STUBDIR:$PATH"
  export STATEFILE
  # Isolate sidecar dir per test so live :4096 state never bleeds in.
  # The opencode-daemon helper reads OPENCODE_DAEMON_STATE_DIR.
  OPENCODE_DAEMON_STATE_DIR="$STUBDIR/state"
  mkdir -p "$OPENCODE_DAEMON_STATE_DIR"
  export OPENCODE_DAEMON_STATE_DIR
  # Isolate config dir so content_hash doesn't read the user's real config.
  OPENCODE_CONFIG_DIR="$STUBDIR/config"
  mkdir -p "$OPENCODE_CONFIG_DIR"
  printf '{}\n' >"$OPENCODE_CONFIG_DIR/opencode.json"
  export OPENCODE_CONFIG_DIR
}

teardown() {
  [[ -d "$STUBDIR" ]] && rm -rf "$STUBDIR"
}

# --- stub factories ---------------------------------------------------------

# Mirrors the `security find-generic-password` contract used in opencode-web.bats:
# returns $KEYCHAIN_VALUE if set, else fails with rc=44.
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

# Stub `opencode`: log args + the env vars the wrapper is expected to export,
# so tests can assert credentials propagate to the child without ever logging
# the value itself.
write_opencode_stub() {
  cat >"$STUBDIR/opencode" <<'EOF'
#!/usr/bin/env bash
echo "opencode $*" >>"$STATEFILE"
echo "env OPENCODE_SERVER_USERNAME=${OPENCODE_SERVER_USERNAME-}" >>"$STATEFILE"
echo "env OPENCODE_SERVER_PASSWORD_LEN=${#OPENCODE_SERVER_PASSWORD}" >>"$STATEFILE"
exit 0
EOF
  chmod +x "$STUBDIR/opencode"
}

write_all_stubs() {
  write_security_stub
  write_opencode_stub
}

# --- daemon-helper stubs ---------------------------------------------------
#
# The opencode-daemon helper sources `require_cmd` for lsof/ps/stat/etc. at
# script start. With our restricted PATH (STUBDIR + system PATH) we need to
# either provide stubs or rely on system tools. lsof lives in /usr/sbin on
# macOS, so we always stub it. ps and stat are in /bin and visible. shasum
# is in /usr/bin.

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
if [[ -n "$port" && -r "$(dirname "$0")/lsof-map" ]]; then
  awk -F '\t' -v p="$port" '$1==p {print $2; found=1} END {exit !found}' \
    "$(dirname "$0")/lsof-map" && exit 0
fi
exit 1
EOF
  chmod +x "$STUBDIR/lsof"
}

set_lsof_port() {
  local port="$1" pid="$2"
  printf '%s\t%s\n' "$port" "$pid" >>"$STUBDIR/lsof-map"
}

write_ps_stub() {
  cat >"$STUBDIR/ps" <<'EOF'
#!/usr/bin/env bash
echo "ps $*" >>"$STATEFILE"
# ps -o comm= -p PID  →  print mapped comm
# ps -o lstart= -p PID → print a fixed timestamp (used by start_epoch)
mode=""
pid=""
while [[ $# -gt 0 ]]; do
  case "$1" in
    -o)
      shift
      case "${1:-}" in
        comm=) mode="comm" ;;
        lstart=) mode="lstart" ;;
      esac
      ;;
    -p)
      shift
      pid="${1:-}"
      ;;
  esac
  shift || true
done
if [[ "$mode" == "comm" && -r "$(dirname "$0")/ps-comm-map" ]]; then
  awk -F '\t' -v p="$pid" '$1==p {print $2; found=1} END {exit !found}' \
    "$(dirname "$0")/ps-comm-map"
elif [[ "$mode" == "lstart" ]]; then
  # Stable timestamp, parseable by /bin/date -j -f.
  printf 'Sat May 10 12:00:00 2026\n'
else
  exit 1
fi
EOF
  chmod +x "$STUBDIR/ps"
}

set_ps_comm() {
  local pid="$1" comm="$2"
  printf '%s\t%s\n' "$pid" "$comm" >>"$STUBDIR/ps-comm-map"
}

# Arms the test environment to look like "daemon present on :PORT and FRESH"
# (sidecar matches current config hash). Default port 4096; override via
# OPENCODE_WEB_PORT at the test's setup time.
arm_fresh_daemon() {
  local port="${OPENCODE_WEB_PORT:-4096}"
  local pid="${1:-77777}"
  write_lsof_stub
  write_ps_stub
  set_lsof_port "$port" "$pid"
  set_ps_comm "$pid" "/opt/homebrew/bin/opencode"
  # Write a sidecar with the CURRENT config hash so is_stale → fresh.
  local hash
  hash="$(bash -c "source '$BATS_TEST_DIRNAME/../lib/opencode-daemon.sh' && opencode_config_content_hash")"
  printf '%s' "$hash" >"$OPENCODE_DAEMON_STATE_DIR/daemon-config-hash-${port}-${pid}"
}

# Arms "daemon present + STALE": sidecar exists but with wrong hash.
arm_stale_daemon() {
  local port="${OPENCODE_WEB_PORT:-4096}"
  local pid="${1:-77778}"
  write_lsof_stub
  write_ps_stub
  set_lsof_port "$port" "$pid"
  set_ps_comm "$pid" "/opt/homebrew/bin/opencode"
  printf '0000000000000000000000000000000000000000000000000000000000000000' \
    >"$OPENCODE_DAEMON_STATE_DIR/daemon-config-hash-${port}-${pid}"
}

# Arms "daemon present + sidecar MISSING" → treated as stale + warns.
arm_missing_sidecar_daemon() {
  local port="${OPENCODE_WEB_PORT:-4096}"
  local pid="${1:-77779}"
  write_lsof_stub
  write_ps_stub
  set_lsof_port "$port" "$pid"
  set_ps_comm "$pid" "/opt/homebrew/bin/opencode"
  rm -f "$OPENCODE_DAEMON_STATE_DIR/daemon-config-hash-${port}-${pid}"
}

# Arms "no daemon": lsof returns nothing for the port.
arm_no_daemon() {
  write_lsof_stub
  write_ps_stub
  # No set_lsof_port → lsof exits non-zero → opencode_daemon_pid_for_port
  # returns empty.
}

# --- arg parsing tests ------------------------------------------------------

@test "opencode-attach: --help exits 0 and prints Usage" {
  run "$SCRIPT" --help
  assert_success
  assert_output --partial "Usage:"
  assert_output --partial "openattach"
}

@test "opencode-attach: -h exits 0 and prints Usage" {
  run "$SCRIPT" -h
  assert_success
  assert_output --partial "Usage:"
}

@test "opencode-attach: unknown flag exits 2" {
  run "$SCRIPT" --bogus-flag
  assert_failure 2
  assert_output --partial "unknown flag"
}

@test "opencode-attach: rejects multiple positional URLs" {
  run "$SCRIPT" http://a:1 http://b:2
  assert_failure 2
  assert_output --partial "unexpected positional arg"
}

# --- dependency-check tests -------------------------------------------------

@test "opencode-attach: missing opencode on PATH exits 3" {
  # The opencode-daemon helper sources at script start and require_cmd's
  # several system tools (lsof, ps, etc.). Strip PATH but keep /usr/sbin
  # for lsof so the helper sources cleanly and opencode is the gating miss.
  PATH="/usr/sbin:/usr/bin:/bin" run "$SCRIPT" --force
  assert_failure 3
  assert_output --partial "opencode"
}

# --- keychain integration tests ---------------------------------------------

@test "opencode-attach: missing keychain entry exits 1 with hint" {
  write_all_stubs
  unset KEYCHAIN_VALUE
  run "$SCRIPT" --force
  assert_failure 1
  assert_output --partial "Secret not found"
  assert_output --partial "opencode-server-password"
}

@test "opencode-attach: happy path execs opencode attach with default URL" {
  write_all_stubs
  export KEYCHAIN_VALUE="x"
  run "$SCRIPT" --force
  assert_success
  run cat "$STATEFILE"
  assert_output --partial "opencode attach http://127.0.0.1:4096"
}

@test "opencode-attach: explicit URL positional is honored" {
  write_all_stubs
  export KEYCHAIN_VALUE="x"
  run "$SCRIPT" --force "http://10.0.0.5:4096"
  assert_success
  run cat "$STATEFILE"
  assert_output --partial "opencode attach http://10.0.0.5:4096"
}

@test "opencode-attach: passthrough args after -- are forwarded" {
  write_all_stubs
  export KEYCHAIN_VALUE="x"
  run "$SCRIPT" --force -- --continue
  assert_success
  run cat "$STATEFILE"
  assert_output --partial "opencode attach http://127.0.0.1:4096 --dir"
  assert_output --partial "--continue"
}

@test "opencode-attach: URL + passthrough args coexist" {
  write_all_stubs
  export KEYCHAIN_VALUE="x"
  run "$SCRIPT" --force "http://h:9" -- --session abc
  assert_success
  run cat "$STATEFILE"
  assert_output --partial "opencode attach http://h:9 --dir"
  assert_output --partial "--session abc"
}

# --- --dir injection regression tests ---------------------------------------
#
# `opencode attach` without --dir falls back to the SERVER's process.cwd()
# (the dir openweb was launched from), so every attached session lands in
# the same project regardless of where the alias was invoked. These tests
# pin the wrapper's behavior of injecting `--dir "$PWD"` by default and
# yielding to an explicit caller-supplied --dir.
# Refs: https://github.com/anomalyco/opencode/issues/14460

@test "opencode-attach: injects --dir \$PWD by default" {
  write_all_stubs
  export KEYCHAIN_VALUE="x"
  cd "$STUBDIR"
  run "$SCRIPT" --force
  assert_success
  run cat "$STATEFILE"
  assert_output --partial "opencode attach http://127.0.0.1:4096 --dir $STUBDIR"
}

@test "opencode-attach: --dir reflects current working directory at invocation" {
  write_all_stubs
  export KEYCHAIN_VALUE="x"
  local subdir="$STUBDIR/nested/project"
  mkdir -p "$subdir"
  cd "$subdir"
  run "$SCRIPT" --force
  assert_success
  run cat "$STATEFILE"
  assert_output --partial "--dir $subdir"
}

@test "opencode-attach: caller-supplied --dir overrides default injection" {
  write_all_stubs
  export KEYCHAIN_VALUE="x"
  cd "$STUBDIR"
  run "$SCRIPT" --force -- --dir /override/path
  assert_success
  run cat "$STATEFILE"
  # The forwarded args should contain the caller's --dir exactly once,
  # and must not contain the default $PWD injection.
  assert_output --partial "--dir /override/path"
  refute_output --partial "--dir $STUBDIR"
}

@test "opencode-attach: caller-supplied --dir=value form also overrides default" {
  write_all_stubs
  export KEYCHAIN_VALUE="x"
  cd "$STUBDIR"
  run "$SCRIPT" --force -- --dir=/override/path
  assert_success
  run cat "$STATEFILE"
  assert_output --partial "--dir=/override/path"
  refute_output --partial "--dir $STUBDIR"
}

@test "opencode-attach: --dir injected alongside other passthrough args" {
  write_all_stubs
  export KEYCHAIN_VALUE="x"
  cd "$STUBDIR"
  run "$SCRIPT" --force -- --continue
  assert_success
  run cat "$STATEFILE"
  assert_output --partial "--dir $STUBDIR"
  assert_output --partial "--continue"
}

@test "opencode-attach: exports OPENCODE_SERVER_PASSWORD for the child process" {
  write_all_stubs
  export KEYCHAIN_VALUE="0123456789"
  run "$SCRIPT" --force
  assert_success
  run cat "$STATEFILE"
  assert_output --partial "env OPENCODE_SERVER_PASSWORD_LEN=10"
}

@test "opencode-attach: exports default OPENCODE_SERVER_USERNAME=opencode" {
  write_all_stubs
  export KEYCHAIN_VALUE="x"
  run "$SCRIPT" --force
  assert_success
  run cat "$STATEFILE"
  assert_output --partial "env OPENCODE_SERVER_USERNAME=opencode"
}

@test "opencode-attach: respects OPENCODE_SERVER_USERNAME override" {
  write_all_stubs
  export KEYCHAIN_VALUE="x"
  export OPENCODE_SERVER_USERNAME="hunter"
  run "$SCRIPT" --force
  assert_success
  run cat "$STATEFILE"
  assert_output --partial "env OPENCODE_SERVER_USERNAME=hunter"
}

@test "opencode-attach: OPENCODE_WEB_PORT/HOSTNAME override default URL" {
  write_all_stubs
  export KEYCHAIN_VALUE="x"
  export OPENCODE_WEB_PORT="5555"
  export OPENCODE_WEB_HOSTNAME="0.0.0.0"
  run "$SCRIPT" --force
  assert_success
  run cat "$STATEFILE"
  assert_output --partial "opencode attach http://0.0.0.0:5555"
}

@test "opencode-attach: never prints the password to stdout/stderr" {
  write_all_stubs
  export KEYCHAIN_VALUE="THIS_PASSWORD_MUST_NEVER_LEAK"
  run "$SCRIPT" --force
  assert_success
  refute_output --partial "THIS_PASSWORD_MUST_NEVER_LEAK"
}

# --- bash 3.2 portability regression ---------------------------------------
#
# macOS still ships /bin/bash at version 3.2, and so does GitHub's
# `macos-latest` runner under `#!/usr/bin/env bash`. Under `set -u`, bash 3.2
# raises "unbound variable" for "${arr[@]}" when arr is an empty array — a
# trap newer bash (≥4.4) silently tolerates. This test pins the happy path
# to /bin/bash so any regression of that idiom in the script is caught
# locally, not on CI.

@test "opencode-attach: happy path is bash 3.2 safe (empty PASSTHROUGH array)" {
  [[ -x /bin/bash ]] || skip "no /bin/bash on host"
  write_all_stubs
  export KEYCHAIN_VALUE="x"
  # Invoke the script via /bin/bash explicitly to bypass the env(1) PATH
  # lookup that would otherwise pick up /opt/homebrew/bin/bash.
  run /bin/bash "$SCRIPT" --force
  assert_success
  run cat "$STATEFILE"
  assert_output --partial "opencode attach http://127.0.0.1:4096"
}

# --- staleness / daemon-presence tests ------------------------------------
#
# These exercise the new opencode-daemon helper integration: presence check,
# fresh/stale sidecar handling, /dev/tty prompt path, force bypass.

@test "opencode-attach: no daemon at port → exit 5 with actionable message" {
  write_all_stubs
  arm_no_daemon
  export KEYCHAIN_VALUE="x"
  run "$SCRIPT"
  assert_failure 5
  assert_output --partial "no opencode daemon at :4096"
  assert_output --partial "openweb"
}

@test "opencode-attach: fresh daemon → silent attach (no warn, no prompt)" {
  write_all_stubs
  arm_fresh_daemon
  export KEYCHAIN_VALUE="x"
  run "$SCRIPT"
  assert_success
  refute_output --partial "Stale daemon"
  refute_output --partial "no config-hash sidecar"
  run cat "$STATEFILE"
  assert_output --partial "opencode attach http://127.0.0.1:4096"
}

@test "opencode-attach: stale daemon + no /dev/tty → exit 5 with bypass instructions" {
  # Force the no-tty branch via setsid -w (detach controlling tty). Skip
  # if setsid isn't available AND a /dev/tty IS reachable (means we can't
  # reliably exercise the no-tty branch).
  if { : >/dev/tty; } 2>/dev/null; then
    if ! command -v setsid >/dev/null 2>&1; then
      skip "no setsid(1) and /dev/tty is reachable — cannot test no-tty branch"
    fi
    write_all_stubs
    arm_stale_daemon
    export KEYCHAIN_VALUE="x"
    run setsid -w "$SCRIPT"
  else
    write_all_stubs
    arm_stale_daemon
    export KEYCHAIN_VALUE="x"
    run "$SCRIPT"
  fi
  assert_failure 5
  assert_output --partial "stale daemon on :4096"
  assert_output --partial "OPENCODE_ATTACH_FORCE=1"
  assert_output --partial "openweb --restart"
}

@test "opencode-attach: --force bypasses staleness check on stale daemon" {
  write_all_stubs
  arm_stale_daemon
  export KEYCHAIN_VALUE="x"
  run "$SCRIPT" --force
  assert_success
  refute_output --partial "Stale daemon"
  run cat "$STATEFILE"
  assert_output --partial "opencode attach http://127.0.0.1:4096"
}

@test "opencode-attach: OPENCODE_ATTACH_FORCE=1 also bypasses staleness check" {
  write_all_stubs
  arm_stale_daemon
  export KEYCHAIN_VALUE="x"
  export OPENCODE_ATTACH_FORCE=1
  run "$SCRIPT"
  assert_success
  run cat "$STATEFILE"
  assert_output --partial "opencode attach http://127.0.0.1:4096"
}

@test "opencode-attach: missing sidecar treated-as-stale (verified via no-tty branch)" {
  # The plan calls for a "sidecar-missing → warn + treat as stale" assertion.
  # Easiest deterministic path: arm a missing-sidecar daemon, force the
  # no-tty branch, and assert we exit 5 with the stale-daemon message
  # (the warn from is_stale is on stderr, captured in the run output).
  if { : >/dev/tty; } 2>/dev/null && ! command -v setsid >/dev/null 2>&1; then
    skip "no setsid(1) and /dev/tty is reachable — cannot test no-tty branch"
  fi
  write_all_stubs
  arm_missing_sidecar_daemon
  export KEYCHAIN_VALUE="x"
  if { : >/dev/tty; } 2>/dev/null; then
    run setsid -w "$SCRIPT"
  else
    run "$SCRIPT"
  fi
  assert_failure 5
  # The warn fires (sidecar missing), then the no-tty die_upstream.
  assert_output --partial "no config-hash sidecar"
  assert_output --partial "stale daemon on :4096"
}

@test "stale daemon: real pty path prompts and aborts on N (script(1))" {
  # Integration test — uses BSD script(1) to allocate a real pty so the
  # /dev/tty codepath runs against a kernel pty (not stub fds). Pinned by
  # plan §"Implementation gotchas" as the canonical test that proves
  # `{ : >/dev/tty; } 2>/dev/null` works as a TTY gate.
  command -v script >/dev/null 2>&1 || skip "no script(1) available"
  write_all_stubs
  arm_stale_daemon
  export KEYCHAIN_VALUE="x"
  # BSD script(1) exports SCRIPT to the spawned shell (typescript path),
  # which would collide with our wrapper variable. Save and unset.
  local script_path="$SCRIPT"
  unset SCRIPT
  # Feed 'n\n' via stdin; script(1) runs the wrapper inside a real pty.
  # `|| true` because script(1)'s exit code passthrough is variable across
  # platforms — we assert via the captured typescript content.
  if [[ "$(uname -s)" == "Linux" ]]; then
    # GNU script (util-linux): requires -c for command
    echo n | script -q "$BATS_TEST_TMPDIR/pty.out" -c "$script_path" || true
  else
    # BSD script (macOS): command is positional
    echo n | script -q "$BATS_TEST_TMPDIR/pty.out" "$script_path" || true
  fi
  SCRIPT="$script_path"
  grep -q "Continue attaching" "$BATS_TEST_TMPDIR/pty.out"
}

@test "stale daemon: real pty path proceeds on Y (covered by --force)" {
  # The "proceed after Y" path on a real pty cannot be exercised reliably with
  # BSD script(1) on macOS — script(1) does NOT forward its stdin to the pty's
  # /dev/tty, so `read … </dev/tty` in the wrapper blocks indefinitely. expect(1)
  # would work but adds a tool dep and is not in the project's test toolchain.
  #
  # Coverage for "proceed-after-warning" is provided by:
  #   - test 25 (--force bypass) and test 26 (OPENCODE_ATTACH_FORCE=1 bypass),
  #     which prove the post-warning exec path reaches `opencode attach`.
  #   - test 28 (real pty path prompts and aborts on N), which proves the
  #     /dev/tty prompt renders against a real kernel pty.
  # Together these cover the Y-branch behavior without an expect(1) dependency.
  skip "BSD script(1) cannot drive /dev/tty input; covered by tests 25/26/28"
}
