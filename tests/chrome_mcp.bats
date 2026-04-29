#!/usr/bin/env bats
# CLI parsing tests for agent/chrome_mcp.sh.
# We stub the Chrome binary, `pkill`, `osascript`, and `open` so the script
# runs to completion without launching anything real.

setup() {
  load 'test_helper/bats-support/load'
  load 'test_helper/bats-assert/load'
  SCRIPT="$BATS_TEST_DIRNAME/../agent/chrome_mcp.sh"

  STUBDIR="$(mktemp -d)"
  export PATH="$STUBDIR:$PATH"
  export FAKE_CHROME="$STUBDIR/Chrome"

  # Default: a stub Chrome binary that just records its argv.
  cat >"$FAKE_CHROME" <<'EOF'
#!/usr/bin/env bash
echo "fake-chrome-args: $*"
EOF
  chmod +x "$FAKE_CHROME"

  # Stub `pkill` and `open` so detached mode doesn't actually shell out.
  for cmd in pkill open osascript; do
    cat >"$STUBDIR/$cmd" <<EOF
#!/usr/bin/env bash
echo "fake-$cmd: \$*"
exit 0
EOF
    chmod +x "$STUBDIR/$cmd"
  done
}

teardown() {
  [[ -d "$STUBDIR" ]] && rm -rf "$STUBDIR"
}

# --- --help / -h --------------------------------------------------------------

@test "chrome_mcp: --help exits 0 and prints usage" {
  run "$SCRIPT" --help
  assert_success
  assert_output --partial "Usage:"
  assert_output --partial "chrome-mcp"
}

@test "chrome_mcp: -h exits 0 and prints usage" {
  run "$SCRIPT" -h
  assert_success
  assert_output --partial "Usage:"
}

# --- exit codes per convention -----------------------------------------------

@test "chrome_mcp: unknown flag exits 2 (usage error)" {
  run "$SCRIPT" --bogus
  assert_failure 2
  assert_output --partial "Unknown option:"
}

@test "chrome_mcp: --url without value exits 2" {
  run "$SCRIPT" --url
  assert_failure 2
  assert_output --partial "Usage error:"
}

@test "chrome_mcp: --port without value exits 2" {
  run "$SCRIPT" --port
  assert_failure 2
}

@test "chrome_mcp: --user-data-dir without value exits 2" {
  run "$SCRIPT" --user-data-dir
  assert_failure 2
}

@test "chrome_mcp: --new-tab + --new-window combo exits 2" {
  run "$SCRIPT" --new-tab --new-window
  assert_failure 2
  assert_output --partial "Cannot use --new-tab and --new-window together"
}

@test "chrome_mcp: missing Chrome binary exits 3 (missing dep)" {
  # Make a one-off copy of the script with CHROME_BIN pointing at a
  # nonexistent path; copy it next to lib/ so its sibling-resolution still
  # finds common.sh.
  tmp_script="$BATS_TEST_DIRNAME/../agent/.tmp_chrome_mcp_nochrome.sh"
  sed 's|^CHROME_BIN=.*|CHROME_BIN="/nonexistent/Chrome"|' "$SCRIPT" >"$tmp_script"
  chmod +x "$tmp_script"
  run "$tmp_script"
  rm -f "$tmp_script"
  assert_failure 3
  assert_output --partial "Missing dependency:"
}

# --- --check + --kill ---------------------------------------------------------

@test "chrome_mcp: --check exits 1 when no matching Chrome instance" {
  # Use a port unlikely to collide with any running Chrome.
  run "$SCRIPT" --check --port 59999 --user-data-dir "/tmp/bats-chrome-mcp-no-such-$$"
  assert_failure 1
}

@test "chrome_mcp: --kill exits 0 and prints status" {
  run "$SCRIPT" --kill
  assert_success
  assert_output --partial "Killed Chrome on port"
}

# --- arg passthrough sanity (using stubbed Chrome) ----------------------------

@test "chrome_mcp: foreground mode passes URL and port to Chrome" {
  # Place tmp script next to lib/ so common.sh resolves.
  tmp_script="$BATS_TEST_DIRNAME/../agent/.tmp_chrome_mcp_stubbed.sh"
  sed "s|^CHROME_BIN=.*|CHROME_BIN=\"$FAKE_CHROME\"|" "$SCRIPT" >"$tmp_script"
  chmod +x "$tmp_script"
  run "$tmp_script" --foreground --port 9333 --url "https://example.com"
  rm -f "$tmp_script"
  assert_success
  assert_output --partial "fake-chrome-args:"
  assert_output --partial "--remote-debugging-port=9333"
  assert_output --partial "https://example.com"
}
