#!/usr/bin/env bats
# CLI tests for personal/tmux-sessionizer.sh
#
# We stub `tmux`, `fzf`, and `fd` via PATH override so tests don't depend on a
# real tmux server, an interactive picker, or a particular filesystem layout.
# A per-test STATEFILE captures every stub invocation so we can assert the
# exact tmux command sequence (has-session → new-session → switch-client/etc).

setup() {
  load 'test_helper/bats-support/load'
  load 'test_helper/bats-assert/load'
  SCRIPT="$BATS_TEST_DIRNAME/../personal/tmux-sessionizer.sh"

  STUBDIR="$(mktemp -d)"
  STATEFILE="$STUBDIR/calls.log"
  export PATH="$STUBDIR:$PATH"
  export STATEFILE

  # Default: NOT inside tmux (TMUX env var unset).
  unset TMUX
}

teardown() {
  [[ -d "$STUBDIR" ]] && rm -rf "$STUBDIR"
}

# --- helpers -----------------------------------------------------------------

# Write a tmux stub. Behavior controlled by env vars:
#   TMUX_HAS_SESSION_NO_ARG_RC : exit code when called as `tmux has-session`
#                                (no -t). Default 0 (server running).
#   TMUX_HAS_SESSION_NAMED_RC  : exit code when called as `tmux has-session -t=NAME`.
#                                Default 1 (session does NOT exist → will create).
write_tmux_stub() {
  cat >"$STUBDIR/tmux" <<'EOF'
#!/usr/bin/env bash
# Log every invocation, one line per call.
echo "tmux $*" >>"$STATEFILE"
case "$1" in
  has-session)
    if [[ "${2:-}" == -t=* ]]; then
      exit "${TMUX_HAS_SESSION_NAMED_RC:-1}"
    fi
    exit "${TMUX_HAS_SESSION_NO_ARG_RC:-0}"
    ;;
  new-session|switch-client|attach-session)
    exit 0
    ;;
  *)
    echo "unexpected tmux args: $*" >&2
    exit 99
    ;;
esac
EOF
  chmod +x "$STUBDIR/tmux"
}

# Write fzf + fd stubs. FZF_PICK is the line fzf prints to stdout (or empty
# = user cancelled).
write_picker_stubs() {
  cat >"$STUBDIR/fd" <<'EOF'
#!/usr/bin/env bash
# Just print the FD_OUTPUT env var (newline-separated list of dirs).
printf '%s\n' "${FD_OUTPUT:-}"
EOF
  chmod +x "$STUBDIR/fd"

  cat >"$STUBDIR/fzf" <<'EOF'
#!/usr/bin/env bash
# Discard stdin; print the configured pick.
cat >/dev/null
printf '%s\n' "${FZF_PICK:-}"
EOF
  chmod +x "$STUBDIR/fzf"
}

# --- --help / usage ----------------------------------------------------------

@test "tmux-sessionizer: --help exits 0 and prints usage" {
  write_tmux_stub
  run "$SCRIPT" --help
  assert_success
  assert_output --partial "Usage: tmux-sessionizer"
  assert_output --partial "TMUX_SESSIONIZER_DIRS"
}

@test "tmux-sessionizer: -h exits 0 and prints usage" {
  write_tmux_stub
  run "$SCRIPT" -h
  assert_success
  assert_output --partial "Usage: tmux-sessionizer"
}

@test "tmux-sessionizer: unknown flag exits 2 with usage error" {
  write_tmux_stub
  run "$SCRIPT" --bogus
  assert_failure 2
  assert_output --partial "unknown flag"
}

# --- direct path arg (no fzf path) -------------------------------------------

@test "tmux-sessionizer: direct path with new session creates and attaches" {
  write_tmux_stub
  # Server has no sessions → fall through to plain new-session attach.
  TMUX_HAS_SESSION_NO_ARG_RC=1 run "$SCRIPT" "$BATS_TEST_TMPDIR"
  assert_success
  # First (and only relevant) invocation should be `tmux new-session -s NAME -c PATH`.
  run cat "$STATEFILE"
  assert_output --partial "new-session -s"
  assert_output --partial "$BATS_TEST_TMPDIR"
}

@test "tmux-sessionizer: direct path with running server, no existing session: creates detached + attaches" {
  write_tmux_stub
  # Server running (rc=0), session not found (rc=1).
  TMUX_HAS_SESSION_NO_ARG_RC=0 TMUX_HAS_SESSION_NAMED_RC=1 \
    run "$SCRIPT" "$BATS_TEST_TMPDIR"
  assert_success
  run cat "$STATEFILE"
  assert_output --partial "new-session -ds"
  assert_output --partial "attach-session -t"
}

@test "tmux-sessionizer: direct path with running server + existing session: skips new-session" {
  write_tmux_stub
  TMUX_HAS_SESSION_NO_ARG_RC=0 TMUX_HAS_SESSION_NAMED_RC=0 \
    run "$SCRIPT" "$BATS_TEST_TMPDIR"
  assert_success
  run cat "$STATEFILE"
  refute_output --partial "new-session"
  assert_output --partial "attach-session -t"
}

