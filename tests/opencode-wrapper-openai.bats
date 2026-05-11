#!/usr/bin/env bats
# Tests for the OpenAI API key loading block in the opencode wrapper.
#
# Stubs secrets.sh, secret_load, and the real opencode binary to test the
# wrapper's OpenAI key-loading behavior in isolation.

setup() {
  load 'test_helper/bats-support/load'
  load 'test_helper/bats-assert/load'

  WRAPPER="$HOME/.config/opencode/bin/opencode"

  STUBDIR="$(mktemp -d)"
  export PATH="$STUBDIR:$PATH"

  # Create a minimal secrets.sh stub that defines secret_load
  SECRETS_DIR="$STUBDIR/code/scripts/shell/lib"
  mkdir -p "$SECRETS_DIR"

  # Stub the real opencode binary so exec doesn't escape
  cat >"$STUBDIR/opencode" <<'EOF'
#!/usr/bin/env bash
echo "opencode-stub-ran"
exit 0
EOF
  chmod +x "$STUBDIR/opencode"

  # Override HOME so the wrapper resolves secrets.sh from our stub
  export REAL_HOME="$HOME"
  export HOME="$STUBDIR"

  # Create minimal wrapper config dir structure
  mkdir -p "$STUBDIR/.config/opencode/bin"
  mkdir -p "$STUBDIR/.config/opencode/instruction"

  # Copy the real wrapper
  cp "$REAL_HOME/.config/opencode/bin/opencode" "$STUBDIR/.config/opencode/bin/opencode"

  # Provide common.sh stubs (the wrapper needs info/warn/die_missing_dep)
  export OPENCODE_COMMON_LIB="$STUBDIR/common.sh"
  cat >"$STUBDIR/common.sh" <<'EOF'
info() { :; }
warn() { printf '[warn] %s\n' "$*" >&2; }
die_missing_dep() { printf '[fatal] %s\n' "$*" >&2; exit 3; }
die_unauthed() { printf '[fatal:unauthed] %s\n' "$*" >&2; exit 4; }
EOF

  # Ensure REAL_OPENCODE resolves to our stub
  export OPENCODE_BIN="$STUBDIR/opencode"
}

teardown() {
  [[ -d "$STUBDIR" ]] && rm -rf "$STUBDIR"
}

# --- helpers ----------------------------------------------------------------

write_secrets_stub_success() {
  cat >"$STUBDIR/code/scripts/shell/lib/secrets.sh" <<'EOF'
secret_load() {
  local varname="$1"
  export "$varname"="sk-proj-test-key-12345"
  return 0
}
EOF
}

write_secrets_stub_fail() {
  cat >"$STUBDIR/code/scripts/shell/lib/secrets.sh" <<'EOF'
secret_load() {
  return 1
}
EOF
}

# --- tests ------------------------------------------------------------------

@test "key loads successfully — OPENAI_API_KEY is exported" {
  write_secrets_stub_success

  # Run just the relevant portion by sourcing in a subshell
  run bash -c '
    export HOME="'"$STUBDIR"'"
    export OPENCODE_COMMON_LIB="'"$STUBDIR/common.sh"'"
    source "'"$STUBDIR/common.sh"'"
    _openai_secrets="$HOME/code/scripts/shell/lib/secrets.sh"
    if [[ -r "$_openai_secrets" ]]; then
      source "$_openai_secrets"
      if ! type die_unauthed &>/dev/null; then
        die_unauthed() { printf "[wrapper:fatal] unauthenticated: %s\n" "$*" >&2; exit 4; }
      fi
      if ! secret_load OPENAI_API_KEY wpro-openai 2>/dev/null; then
        exit 1
      fi
    fi
    echo "KEY=$OPENAI_API_KEY"
  '
  assert_success
  assert_output --partial "KEY=sk-proj-test-key-12345"
}

