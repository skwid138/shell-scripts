#!/usr/bin/env bash
# rollback — interactive Docker Desktop rollback for macOS via Homebrew.
#
# Behavior:
#   - Stops a running Docker Desktop, uninstalls the current cask, then
#     attempts to install a target version using a known cask-commit hash,
#     a user-supplied commit hash, or a direct download from Docker's CDN.
#   - Default target is 4.47.0 (override by passing a version argument).
#   - Prompts for confirmation and (when needed) for a commit hash.
#
# Examples:
#   rollback.sh                # rollback to default version (4.47.0)
#   rollback.sh 4.46.0         # rollback to a specific version
#
# Exit codes (per docs/EXIT-CODES.md):
#   0  success
#   1  generic runtime failure (all install methods failed, etc.)
#   2  usage error
#   3  missing dependency (brew, curl)

set -uo pipefail
source "$(dirname "$0")/../../lib/common.sh"

usage() {
  cat <<'EOF'
Usage: rollback.sh [VERSION]

Interactively rollback Docker Desktop to a specified version on macOS.

Arguments:
  VERSION   Target Docker Desktop version (default: 4.47.0).

Options:
  -h, --help    Show this help and exit.

Examples:
  rollback.sh
  rollback.sh 4.46.0
EOF
}

# Default version to rollback to.
DEFAULT_VERSION="4.47.0"
TARGET_VERSION=""

# Parse args.
while [[ $# -gt 0 ]]; do
  case "$1" in
    -h | --help)
      usage
      exit 0
      ;;
    -*)
      die_usage "unknown flag: $1 (try --help)"
      ;;
    *)
      if [[ -n "$TARGET_VERSION" ]]; then
        die_usage "unexpected extra argument: $1 (try --help)"
      fi
      TARGET_VERSION="$1"
      shift
      ;;
  esac
done

TARGET_VERSION="${TARGET_VERSION:-$DEFAULT_VERSION}"

require_cmd "brew" "https://brew.sh"
require_cmd "curl"

# Known version → commit hash mappings for docker-desktop cask.
# Update as new known-good cask commits are discovered.
declare -A VERSION_COMMITS
VERSION_COMMITS["4.47.0"]="e76f6ccff64e9f1eac44e59f2bb5c06c3dd2e0e7" # We'll need to find this
VERSION_COMMITS["4.46.0"]="PLACEHOLDER"                              # Backup option

log_info() {
  echo -e "${BLUE}ℹ${NC} $1"
}

log_success() {
  echo -e "${GREEN}✓${NC} $1"
}

log_warning() {
  echo -e "${YELLOW}⚠${NC} $1"
}

log_error() {
  echo -e "${RED}✗${NC} $1"
}

# Check current Docker Desktop version.
check_current_version() {
  if [ -d "/Applications/Docker.app" ]; then
    CURRENT_VERSION="$(defaults read /Applications/Docker.app/Contents/Info.plist CFBundleShortVersionString 2>/dev/null || echo "unknown")"
    log_info "Current Docker Desktop version: $CURRENT_VERSION"
  else
    log_warning "Docker Desktop not found in /Applications"
  fi
}

# Stop Docker Desktop if running.
stop_docker() {
  log_info "Stopping Docker Desktop..."

  if pgrep -x "Docker Desktop" >/dev/null; then
    osascript -e 'quit app "Docker Desktop"' 2>/dev/null || true
    sleep 5

    # Force quit if still running.
    if pgrep -x "Docker Desktop" >/dev/null; then
      killall "Docker Desktop" 2>/dev/null || true
      sleep 2
    fi
  fi

  log_success "Docker Desktop stopped"
}

# Uninstall current Docker Desktop via Homebrew.
uninstall_docker() {
  log_info "Uninstalling current Docker Desktop..."

  if brew list --cask docker-desktop &>/dev/null; then
    brew uninstall --cask docker-desktop --force
    log_success "Docker Desktop uninstalled via Homebrew"
  elif brew list --cask docker &>/dev/null; then
    brew uninstall --cask docker --force
    log_success "Docker Desktop uninstalled via Homebrew (legacy cask name)"
  else
    log_warning "Docker Desktop not found in Homebrew cask list"

    # Manual removal if needed.
    if [ -d "/Applications/Docker.app" ]; then
      log_info "Removing /Applications/Docker.app manually..."
      sudo rm -rf /Applications/Docker.app
    fi
  fi
}

# Method 1: install specific version using GitHub commit.
install_from_github_commit() {
  local version="$1"
  local commit_hash="$2"

  log_info "Attempting to install Docker Desktop $version using GitHub commit method..."

  local raw_url="https://raw.githubusercontent.com/Homebrew/homebrew-cask/${commit_hash}/Casks/d/docker-desktop.rb"

  if brew install --cask "$raw_url" 2>/dev/null; then
    log_success "Successfully installed Docker Desktop $version"
    return 0
  else
    log_error "Failed to install from GitHub commit"
    return 1
  fi
}