@test "tmux-sessionizer: inside tmux uses switch-client, not attach-session" {
  write_tmux_stub
  TMUX_HAS_SESSION_NO_ARG_RC=0 TMUX_HAS_SESSION_NAMED_RC=1 \
    TMUX="/tmp/fake-tmux-socket" run "$SCRIPT" "$BATS_TEST_TMPDIR"
  assert_success
  run cat "$STATEFILE"
  assert_output --partial "switch-client -t"
  refute_output --partial "attach-session"
}

@test "tmux-sessionizer: rejects non-directory arg" {
  write_tmux_stub
  TMUX_HAS_SESSION_NO_ARG_RC=0 \
    run "$SCRIPT" "/definitely/does/not/exist/anywhere"
  assert_failure 1
  assert_output --partial "Not a directory"
}

# --- session name sanitization ----------------------------------------------

@test "tmux-sessionizer: sanitizes dots in session name" {
  write_tmux_stub
  mkdir -p "$BATS_TEST_TMPDIR/foo.bar.baz"
  TMUX_HAS_SESSION_NO_ARG_RC=1 \
    run "$SCRIPT" "$BATS_TEST_TMPDIR/foo.bar.baz"
  assert_success
  run cat "$STATEFILE"
  # Assert the exact session-name token after `-s`, not just absence of the
  # full path (which the `-c` arg legitimately contains).
  assert_output --partial "new-session -s foo_bar_baz"
}

@test "tmux-sessionizer: sanitizes colons in session name" {
  write_tmux_stub
  mkdir -p "$BATS_TEST_TMPDIR/has:colon"
  TMUX_HAS_SESSION_NO_ARG_RC=1 \
    run "$SCRIPT" "$BATS_TEST_TMPDIR/has:colon"
  assert_success
  run cat "$STATEFILE"
  assert_output --partial "has_colon"
}

# --- fzf path (no args) ------------------------------------------------------

@test "tmux-sessionizer: no args + fzf cancel exits 0 silently" {
  write_tmux_stub
  write_picker_stubs
  mkdir -p "$BATS_TEST_TMPDIR/projects"
  export TMUX_SESSIONIZER_DIRS="$BATS_TEST_TMPDIR/projects"
  export FD_OUTPUT="$BATS_TEST_TMPDIR/projects/p1"
  export FZF_PICK="" # user pressed Esc
  run "$SCRIPT"
  assert_success
  # No tmux session-creating commands should have been invoked.
  run cat "$STATEFILE"
  refute_output --partial "new-session"
  refute_output --partial "switch-client"
}

@test "tmux-sessionizer: no args + fzf pick uses the chosen path" {
  write_tmux_stub
  write_picker_stubs
  mkdir -p "$BATS_TEST_TMPDIR/projects/picked"
  export TMUX_SESSIONIZER_DIRS="$BATS_TEST_TMPDIR/projects"
  export FD_OUTPUT="$BATS_TEST_TMPDIR/projects/picked"
  export FZF_PICK="$BATS_TEST_TMPDIR/projects/picked"
  TMUX_HAS_SESSION_NO_ARG_RC=0 TMUX_HAS_SESSION_NAMED_RC=1 run "$SCRIPT"
  assert_success
  run cat "$STATEFILE"
  assert_output --partial "new-session -ds picked"
}

@test "tmux-sessionizer: no args with no existing project dirs fails clearly" {
  write_tmux_stub
  write_picker_stubs
  export TMUX_SESSIONIZER_DIRS="/nonexistent/a:/nonexistent/b"
  run "$SCRIPT"
  assert_failure 1
  assert_output --partial "No project dirs exist"
}

# --- dependency gating -------------------------------------------------------

@test "tmux-sessionizer: missing tmux exits 3 with install hint" {
  # Don't write tmux stub. PATH points at STUBDIR plus minimal system dirs
  # (so the script's `#!/usr/bin/env bash` shebang and `dirname`/`basename`
  # still resolve), but tmux itself is absent from STUBDIR.
  #
  # On Ubuntu CI runners, tmux is pre-installed at /usr/bin/tmux, so the
  # require_cmd guard finds it via the /usr/bin fallback in PATH and the
  # script proceeds — failing later with "open terminal failed: not a
  # terminal" when tmux tries to attach. The test's invariant ("missing
  # tmux exits 3") only holds on hosts where tmux isn't on the bare
  # system PATH; skip elsewhere rather than fight environment skew.
  if [[ -x /usr/bin/tmux || -x /bin/tmux ]]; then
    skip "tmux is available on the system PATH; can't simulate 'missing' without breaking shebang resolution"
  fi
  PATH="$STUBDIR:/usr/bin:/bin" run "$SCRIPT" "$BATS_TEST_TMPDIR"
  assert_failure 3
  assert_output --partial "tmux"
}
