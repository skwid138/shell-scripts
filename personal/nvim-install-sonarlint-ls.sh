#!/usr/bin/env bash
# nvim-install-sonarlint-ls — download the SonarLint Language Server for nvim.
#
# sonarlint.nvim does NOT bundle the language server. The official path
# (per the plugin README) is to extract it from the VSCode SonarLint
# extension's .vsix bundle, which ships the LS jars + analyzers + a JRE
# location that we replace with the system Java.
#
# This script:
#   1. Downloads a pinned VSCode SonarLint extension VSIX from the
#      Visual Studio Marketplace.
#   2. Unzips it into a stable install dir.
#   3. Verifies the language server jar exists at the expected path.
#
# The nvim sonarlint.nvim config then points its `cmd` at:
#   { 'java', '-jar', '<install-dir>/extension/server/sonarlint-ls.jar', ... }
#
# Idempotent: if the install dir already exists and contains the jar, exits
# 0 without re-downloading. Use --force to re-download.
#
# Exit codes:
#   0 success (or already installed)
#   1 generic failure (install dir invalid, jar missing after extract)
#   2 usage error
#   3 missing dependency (curl, unzip)
#   5 upstream failure (download failed)

set -uo pipefail
source "$(dirname "$0")/../lib/common.sh"

# Pinned versions — bump deliberately. As of 2025-Q4 the marketplace URL
# pattern is stable; the publisher/extension/version triple is what changes.
SONARLINT_PUBLISHER="SonarSource"
SONARLINT_EXTENSION="sonarlint-vscode"
SONARLINT_VERSION="4.18.0"

DEFAULT_INSTALL_DIR="$HOME/.local/share/sonarlint-ls"

usage() {
  cat <<EOF
Usage: nvim-install-sonarlint-ls [--install-dir DIR] [--force]

Download the SonarLint Language Server (extracted from the VSCode SonarLint
extension VSIX) for use with sonarlint.nvim.

Options:
  --install-dir DIR  Where to extract the VSIX. Default: $DEFAULT_INSTALL_DIR
  --force            Re-download even if already installed.
  -h, --help         Show this help.

Pinned version: ${SONARLINT_PUBLISHER}.${SONARLINT_EXTENSION}@${SONARLINT_VERSION}

Override pinned version via env vars (advanced):
  SONARLINT_VERSION, SONARLINT_PUBLISHER, SONARLINT_EXTENSION

After install, point sonarlint.nvim at:
  <install-dir>/extension/server/sonarlint-ls.jar

Examples:
  nvim-install-sonarlint-ls
  nvim-install-sonarlint-ls --force
  nvim-install-sonarlint-ls --install-dir ~/tools/sonarlint
EOF
}

# Honor env-var overrides for the version triple (used heavily in tests).
SONARLINT_PUBLISHER="${SONARLINT_PUBLISHER_OVERRIDE:-$SONARLINT_PUBLISHER}"
SONARLINT_EXTENSION="${SONARLINT_EXTENSION_OVERRIDE:-$SONARLINT_EXTENSION}"
SONARLINT_VERSION="${SONARLINT_VERSION_OVERRIDE:-$SONARLINT_VERSION}"

install_dir="$DEFAULT_INSTALL_DIR"
force=0

while [[ $# -gt 0 ]]; do
  case "$1" in
    -h | --help)
      usage
      exit 0
      ;;
    --force)
      force=1
      shift
      ;;
    --install-dir)
      [[ $# -ge 2 ]] || die_usage "--install-dir requires a value"
      install_dir="$2"
      shift 2
      ;;
    *)
      die_usage "unknown flag: $1 (try --help)"
      ;;
  esac
done

require_cmd "curl" "(curl is in macOS base; check PATH)"
require_cmd "unzip" "(unzip is in macOS base; check PATH)"

jar_relpath="extension/server/sonarlint-ls.jar"
jar_path="$install_dir/$jar_relpath"

# Idempotency check.
if [[ -f "$jar_path" && $force -eq 0 ]]; then
  info "SonarLint LS already installed at $install_dir (use --force to re-download)"
  echo "$jar_path"
  exit 0
fi

# Marketplace download URL pattern (stable as of 2025).
# Format: https://${publisher}.gallery.vsassets.io/_apis/public/gallery/publisher/${publisher}/extension/${extension}/${version}/assetbyname/Microsoft.VisualStudio.Services.VSIXPackage
url="https://${SONARLINT_PUBLISHER}.gallery.vsassets.io/_apis/public/gallery/publisher/${SONARLINT_PUBLISHER}/extension/${SONARLINT_EXTENSION}/${SONARLINT_VERSION}/assetbyname/Microsoft.VisualStudio.Services.VSIXPackage"

# Allow tests to override the URL entirely (point at a local file:// or http
# fixture). Lets the bats suite avoid hitting the network.
url="${SONARLINT_DOWNLOAD_URL:-$url}"

tmpdir="$(mktemp -d)"
# shellcheck disable=SC2064  # we WANT $tmpdir expanded at trap-set time
trap "rm -rf '$tmpdir'" EXIT

vsix_file="$tmpdir/sonarlint.vsix"

info "Downloading SonarLint VSIX (${SONARLINT_VERSION}) from $url"
if ! curl --fail --silent --show-error --location --output "$vsix_file" "$url"; then
  die_upstream "Failed to download VSIX from $url"
fi

# Validate it's actually a zip (VSIX = renamed zip).
if ! unzip -tq "$vsix_file" >/dev/null 2>&1; then
  die_upstream "Downloaded file is not a valid VSIX (zip): $vsix_file"
fi

# Wipe and recreate install dir for a clean slate.
mkdir -p "$(dirname "$install_dir")"
rm -rf "$install_dir"
mkdir -p "$install_dir"

info "Extracting to $install_dir"
if ! unzip -q "$vsix_file" -d "$install_dir"; then
  die "Failed to extract VSIX to $install_dir"
fi

# Verify the jar landed where we expect.
if [[ ! -f "$jar_path" ]]; then
  die "SonarLint LS jar not found after extract: $jar_path (VSIX layout may have changed)"
fi

info "SonarLint LS installed: $jar_path"
echo "$jar_path"
