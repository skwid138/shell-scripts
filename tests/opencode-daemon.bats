#!/usr/bin/env bats
# Unit tests for lib/opencode-daemon.sh
#
# Strategy:
#   - The hash function is exercised against REAL fixture trees (no shasum stub) —
#     it's a thin wrapper around shasum + find and stubbing them would test
#     nothing. Each test creates a self-contained $OPENCODE_CONFIG_DIR fixture
#     under BATS_TEST_TMPDIR.
#   - Identity / listener / kill / wait functions are exercised against PATH
#     stubs (ps, lsof, pgrep) writing to a STATEFILE for assertion.
#   - Sidecar tests use the real filesystem under BATS_TEST_TMPDIR via
#     $OPENCODE_DAEMON_STATE_DIR override. No mocks.
#   - prompt_continue_on_stale is tested by wiring fds 3/4 to here-strings /
#     tempfiles; no /dev/tty involvement (that's covered separately by an
#     openattach script(1) integration test).

setup() {
  load 'test_helper/bats-support/load'
  load 'test_helper/bats-assert/load'

  LIB="$BATS_TEST_DIRNAME/../lib/opencode-daemon.sh"
  [[ -r "$LIB" ]] || {
    echo "missing helper: $LIB"
    return 1
  }

  # Per-test sandbox. BATS_TEST_TMPDIR is auto-cleaned, no manual teardown.
  export OPENCODE_CONFIG_DIR="$BATS_TEST_TMPDIR/config"
  export OPENCODE_DAEMON_STATE_DIR="$BATS_TEST_TMPDIR/state"
  mkdir -p "$OPENCODE_CONFIG_DIR" "$OPENCODE_DAEMON_STATE_DIR"

  STUBDIR="$BATS_TEST_TMPDIR/stubs"
  mkdir -p "$STUBDIR"
  STATEFILE="$BATS_TEST_TMPDIR/calls.log"
  : >"$STATEFILE"
  export STATEFILE

  # Keep real shasum/find/sort/grep/awk/mkdir on PATH; only the stub dir wins
  # for stubbed commands.
  export PATH="$STUBDIR:$PATH"

  # Re-source the helper fresh for every test (guard already prevents double-source
  # in a single shell, but bats spawns a new shell per test so it's a no-op here).
  unset _LIB_OPENCODE_DAEMON_LOADED
}

# --- fixture helpers --------------------------------------------------------

# Build a minimal $OPENCODE_CONFIG_DIR that mirrors the real layout enough
# to exercise include / exclude rules.
make_config_fixture() {
  mkdir -p "$OPENCODE_CONFIG_DIR"/{agent,instruction,skill,mcp,plugins,command,bin,logs,node_modules,.project-plans,.git}
  echo '{"foo":1}' >"$OPENCODE_CONFIG_DIR/opencode.json"
  echo '{"name":"x"}' >"$OPENCODE_CONFIG_DIR/package.json"
  echo '{}' >"$OPENCODE_CONFIG_DIR/dcp.jsonc"
  echo 'agent-content' >"$OPENCODE_CONFIG_DIR/agent/foo.md"
  echo 'inst' >"$OPENCODE_CONFIG_DIR/instruction/x.md"
  echo 'skill' >"$OPENCODE_CONFIG_DIR/skill/y.md"
  echo 'mcp' >"$OPENCODE_CONFIG_DIR/mcp/m.json"
  echo 'plugin' >"$OPENCODE_CONFIG_DIR/plugins/p.js"
  echo 'cmd' >"$OPENCODE_CONFIG_DIR/command/c.md"
  echo 'gitignore' >"$OPENCODE_CONFIG_DIR/.gitignore"
  echo '18' >"$OPENCODE_CONFIG_DIR/.nvmrc"
  # The ones that MUST be ignored:
  echo 'readme content' >"$OPENCODE_CONFIG_DIR/README.md"
  echo 'remote' >"$OPENCODE_CONFIG_DIR/README-remote-access.md"
  echo '{"lockfileVersion":3}' >"$OPENCODE_CONFIG_DIR/package-lock.json"
  echo 'log noise' >"$OPENCODE_CONFIG_DIR/logs/run.log"
  mkdir -p "$OPENCODE_CONFIG_DIR/node_modules/foo"
  echo 'dep' >"$OPENCODE_CONFIG_DIR/node_modules/foo/index.js"
  echo 'plan content' >"$OPENCODE_CONFIG_DIR/.project-plans/note.md"
  echo 'git ref' >"$OPENCODE_CONFIG_DIR/.git/HEAD"
  # Symlink: bin/opencode → arbitrary path
  ln -sf "/tmp/real-opencode-wrapper.sh" "$OPENCODE_CONFIG_DIR/bin/opencode"
}

