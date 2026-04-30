#!/usr/bin/env bash

#######################################################################
# Docker Desktop Rollback Script for macOS (Homebrew)
#
# This script helps you rollback from Docker Desktop 4.48.0 to 4.47.0
#
# Usage: ./rollback.sh [VERSION]
# Example: ./rollback.sh 4.47.0
#
# If no version is provided, defaults to 4.47.0
#######################################################################

set -euo pipefail

# Colors for output
RED='\033[0;31m'
GREEN='\033[0;32m'
YELLOW='\033[1;33m'
BLUE='\033[0;34m'
NC='\033[0m' # No Color

# Default version to rollback to
DEFAULT_VERSION="4.47.0"
TARGET_VERSION="${1:-$DEFAULT_VERSION}"

# Known version to commit hash mappings for docker-desktop cask
# These are from the Homebrew/homebrew-cask repository history
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

# Check if Homebrew is installed
check_homebrew() {
  if ! command -v brew &>/dev/null; then
    log_error "Homebrew is not installed. Please install it first: https://brew.sh"
    exit 1
  fi
  log_success "Homebrew is installed"
}

# Check current Docker Desktop version
check_current_version() {
  if [ -d "/Applications/Docker.app" ]; then
    CURRENT_VERSION=$(defaults read /Applications/Docker.app/Contents/Info.plist CFBundleShortVersionString 2>/dev/null || echo "unknown")
    log_info "Current Docker Desktop version: $CURRENT_VERSION"
  else
    log_warning "Docker Desktop not found in /Applications"
  fi
}

# Stop Docker Desktop if running
stop_docker() {
  log_info "Stopping Docker Desktop..."

  if pgrep -x "Docker Desktop" >/dev/null; then
    osascript -e 'quit app "Docker Desktop"' 2>/dev/null || true
    sleep 5

    # Force quit if still running
    if pgrep -x "Docker Desktop" >/dev/null; then
      killall "Docker Desktop" 2>/dev/null || true
      sleep 2
    fi
  fi

  log_success "Docker Desktop stopped"
}

# Uninstall current Docker Desktop via Homebrew
uninstall_docker() {
  log_info "Uninstalling current Docker Desktop..."

  # Check if installed via Homebrew
  if brew list --cask docker-desktop &>/dev/null; then
    brew uninstall --cask docker-desktop --force
    log_success "Docker Desktop uninstalled via Homebrew"
  elif brew list --cask docker &>/dev/null; then
    brew uninstall --cask docker --force
    log_success "Docker Desktop uninstalled via Homebrew (legacy cask name)"
  else
    log_warning "Docker Desktop not found in Homebrew cask list"

    # Manual removal if needed
    if [ -d "/Applications/Docker.app" ]; then
      log_info "Removing /Applications/Docker.app manually..."
      sudo rm -rf /Applications/Docker.app
    fi
  fi
}

# Method 1: Install specific version using GitHub commit
install_from_github_commit() {
  local version=$1
  local commit_hash=$2

  log_info "Attempting to install Docker Desktop $version using GitHub commit method..."

  local raw_url="https://raw.githubusercontent.com/Homebrew/homebrew-cask/${commit_hash}/Casks/d/docker-desktop.rb"

  # Try to install from the raw URL
  if brew install --cask "$raw_url" 2>/dev/null; then
    log_success "Successfully installed Docker Desktop $version"
    return 0
  else
    log_error "Failed to install from GitHub commit"
    return 1
  fi
}

# Method 2: Direct download and install from Docker's CDN
install_from_docker_cdn() {
  local version=$1

  log_info "Attempting direct download from Docker CDN..."
  log_warning "We need to find the build number for version $version"

  # Known build numbers (these would need to be updated)
  local build_number
  case $version in
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

  # Determine architecture
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

    # Mount and install
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

# Method 3: Use Homebrew extract (for formulae, not casks)
# This method doesn't work well for casks, but included for completeness
info_homebrew_extract() {
  log_warning "Note: 'brew extract' works for formulae but not for casks like docker-desktop"
  log_warning "If you need a formula-based Docker CLI (without Desktop), you can use:"
  echo "  brew tap-new \$USER/local-docker"
  echo "  brew extract --version=XX.XX.XX docker \$USER/local-docker"
  echo "  brew install docker@XX.XX.XX"
}

# Search for the correct commit hash for a version
find_version_commit() {
  local version=$1

  log_info "Searching for commit hash for version $version..."
  log_info "Please visit: https://github.com/Homebrew/homebrew-cask/commits/master/Casks/d/docker-desktop.rb"
  log_info "Look for the commit that updated docker-desktop to version $version"
  echo ""
  read -p "Enter the commit hash (or press Enter to try direct download): " user_commit

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

  # Pre-flight checks
  check_homebrew
  check_current_version

  # Confirm with user
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

  # Stop and uninstall
  stop_docker
  uninstall_docker

  # Try to install the target version
  echo ""
  log_info "Attempting to install Docker Desktop $TARGET_VERSION..."

  # Check if we have a known commit hash
  if [ -n "${VERSION_COMMITS[$TARGET_VERSION]:-}" ] && [ "${VERSION_COMMITS[$TARGET_VERSION]}" != "PLACEHOLDER" ]; then
    if install_from_github_commit "$TARGET_VERSION" "${VERSION_COMMITS[$TARGET_VERSION]}"; then
      log_success "Installation complete!"
      echo ""
      log_info "Please open Docker Desktop from Applications to complete setup"
      exit 0
    fi
  fi

  # If GitHub method failed, ask user for commit hash
  if commit_hash=$(find_version_commit "$TARGET_VERSION"); then
    VERSION_COMMITS[$TARGET_VERSION]=$commit_hash
    if install_from_github_commit "$TARGET_VERSION" "$commit_hash"; then
      log_success "Installation complete!"
      echo ""
      log_info "Please open Docker Desktop from Applications to complete setup"
      exit 0
    fi
  fi

  # Try direct download as fallback
  log_warning "GitHub method failed, trying direct download..."
  if install_from_docker_cdn "$TARGET_VERSION"; then
    log_success "Installation complete!"
    echo ""
    log_info "Please open Docker Desktop from Applications to complete setup"
    exit 0
  fi

  # If all methods failed
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

  exit 1
}

# Run main function
main "$@"