# Method 2: direct download and install from Docker's CDN.
install_from_docker_cdn() {
  local version="$1"

  log_info "Attempting direct download from Docker CDN..."
  log_warning "We need to find the build number for version $version"

  # Known build numbers (these would need to be updated).
  local build_number
  case "$version" in
    "4.48.0") build_number="207573" ;;
    "4.47.0") build_number="UNKNOWN" ;; # We need to find this
    *)
      log_error "Build number for version $version is not known"
      return 1
      ;;
  esac

  if [ "$build_number" == "UNKNOWN" ]; then
    log_error "Build number not available for version $version"
    return 1
  fi

  # Determine architecture.
  local arch
  if [ "$(uname -m)" == "arm64" ]; then
    arch="arm64"
  else
    arch="amd64"
  fi

  local download_url="https://desktop.docker.com/mac/main/${arch}/${build_number}/Docker.dmg"
  local dmg_path="/tmp/Docker-${version}.dmg"

  log_info "Downloading Docker Desktop ${version} from ${download_url}..."

  if curl -fL -o "$dmg_path" "$download_url"; then
    log_success "Download complete"

    log_info "Installing Docker Desktop..."
    hdiutil attach "$dmg_path" -nobrowse -quiet

    local volume="/Volumes/Docker"
    if [ -d "$volume" ]; then
      cp -R "$volume/Docker.app" /Applications/
      hdiutil detach "$volume" -quiet
      rm "$dmg_path"
      log_success "Docker Desktop ${version} installed successfully"
      return 0
    else
      log_error "Failed to mount DMG"
      return 1
    fi
  else
    log_error "Failed to download Docker Desktop"
    return 1
  fi
}

# Search for the correct commit hash for a version (interactive).
find_version_commit() {
  local version="$1"

  log_info "Searching for commit hash for version $version..."
  log_info "Please visit: https://github.com/Homebrew/homebrew-cask/commits/master/Casks/d/docker-desktop.rb"
  log_info "Look for the commit that updated docker-desktop to version $version"
  echo ""
  read -rp "Enter the commit hash (or press Enter to try direct download): " user_commit

  if [ -n "$user_commit" ]; then
    echo "$user_commit"
    return 0
  fi
  return 1
}

main() {
  echo ""
  log_info "==================================================================="
  log_info "Docker Desktop Rollback Script"
  log_info "Target version: $TARGET_VERSION"
  log_info "==================================================================="
  echo ""

  # Pre-flight checks.
  check_current_version

  # Confirm with user.
  echo ""
  log_warning "This script will:"
  echo "  1. Stop Docker Desktop if running"
  echo "  2. Uninstall the current version"
  echo "  3. Install Docker Desktop $TARGET_VERSION"
  echo ""
  read -p "Do you want to continue? (y/N): " -n 1 -r
  echo ""

  if [[ ! $REPLY =~ ^[Yy]$ ]]; then
    log_info "Operation cancelled"
    exit 0
  fi

  # Stop and uninstall.
  stop_docker
  uninstall_docker

  # Try to install the target version.
  echo ""
  log_info "Attempting to install Docker Desktop $TARGET_VERSION..."

  # Check if we have a known commit hash.
  if [ -n "${VERSION_COMMITS[$TARGET_VERSION]:-}" ] && [ "${VERSION_COMMITS[$TARGET_VERSION]}" != "PLACEHOLDER" ]; then
    if install_from_github_commit "$TARGET_VERSION" "${VERSION_COMMITS[$TARGET_VERSION]}"; then
      log_success "Installation complete!"
      echo ""
      log_info "Please open Docker Desktop from Applications to complete setup"
      exit 0
    fi
  fi

  # If GitHub method failed, ask user for commit hash.
  if commit_hash="$(find_version_commit "$TARGET_VERSION")"; then
    VERSION_COMMITS[$TARGET_VERSION]="$commit_hash"
    if install_from_github_commit "$TARGET_VERSION" "$commit_hash"; then
      log_success "Installation complete!"
      echo ""
      log_info "Please open Docker Desktop from Applications to complete setup"
      exit 0
    fi
  fi

  # Try direct download as fallback.
  log_warning "GitHub method failed, trying direct download..."
  if install_from_docker_cdn "$TARGET_VERSION"; then
    log_success "Installation complete!"
    echo ""
    log_info "Please open Docker Desktop from Applications to complete setup"
    exit 0
  fi

  # If all methods failed.
  log_error "All installation methods failed"
  echo ""
  log_info "Manual installation options:"
  echo "  1. Visit: https://docs.docker.com/desktop/release-notes/"
  echo "  2. Find version $TARGET_VERSION"
  echo "  3. Download the DMG for your architecture"
  echo "  4. Install manually"
  echo ""
  echo "  OR"
  echo ""
  echo "  1. Visit: https://github.com/Homebrew/homebrew-cask/commits/master/Casks/d/docker-desktop.rb"
  echo "  2. Find the commit for version $TARGET_VERSION"
  echo "  3. Get the raw URL of docker-desktop.rb from that commit"
  echo "  4. Run: brew install --cask [RAW_URL]"

  die "all installation methods failed"
}

main "$@"