# Write a ps stub whose response to `ps -o comm= -p <pid>` is configurable via
# a per-pid mapping file at $STUBDIR/ps-comm-map (pid<TAB>comm per line).
write_ps_stub() {
  cat >"$STUBDIR/ps" <<'EOF'
#!/usr/bin/env bash
echo "ps $*" >>"$STATEFILE"
# Only mock the `ps -o comm= -p PID` form we care about; for `ps -o lstart=`
# fall through to /bin/ps so opencode_daemon_start_epoch still works against
# real pids in the few tests that need it.
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

# Set the pid → comm mapping for the ps stub.
set_ps_comm() {
  local pid="$1" comm="$2"
  printf '%s\t%s\n' "$pid" "$comm" >>"$STUBDIR/ps-comm-map"
}

# lsof stub. Returns whatever pid the test set via $STUBDIR/lsof-map for
# the requested port (or empty).
write_lsof_stub() {
  cat >"$STUBDIR/lsof" <<'EOF'
#!/usr/bin/env bash
echo "lsof $*" >>"$STATEFILE"
# Match `lsof -ti tcp:PORT -sTCP:LISTEN`
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

# === opencode_config_relevant_files ========================================

@test "config_relevant_files: returns expected entries on a realistic fixture" {
  make_config_fixture
  run bash -c "source '$LIB' && opencode_config_relevant_files | tr '\0' '\n'"
  assert_success
  # Spot-check included paths
  assert_output --partial "opencode.json"
  assert_output --partial "package.json"
  assert_output --partial "dcp.jsonc"
  assert_output --partial "agent/foo.md"
  assert_output --partial "mcp/m.json"
  assert_output --partial "plugins/p.js"
  assert_output --partial "command/c.md"
  assert_output --partial "bin/opencode" # symlink
  assert_output --partial ".gitignore"
  assert_output --partial ".nvmrc"
}

@test "config_relevant_files: excludes README*.md, .project-plans, logs, node_modules, package-lock, .git" {
  make_config_fixture
  run bash -c "source '$LIB' && opencode_config_relevant_files | tr '\0' '\n'"
  assert_success
  refute_output --partial "README.md"
  refute_output --partial "README-remote-access.md"
  refute_output --partial ".project-plans/note.md"
  refute_output --partial "logs/run.log"
  refute_output --partial "node_modules/foo/index.js"
  refute_output --partial "package-lock.json"
  refute_output --partial ".git/HEAD"
}

@test "config_relevant_files: empty config dir → no output" {
  rm -rf "$OPENCODE_CONFIG_DIR"
  mkdir -p "$OPENCODE_CONFIG_DIR"
  run bash -c "source '$LIB' && opencode_config_relevant_files | tr '\0' '\n'"
  assert_success
  assert_output ""
}

# === opencode_config_content_hash ==========================================

@test "content_hash: deterministic — same fixture, same digest across runs" {
  make_config_fixture
  run bash -c "source '$LIB' && opencode_config_content_hash"
  assert_success
  local h1="$output"
  run bash -c "source '$LIB' && opencode_config_content_hash"
  assert_success
  assert_output "$h1"
  # Must be 64-char hex.
  [[ "$h1" =~ ^[0-9a-f]{64}$ ]]
}

@test "content_hash: changes when an INCLUDED file's content changes" {
  make_config_fixture
  run bash -c "source '$LIB' && opencode_config_content_hash"
  local before="$output"
  echo '{"foo":2}' >"$OPENCODE_CONFIG_DIR/opencode.json"
  run bash -c "source '$LIB' && opencode_config_content_hash"
  refute_output "$before"
}

@test "content_hash: does NOT change when an IGNORED file changes" {
  make_config_fixture
  run bash -c "source '$LIB' && opencode_config_content_hash"
  local before="$output"
  # Mutate every ignored category
  echo 'new readme' >"$OPENCODE_CONFIG_DIR/README.md"
  echo 'noisier logs' >>"$OPENCODE_CONFIG_DIR/logs/run.log"
  echo 'newer plan' >"$OPENCODE_CONFIG_DIR/.project-plans/note.md"
  echo '{"lockfileVersion":4}' >"$OPENCODE_CONFIG_DIR/package-lock.json"
  echo 'newer dep' >"$OPENCODE_CONFIG_DIR/node_modules/foo/index.js"
  echo 'newer git ref' >"$OPENCODE_CONFIG_DIR/.git/HEAD"
  run bash -c "source '$LIB' && opencode_config_content_hash"
  assert_output "$before"
}

@test "content_hash: changes when an INCLUDED file is added" {
  make_config_fixture
  run bash -c "source '$LIB' && opencode_config_content_hash"
  local before="$output"
  echo 'fresh' >"$OPENCODE_CONFIG_DIR/agent/new.md"
  run bash -c "source '$LIB' && opencode_config_content_hash"
  refute_output "$before"
}

@test "content_hash: changes when an INCLUDED file is removed" {
  make_config_fixture
  run bash -c "source '$LIB' && opencode_config_content_hash"
  local before="$output"
  rm "$OPENCODE_CONFIG_DIR/agent/foo.md"
  run bash -c "source '$LIB' && opencode_config_content_hash"
  refute_output "$before"
}

@test "content_hash: stable under permission-only changes" {
  make_config_fixture
  run bash -c "source '$LIB' && opencode_config_content_hash"
  local before="$output"
  chmod 644 "$OPENCODE_CONFIG_DIR/opencode.json"
  chmod 755 "$OPENCODE_CONFIG_DIR/opencode.json"
  run bash -c "source '$LIB' && opencode_config_content_hash"
  assert_output "$before"
}

@test "content_hash: stable under atomic byte-identical rewrite (vim :w pattern)" {
  make_config_fixture
  run bash -c "source '$LIB' && opencode_config_content_hash"
  local before="$output"
  # Atomic rewrite of identical content.
  cp "$OPENCODE_CONFIG_DIR/opencode.json" "$OPENCODE_CONFIG_DIR/opencode.json.tmp"
  mv "$OPENCODE_CONFIG_DIR/opencode.json.tmp" "$OPENCODE_CONFIG_DIR/opencode.json"
  run bash -c "source '$LIB' && opencode_config_content_hash"
  assert_output "$before"
}

@test "content_hash: symlink target change flips hash; identical target keeps it stable" {
  make_config_fixture
  run bash -c "source '$LIB' && opencode_config_content_hash"
  local before="$output"
  # Re-create symlink with identical target → hash stable.
  ln -sf "/tmp/real-opencode-wrapper.sh" "$OPENCODE_CONFIG_DIR/bin/opencode"
  run bash -c "source '$LIB' && opencode_config_content_hash"
  assert_output "$before"
  # Retarget → hash changes.
  ln -sf "/tmp/different-wrapper.sh" "$OPENCODE_CONFIG_DIR/bin/opencode"
  run bash -c "source '$LIB' && opencode_config_content_hash"
  refute_output "$before"
}

@test "content_hash: symlink hashes target STRING, not dereferenced content" {
  mkdir -p "$OPENCODE_CONFIG_DIR/bin"
  # Two different real files with same content; symlink points to one then the other.
  echo 'identical-body' >"$BATS_TEST_TMPDIR/a.sh"
  echo 'identical-body' >"$BATS_TEST_TMPDIR/b.sh"
  ln -sf "$BATS_TEST_TMPDIR/a.sh" "$OPENCODE_CONFIG_DIR/bin/opencode"
  run bash -c "source '$LIB' && opencode_config_content_hash"
  local before="$output"
  ln -sf "$BATS_TEST_TMPDIR/b.sh" "$OPENCODE_CONFIG_DIR/bin/opencode"
  run bash -c "source '$LIB' && opencode_config_content_hash"
  # Targets differ as STRINGS → hash MUST change even though dereferenced
  # contents are identical. This is the safety-net for the
  # escape-from-config-dir / circular-symlink threat model.
  refute_output "$before"
}

# === opencode_pid_is_opencode_web ==========================================

@test "pid_is_opencode_web: returns 0 for /opt/homebrew/bin/opencode (full path)" {
  write_ps_stub
  set_ps_comm 12345 "/opt/homebrew/bin/opencode"
  run bash -c "source '$LIB' && opencode_pid_is_opencode_web 12345"
  assert_success
}

@test "pid_is_opencode_web: returns 0 for bare 'opencode' (basename form)" {
  write_ps_stub
  set_ps_comm 12345 "opencode"
  run bash -c "source '$LIB' && opencode_pid_is_opencode_web 12345"
  assert_success
}

@test "pid_is_opencode_web: returns non-zero for /usr/bin/caffeinate" {
  write_ps_stub
  set_ps_comm 12345 "/usr/bin/caffeinate"
  run bash -c "source '$LIB' && opencode_pid_is_opencode_web 12345"
  assert_failure
}

@test "pid_is_opencode_web: returns non-zero when ps returns empty (process gone)" {
  write_ps_stub
  # No mapping for pid 99999 → stub exits non-zero → comm is empty
  run bash -c "source '$LIB' && opencode_pid_is_opencode_web 99999"
  assert_failure
}

@test "pid_is_opencode_web: returns non-zero when pid arg is empty" {
  write_ps_stub
  run bash -c "source '$LIB' && opencode_pid_is_opencode_web ''"
  assert_failure
}

# === opencode_daemon_pid_for_port ==========================================

@test "daemon_pid_for_port: returns 0+pid when listener is opencode-web" {
  write_lsof_stub
  write_ps_stub
  set_lsof_port 4096 7777
  set_ps_comm 7777 "/opt/homebrew/bin/opencode"
  run bash -c "source '$LIB' && opencode_daemon_pid_for_port 4096"
  assert_success
  assert_output "7777"
}

@test "daemon_pid_for_port: returns non-zero when no listener at all" {
  write_lsof_stub
  write_ps_stub
  run bash -c "source '$LIB' && opencode_daemon_pid_for_port 4096"
  assert_failure
  assert_output ""
}

@test "daemon_pid_for_port: returns non-zero when listener is some other process" {
  write_lsof_stub
  write_ps_stub
  set_lsof_port 4096 8888
  set_ps_comm 8888 "/usr/sbin/httpd"
  run bash -c "source '$LIB' && VERBOSE=1 opencode_daemon_pid_for_port 4096 2>&1"
  assert_failure
  # The debug() message includes the foreign pid+comm for diagnostics.
  assert_output --partial "8888"
}

# === opencode_wait_for_opencode_listener ===================================

@test "wait_for_opencode_listener: succeeds when listener appears and is opencode" {
  write_lsof_stub
  write_ps_stub
  set_lsof_port 4096 5555
  set_ps_comm 5555 "opencode"
  run bash -c "source '$LIB' && opencode_wait_for_opencode_listener 4096 1"
  assert_success
  assert_output "5555"
}

@test "wait_for_opencode_listener: fails fast with listener-identity error on foreign listener" {
  write_lsof_stub
  write_ps_stub
  set_lsof_port 4096 6666
  set_ps_comm 6666 "/usr/bin/nginx"
  run bash -c "source '$LIB' && opencode_wait_for_opencode_listener 4096 1"
  # die_upstream exits 5
  assert_failure 5
  assert_output --partial "port :4096 taken by pid 6666"
  assert_output --partial "nginx"
  assert_output --partial "not opencode"
}

@test "wait_for_opencode_listener: timeout returns non-zero when nothing binds" {
  write_lsof_stub
  write_ps_stub
  # No mapping → lsof stub always returns nothing. Timeout=1s for speed.
  run bash -c "source '$LIB' && opencode_wait_for_opencode_listener 4096 1"
  assert_failure
}

@test "wait_for_port_free: returns 0 immediately when no listener at start" {
  write_lsof_stub
  write_ps_stub
  # No mapping → lsof stub returns nothing on first call.
  run bash -c "source '$LIB' && opencode_wait_for_port_free 4096 1"
  assert_success
}

@test "wait_for_port_free: returns non-zero on timeout when port stays bound" {
  write_lsof_stub
  write_ps_stub
  set_lsof_port 4096 7777
  # No phase transition: port stays bound for the whole timeout window.
  run bash -c "source '$LIB' && opencode_wait_for_port_free 4096 1"
  assert_failure
}

@test "wait_for_port_free: returns 0 when port frees mid-wait" {
  # Custom stub: bound for the first 2 calls, free thereafter. Simulates
  # the user's kill-signal taking effect partway through our poll loop.
  cat >"$STUBDIR/lsof" <<EOF
#!/usr/bin/env bash
echo "lsof \$*" >>"\$(dirname "\$0")/.state"
n=\$(( \$(cat "\$(dirname "\$0")/lsof-count" 2>/dev/null || echo 0) + 1 ))
echo "\$n" >"\$(dirname "\$0")/lsof-count"
if (( n <= 2 )); then
  echo 8888
  exit 0
fi
exit 1
EOF
  chmod +x "$STUBDIR/lsof"
  write_ps_stub
  run bash -c "source '$LIB' && opencode_wait_for_port_free 4096 3"
  assert_success
}

# === sidecar lifecycle =====================================================

@test "write_sidecar: creates sidecar at expected path with 64-hex body" {
  make_config_fixture
  run bash -c "source '$LIB' && opencode_daemon_write_sidecar 4096 12345"
  assert_success
  local f="$OPENCODE_DAEMON_STATE_DIR/daemon-config-hash-4096-12345"
  [[ -f "$f" ]]
  local body
  body="$(<"$f")"
  [[ "$body" =~ ^[0-9a-f]{64}$ ]]
}

@test "write_sidecar: atomic — no .tmp.\$\$ leftover on success" {
  make_config_fixture
  bash -c "source '$LIB' && opencode_daemon_write_sidecar 4096 12345"
  # No tempfile detritus should remain.
  run bash -c "ls '$OPENCODE_DAEMON_STATE_DIR'/.daemon-config-hash-*.tmp.* 2>/dev/null || true"
  assert_output ""
}

@test "write_sidecar: creates state dir if missing" {
  make_config_fixture
  rm -rf "$OPENCODE_DAEMON_STATE_DIR"
  bash -c "source '$LIB' && opencode_daemon_write_sidecar 4096 12345"
  [[ -d "$OPENCODE_DAEMON_STATE_DIR" ]]
  [[ -f "$OPENCODE_DAEMON_STATE_DIR/daemon-config-hash-4096-12345" ]]
}

@test "is_stale: returns 1 (fresh) when sidecar matches current hash" {
  make_config_fixture
  bash -c "source '$LIB' && opencode_daemon_write_sidecar 4096 12345"
  run bash -c "source '$LIB' && opencode_daemon_is_stale 4096 12345"
  assert_failure
}

@test "is_stale: returns 0 (stale) + warn when sidecar is MISSING" {
  make_config_fixture
  # No sidecar written.
  run bash -c "source '$LIB' && opencode_daemon_is_stale 4096 12345 2>&1"
  assert_success
  assert_output --partial "no config-hash sidecar"
  assert_output --partial "crash-restart"
}

@test "is_stale: returns 0 (stale) + warn when sidecar is EMPTY" {
  make_config_fixture
  : >"$OPENCODE_DAEMON_STATE_DIR/daemon-config-hash-4096-12345"
  run bash -c "source '$LIB' && opencode_daemon_is_stale 4096 12345 2>&1"
  assert_success
  assert_output --partial "corrupt"
}

@test "is_stale: returns 0 (stale) + warn when sidecar is not 64 hex chars" {
  make_config_fixture
  echo "not-a-real-sha256" >"$OPENCODE_DAEMON_STATE_DIR/daemon-config-hash-4096-12345"
  run bash -c "source '$LIB' && opencode_daemon_is_stale 4096 12345 2>&1"
  assert_success
  assert_output --partial "corrupt"
}

@test "is_stale: returns 0 (stale) when sidecar hash differs from current hash" {
  make_config_fixture
  bash -c "source '$LIB' && opencode_daemon_write_sidecar 4096 12345"
  # Mutate an included file.
  echo '{"foo":2}' >"$OPENCODE_CONFIG_DIR/opencode.json"
  run bash -c "source '$LIB' && opencode_daemon_is_stale 4096 12345"
  assert_success
}

@test "remove_sidecar: idempotent — succeeds on missing sidecar" {
  run bash -c "source '$LIB' && opencode_daemon_remove_sidecar 4096 12345"
  assert_success
}

@test "remove_sidecar: deletes the matching file" {
  make_config_fixture
  bash -c "source '$LIB' && opencode_daemon_write_sidecar 4096 12345"
  bash -c "source '$LIB' && opencode_daemon_remove_sidecar 4096 12345"
  [[ ! -e "$OPENCODE_DAEMON_STATE_DIR/daemon-config-hash-4096-12345" ]]
}

# === concurrency regression: two ports, two sidecars =======================

@test "two openweb invocations on different ports produce non-colliding sidecars" {
  make_config_fixture
  bash -c "source '$LIB' && opencode_daemon_write_sidecar 4096 1111"
  bash -c "source '$LIB' && opencode_daemon_write_sidecar 4097 2222"
  [[ -f "$OPENCODE_DAEMON_STATE_DIR/daemon-config-hash-4096-1111" ]]
  [[ -f "$OPENCODE_DAEMON_STATE_DIR/daemon-config-hash-4097-2222" ]]
  # And they must contain the SAME hash (same config dir), pinning that the
  # filenames are the only thing port-distinguishing the sidecars.
  diff "$OPENCODE_DAEMON_STATE_DIR/daemon-config-hash-4096-1111" \
    "$OPENCODE_DAEMON_STATE_DIR/daemon-config-hash-4097-2222"
}

# === prompt_continue_on_stale ==============================================

@test "prompt: returns 0 on 'y' from fd 3" {
  out="$BATS_TEST_TMPDIR/fd4.out"
  # `script -q` not needed; we wire fd 3/4 directly.
  run bash -c "source '$LIB'; prompt_continue_on_stale 7777 0 4096 3<<<'y' 4>'$out'"
  assert_success
  run cat "$out"
  assert_output --partial "Stale daemon on :4096"
  assert_output --partial "Continue attaching anyway"
}

@test "prompt: returns 0 on 'Y' (uppercase)" {
  out="$BATS_TEST_TMPDIR/fd4.out"
  run bash -c "source '$LIB'; prompt_continue_on_stale 7777 0 4096 3<<<'Y' 4>'$out'"
  assert_success
}

@test "prompt: returns non-zero on 'n'" {
  out="$BATS_TEST_TMPDIR/fd4.out"
  run bash -c "source '$LIB'; prompt_continue_on_stale 7777 0 4096 3<<<'n' 4>'$out'"
  assert_failure
}

@test "prompt: returns non-zero on empty input (default N)" {
  out="$BATS_TEST_TMPDIR/fd4.out"
  run bash -c "source '$LIB'; prompt_continue_on_stale 7777 0 4096 3<<<'' 4>'$out'"
  assert_failure
}

@test "prompt: returns non-zero on EOF (closed fd 3)" {
  out="$BATS_TEST_TMPDIR/fd4.out"
  run bash -c "source '$LIB'; prompt_continue_on_stale 7777 0 4096 3</dev/null 4>'$out'"
  assert_failure
}

@test "prompt: writes to fd 4 only, never to stdout/stderr" {
  out="$BATS_TEST_TMPDIR/fd4.out"
  run bash -c "source '$LIB'; prompt_continue_on_stale 7777 0 4096 3<<<'n' 4>'$out'"
  # No prompt text leaked to bats-captured stdout/stderr.
  refute_output --partial "Continue attaching"
  refute_output --partial "Stale daemon"
}