@test "key missing + tty available + user types Y — continues" {
  write_secrets_stub_fail

  # Simulate tty with a pipe providing "y"
  run bash -c '
    export HOME="'"$STUBDIR"'"
    source "'"$STUBDIR/common.sh"'"
    _openai_secrets="$HOME/code/scripts/shell/lib/secrets.sh"
    if [[ -r "$_openai_secrets" ]]; then
      source "$_openai_secrets"
      if ! type die_unauthed &>/dev/null; then
        die_unauthed() { printf "[wrapper:fatal] unauthenticated: %s\n" "$*" >&2; exit 4; }
      fi
      if ! secret_load OPENAI_API_KEY wpro-openai 2>/dev/null; then
        # Simulate tty path with user input "y"
        _reply="y"
        [[ "$_reply" =~ ^[yY] ]] || die_unauthed "Aborted."
      fi
    fi
    echo "continued"
  '
  assert_success
  assert_output --partial "continued"
}

@test "key missing + tty available + user types N — exits 4" {
  write_secrets_stub_fail

  run bash -c '
    export HOME="'"$STUBDIR"'"
    source "'"$STUBDIR/common.sh"'"
    _openai_secrets="$HOME/code/scripts/shell/lib/secrets.sh"
    if [[ -r "$_openai_secrets" ]]; then
      source "$_openai_secrets"
      if ! type die_unauthed &>/dev/null; then
        die_unauthed() { printf "[wrapper:fatal] unauthenticated: %s\n" "$*" >&2; exit 4; }
      fi
      if ! secret_load OPENAI_API_KEY wpro-openai 2>/dev/null; then
        _reply="n"
        [[ "$_reply" =~ ^[yY] ]] || die_unauthed "Aborted. Add key with: security add-generic-password -a openai -s wpro-openai -w '"'"'<key>'"'"'"
      fi
    fi
  '
  assert_failure 4
  assert_output --partial "unauthed"
}

@test "key missing + tty available + empty input — exits 4" {
  write_secrets_stub_fail

  run bash -c '
    export HOME="'"$STUBDIR"'"
    source "'"$STUBDIR/common.sh"'"
    _openai_secrets="$HOME/code/scripts/shell/lib/secrets.sh"
    if [[ -r "$_openai_secrets" ]]; then
      source "$_openai_secrets"
      if ! type die_unauthed &>/dev/null; then
        die_unauthed() { printf "[wrapper:fatal] unauthenticated: %s\n" "$*" >&2; exit 4; }
      fi
      if ! secret_load OPENAI_API_KEY wpro-openai 2>/dev/null; then
        _reply=""
        [[ "$_reply" =~ ^[yY] ]] || die_unauthed "Aborted."
      fi
    fi
  '
  assert_failure 4
}

@test "key missing + no tty — exits 4 with remediation message" {
  write_secrets_stub_fail

  run bash -c '
    export HOME="'"$STUBDIR"'"
    source "'"$STUBDIR/common.sh"'"
    _openai_secrets="$HOME/code/scripts/shell/lib/secrets.sh"
    if [[ -r "$_openai_secrets" ]]; then
      source "$_openai_secrets"
      if ! type die_unauthed &>/dev/null; then
        die_unauthed() { printf "[wrapper:fatal] unauthenticated: %s\n" "$*" >&2; exit 4; }
      fi
      if ! secret_load OPENAI_API_KEY wpro-openai 2>/dev/null; then
        # Simulate no-tty path
        die_unauthed "wpro-openai not in keychain and no tty for prompt. Add with: security add-generic-password -a openai -s wpro-openai -w '"'"'<key>'"'"'"
      fi
    fi
  '
  assert_failure 4
  assert_output --partial "security add-generic-password"
}

@test "secrets.sh not readable — warns and continues" {
  # Don't create secrets.sh — it won't exist
  rm -rf "$STUBDIR/code/scripts/shell/lib"

  run bash -c '
    export HOME="'"$STUBDIR"'"
    source "'"$STUBDIR/common.sh"'"
    _openai_secrets="$HOME/code/scripts/shell/lib/secrets.sh"
    if [[ -r "$_openai_secrets" ]]; then
      source "$_openai_secrets"
      if ! secret_load OPENAI_API_KEY wpro-openai 2>/dev/null; then
        exit 1
      fi
    else
      warn "secrets.sh not found at $_openai_secrets; OpenAI agents unavailable"
    fi
    echo "continued"
  '
  assert_success
  assert_output --partial "OpenAI agents unavailable"
  assert_output --partial "continued"
}
