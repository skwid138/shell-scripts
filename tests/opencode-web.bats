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

# Stub `caffeinate` so it does NOT actually exec; just logs args and the
# command tail (so tests can verify what would have been run).
write_caffeinate_stub() {
  cat >"$STUBDIR/caffeinate" <<'EOF'
#!/usr/bin/env bash
echo "caffeinate $*" >>"$STATEFILE"
# Also log relevant exported env vars so tests can assert they were set.
echo "env OPENCODE_SERVER_USERNAME=${OPENCODE_SERVER_USERNAME-}" >>"$STATEFILE"
echo "env OPENCODE_SERVER_PASSWORD_LEN=${#OPENCODE_SERVER_PASSWORD}" >>"$STATEFILE"
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

# Convenience: stub everything except KEYCHAIN_VALUE which the test sets.
write_all_stubs() {
  write_security_stub
  write_caffeinate_stub
  write_opencode_stub
  write_tailscale_stub
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
  # Restrict PATH to only system locations + our stub dir, but DON'T provide
  # an opencode stub. caffeinate exists in /usr/bin on macOS.
  PATH="/usr/bin:/bin" run "$SCRIPT"
  assert_failure 3
  assert_output --partial "opencode"
}

@test "opencode-web: missing caffeinate exits 3" {
  write_opencode_stub
  # Build an isolated PATH containing ONLY $STUBDIR plus symlinks to the
  # handful of real binaries the script actually needs to start and reach
  # the caffeinate dependency check:
  #   - bash:    `#!/usr/bin/env bash` — env(1) searches PATH for bash
  #   - dirname: used by SCRIPT_DIR resolution at the top of the script
  # caffeinate is intentionally NOT linked, so require_cmd caffeinate fires
  # and exits 3. Environment-independent: works whether the host's
  # caffeinate lives in /usr/bin (macOS) or anywhere else.
  for bin in bash dirname; do
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
  write_all_stubs
  export KEYCHAIN_VALUE="x"
  export OPENCODE_WEB_PORT="5555"
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
  # Provide everything EXCEPT tailscale. Restrict PATH to stubdir + minimal
  # system dirs to ensure the real /Applications/.../tailscale CLI is not
  # picked up by `command -v tailscale` in the wrapper.
  write_security_stub
  write_caffeinate_stub
  write_opencode_stub
  export KEYCHAIN_VALUE="x"
  PATH="$STUBDIR:/usr/bin:/bin" run "$SCRIPT"
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
