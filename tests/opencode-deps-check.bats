#!/usr/bin/env bats
# Tests for opencode-deps-check.sh

setup() {
  load 'test_helper/bats-support/load'
  load 'test_helper/bats-assert/load'

  # Source the script in library mode (it returns early when sourced).
  source "$BATS_TEST_DIRNAME/../opencode-deps-check.sh"

  # Per-test scratch dir for fixture configs
  TMP_CFG="$BATS_TEST_TMPDIR/cfg"
  mkdir -p "$TMP_CFG"
}

# --- parse_pkg_ref ----------------------------------------------------------

@test "parse_pkg_ref: scoped package with version → name + version" {
  run parse_pkg_ref "@scope/name@1.2.3"
  assert_success
  assert_output --partial "@scope/name"
  assert_output --partial "1.2.3"
}

@test "parse_pkg_ref: scoped package without version → empty version" {
  run parse_pkg_ref "@scope/name"
  assert_success
  # Two lines: name then empty
  [ "${lines[0]}" = "@scope/name" ]
  [ "${#lines[@]}" -eq 1 ] # trailing empty line is dropped by run
}

@test "parse_pkg_ref: unscoped package with version → name + version" {
  run parse_pkg_ref "chrome-devtools-mcp@0.23.0"
  assert_success
  [ "${lines[0]}" = "chrome-devtools-mcp" ]
  [ "${lines[1]}" = "0.23.0" ]
}

@test "parse_pkg_ref: bare unscoped name → no version" {
  run parse_pkg_ref "some-pkg"
  assert_success
  [ "${lines[0]}" = "some-pkg" ]
  [ "${#lines[@]}" -eq 1 ]
}

@test "parse_pkg_ref: scoped package with @latest" {
  run parse_pkg_ref "@tarquinen/opencode-dcp@latest"
  assert_success
  [ "${lines[0]}" = "@tarquinen/opencode-dcp" ]
  [ "${lines[1]}" = "latest" ]
}

@test "parse_pkg_ref: version with prerelease tag" {
  run parse_pkg_ref "pkg@1.2.3-beta.4"
  assert_success
  [ "${lines[0]}" = "pkg" ]
  [ "${lines[1]}" = "1.2.3-beta.4" ]
}

# --- is_npm_pkg_token -------------------------------------------------------

@test "is_npm_pkg_token: package@version → accepted" {
  run is_npm_pkg_token "chrome-devtools-mcp@0.23.0"
  assert_success
}

@test "is_npm_pkg_token: scoped package@latest → accepted" {
  run is_npm_pkg_token "@scope/foo@latest"
  assert_success
}

@test "is_npm_pkg_token: empty string → rejected" {
  run is_npm_pkg_token ""
  assert_failure
}

@test "is_npm_pkg_token: flag (-y) → rejected" {
  run is_npm_pkg_token "-y"
  assert_failure
}

@test "is_npm_pkg_token: long flag (--browserUrl) → rejected" {
  run is_npm_pkg_token "--browserUrl"
  assert_failure
}

@test "is_npm_pkg_token: npx → rejected" {
  run is_npm_pkg_token "npx"
  assert_failure
}

@test "is_npm_pkg_token: bunx → rejected" {
  run is_npm_pkg_token "bunx"
  assert_failure
}

@test "is_npm_pkg_token: node → rejected" {
  run is_npm_pkg_token "node"
  assert_failure
}

@test "is_npm_pkg_token: http URL → rejected" {
  run is_npm_pkg_token "http://127.0.0.1:9222"
  assert_failure
}

@test "is_npm_pkg_token: https URL → rejected" {
  run is_npm_pkg_token "https://example.com"
  assert_failure
}

@test "is_npm_pkg_token: file URL → rejected" {
  run is_npm_pkg_token "file:///tmp/foo"
  assert_failure
}

@test "is_npm_pkg_token: absolute path → rejected" {
  run is_npm_pkg_token "/usr/local/bin/foo"
  assert_failure
}

@test "is_npm_pkg_token: bare name without @ → rejected" {
  # We only manage tokens that include explicit version info via '@'
  run is_npm_pkg_token "some-package"
  assert_failure
}

# --- status_for -------------------------------------------------------------

@test "status_for: unpinned=true → UNPINNED" {
  run status_for "" "1.2.3" "true"
  assert_success
  assert_output "UNPINNED"
}

@test "status_for: unpinned=true with no latest → UNPINNED" {
  run status_for "" "" "true"
  assert_success
  assert_output "UNPINNED"
}

@test "status_for: missing latest → UNKNOWN" {
  run status_for "1.2.3" "" "false"
  assert_success
  assert_output "UNKNOWN"
}

@test "status_for: current == latest → ok" {
  run status_for "1.2.3" "1.2.3" "false"
  assert_success
  assert_output "ok"
}

@test "status_for: current != latest → OUTDATED" {
  run status_for "1.2.3" "1.2.4" "false"
  assert_success
  assert_output "OUTDATED"
}

# --- strip_jsonc ------------------------------------------------------------

