#!/usr/bin/env bats
# CLI tests for personal/nvim-install-sonarlint-ls.sh
#
# We avoid the network by pointing SONARLINT_DOWNLOAD_URL at a local file://
# URL containing a hand-crafted minimal "VSIX" (a zip with the expected jar
# path inside). This lets us test:
#   - happy path: download → extract → jar exists at expected path
#   - idempotency: second run skips re-download
#   - --force: re-runs even if jar exists
#   - --install-dir override
#   - upstream failure mapping (404 → exit 5)
#   - missing dependency (curl) → exit 3
#   - invalid VSIX (not a zip) → exit 5

setup() {
  load 'test_helper/bats-support/load'
  load 'test_helper/bats-assert/load'
  SCRIPT="$BATS_TEST_DIRNAME/../personal/nvim-install-sonarlint-ls.sh"

  STUBDIR="$(mktemp -d)"
  FIXTURE_DIR="$(mktemp -d)"
  INSTALL_DIR="$BATS_TEST_TMPDIR/sonarlint-install"
}

teardown() {
  [[ -d "$STUBDIR" ]] && rm -rf "$STUBDIR"
  [[ -d "$FIXTURE_DIR" ]] && rm -rf "$FIXTURE_DIR"
}

# --- helpers -----------------------------------------------------------------

# Build a minimal valid VSIX (zip) at $FIXTURE_DIR/fake.vsix containing the
# expected `extension/server/sonarlint-ls.jar` entry. Returns its file:// URL.
make_fixture_vsix() {
  local stage="$FIXTURE_DIR/stage"
  mkdir -p "$stage/extension/server"
  echo "fake-jar-content" >"$stage/extension/server/sonarlint-ls.jar"
  (cd "$stage" && zip -qr "$FIXTURE_DIR/fake.vsix" .)
  echo "file://$FIXTURE_DIR/fake.vsix"
}

# Build a non-zip "VSIX" to trigger the validation failure.
make_bogus_vsix() {
  echo "not a zip file" >"$FIXTURE_DIR/bogus.vsix"
  echo "file://$FIXTURE_DIR/bogus.vsix"
}

# --- --help / usage ----------------------------------------------------------

@test "nvim-install-sonarlint-ls: --help exits 0 and prints usage" {
  run "$SCRIPT" --help
  assert_success
  assert_output --partial "Usage: nvim-install-sonarlint-ls"
  assert_output --partial "--install-dir"
  assert_output --partial "--force"
}

@test "nvim-install-sonarlint-ls: -h exits 0 and prints usage" {
  run "$SCRIPT" -h
  assert_success
  assert_output --partial "Usage: nvim-install-sonarlint-ls"
}

@test "nvim-install-sonarlint-ls: unknown flag exits 2 with usage error" {
  run "$SCRIPT" --bogus
  assert_failure 2
  assert_output --partial "unknown flag"
}

@test "nvim-install-sonarlint-ls: --install-dir without value exits 2" {
  run "$SCRIPT" --install-dir
  assert_failure 2
  assert_output --partial "requires a value"
}

# --- happy path --------------------------------------------------------------

@test "nvim-install-sonarlint-ls: happy path downloads and extracts jar" {
  url="$(make_fixture_vsix)"
  SONARLINT_DOWNLOAD_URL="$url" run "$SCRIPT" --install-dir "$INSTALL_DIR"
  assert_success
  assert_output --partial "$INSTALL_DIR/extension/server/sonarlint-ls.jar"
  [[ -f "$INSTALL_DIR/extension/server/sonarlint-ls.jar" ]]
}

@test "nvim-install-sonarlint-ls: idempotent — second run skips re-download" {
  url="$(make_fixture_vsix)"
  SONARLINT_DOWNLOAD_URL="$url" run "$SCRIPT" --install-dir "$INSTALL_DIR"
  assert_success
  # Sentinel: mark the install dir to detect re-extraction.
  touch "$INSTALL_DIR/.sentinel"
  SONARLINT_DOWNLOAD_URL="$url" run "$SCRIPT" --install-dir "$INSTALL_DIR"
  assert_success
  assert_output --partial "already installed"
  [[ -f "$INSTALL_DIR/.sentinel" ]] # sentinel survives = no re-extract
}

@test "nvim-install-sonarlint-ls: --force re-downloads even if installed" {
  url="$(make_fixture_vsix)"
  SONARLINT_DOWNLOAD_URL="$url" run "$SCRIPT" --install-dir "$INSTALL_DIR"
  assert_success
  touch "$INSTALL_DIR/.sentinel"
  SONARLINT_DOWNLOAD_URL="$url" run "$SCRIPT" --install-dir "$INSTALL_DIR" --force
  assert_success
  refute_output --partial "already installed"
  # Sentinel should be GONE (re-extract wiped the dir).
  [[ ! -f "$INSTALL_DIR/.sentinel" ]]
}

# --- failure modes -----------------------------------------------------------

@test "nvim-install-sonarlint-ls: 404 download maps to exit 5 (upstream)" {
  # file:// URL for a path that doesn't exist → curl --fail returns nonzero.
  SONARLINT_DOWNLOAD_URL="file:///does/not/exist/anywhere.vsix" \
    run "$SCRIPT" --install-dir "$INSTALL_DIR"
  assert_failure 5
  assert_output --partial "Failed to download"
}

@test "nvim-install-sonarlint-ls: invalid (non-zip) VSIX maps to exit 5" {
  url="$(make_bogus_vsix)"
  SONARLINT_DOWNLOAD_URL="$url" run "$SCRIPT" --install-dir "$INSTALL_DIR"
  assert_failure 5
  assert_output --partial "not a valid VSIX"
}

# Note: missing-dependency (curl/unzip) behavior is exhaustively covered by
# tests/common.bats around `require_cmd` — adding a CLI-level test here would
# be redundant and brittle (PATH manipulation can't selectively hide curl
# without also hiding dirname/mktemp on macOS where they share /usr/bin).