@test "strip_jsonc: removes line comments" {
  cat >"$TMP_CFG/input.jsonc" <<'EOF'
{
  "key": "value", // trailing comment
  "other": 1
}
EOF
  run strip_jsonc "$TMP_CFG/input.jsonc"
  assert_success
  # Result must be valid JSON
  echo "$output" | jq empty
}

@test "strip_jsonc: removes block comments" {
  cat >"$TMP_CFG/input.jsonc" <<'EOF'
{
  /* leading
     multi-line block */
  "key": "value"
}
EOF
  run strip_jsonc "$TMP_CFG/input.jsonc"
  assert_success
  echo "$output" | jq empty
}

@test "strip_jsonc: preserves URL in string (no false positive on //)" {
  cat >"$TMP_CFG/input.jsonc" <<'EOF'
{
  "url": "https://example.com/path"
}
EOF
  run strip_jsonc "$TMP_CFG/input.jsonc"
  assert_success
  # URL must survive intact
  echo "$output" | jq -r '.url' | grep -q "https://example.com/path"
}

# --- end-to-end integration smoke (no network) ------------------------------
# These run the script as a child process with `npm` stubbed so registry
# lookups are deterministic.

@test "script: --help exits 0 and prints usage" {
  run "$BATS_TEST_DIRNAME/../opencode-deps-check.sh" --help
  assert_success
  assert_output --partial "Usage: opencode-deps-check"
}

@test "script: unknown flag exits 1" {
  run "$BATS_TEST_DIRNAME/../opencode-deps-check.sh" --bogus
  assert_failure
  assert_output --partial "Unknown option"
}

@test "script: --config-dir without arg exits 1" {
  run "$BATS_TEST_DIRNAME/../opencode-deps-check.sh" --config-dir
  assert_failure
  assert_output --partial "requires an argument"
}

@test "script: missing config dir exits 1 with clear error" {
  run "$BATS_TEST_DIRNAME/../opencode-deps-check.sh" --config-dir /no/such/dir
  assert_failure
  assert_output --partial "config dir not found"
}

@test "script: empty config dir (no package.json or opencode.json) exits 1" {
  run "$BATS_TEST_DIRNAME/../opencode-deps-check.sh" --config-dir "$TMP_CFG"
  assert_failure
  assert_output --partial "Neither package.json nor opencode.json found"
}

@test "script: invalid package.json JSON exits 1" {
  echo "not json {" >"$TMP_CFG/package.json"
  run "$BATS_TEST_DIRNAME/../opencode-deps-check.sh" --config-dir "$TMP_CFG"
  assert_failure
  assert_output --partial "package.json is not valid JSON"
}

@test "script: --json with valid fixture and stubbed npm produces valid JSON" {
  # Fixture: package.json with one dep
  cat >"$TMP_CFG/package.json" <<'EOF'
{
  "name": "fixture",
  "private": true,
  "dependencies": {
    "fake-pkg": "1.0.0"
  }
}
EOF
  # Minimal opencode.json
  cat >"$TMP_CFG/opencode.json" <<'EOF'
{
  "$schema": "https://opencode.ai/config.json",
  "plugin": ["another-fake-pkg@2.0.0"]
}
EOF
  # Stub npm: prepend a tmpdir with a fake `npm` to PATH
  STUB_DIR="$BATS_TEST_TMPDIR/stubs"
  mkdir -p "$STUB_DIR"
  cat >"$STUB_DIR/npm" <<'EOF'
#!/usr/bin/env bash
# Minimal stub: pretend everything is at version 9.9.9
if [[ "${1:-}" == "view" && "${3:-}" == "version" ]]; then
  echo "9.9.9"
  exit 0
fi
# Allow `npm --version` or anything else to fail silently
exit 0
EOF
  chmod +x "$STUB_DIR/npm"
  PATH="$STUB_DIR:$PATH" run "$BATS_TEST_DIRNAME/../opencode-deps-check.sh" --json --config-dir "$TMP_CFG"
  assert_success
  # Output must be valid JSON
  echo "$output" | jq empty
  # Must contain expected packages
  assert_output --partial "fake-pkg"
  assert_output --partial "another-fake-pkg"
  # Must report outdated (current 1.0.0 vs stub latest 9.9.9)
  assert_output --partial '"outdated": true'
}

@test "script: human format default (no --json) produces table" {
  cat >"$TMP_CFG/package.json" <<'EOF'
{ "dependencies": { "fake-pkg": "1.0.0" } }
EOF
  STUB_DIR="$BATS_TEST_TMPDIR/stubs"
  mkdir -p "$STUB_DIR"
  cat >"$STUB_DIR/npm" <<'EOF'
#!/usr/bin/env bash
[[ "${1:-}" == "view" && "${3:-}" == "version" ]] && { echo "1.0.0"; exit 0; }
exit 0
EOF
  chmod +x "$STUB_DIR/npm"
  PATH="$STUB_DIR:$PATH" run "$BATS_TEST_DIRNAME/../opencode-deps-check.sh" --config-dir "$TMP_CFG"
  assert_success
  assert_output --partial "PACKAGE"
  assert_output --partial "STATUS"
  assert_output --partial "Summary:"
  assert_output --partial "fake-pkg"
}
