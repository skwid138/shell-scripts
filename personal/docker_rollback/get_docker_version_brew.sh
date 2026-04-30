#!/usr/bin/env bash
# get-docker-version-brew — find the Homebrew cask commit hash for a Docker Desktop version.
#
# Behavior:
#   - Opens the docker-desktop.rb cask commit history page in the default browser.
#   - Prints step-by-step instructions for locating the commit + raw URL.
#   - Attempts (best-effort) to fetch recent commits via the GitHub API and
#     highlights any whose message references the requested version.
#
# Examples:
#   get_docker_version_brew.sh                  # defaults to 4.47.0
#   get_docker_version_brew.sh 4.46.0
#
# Exit codes (per docs/EXIT-CODES.md):
#   0  success
#   2  usage error
#   3  missing dependency (curl)

set -uo pipefail
source "$(dirname "$0")/../../lib/common.sh"

usage() {
  cat <<'EOF'
Usage: get_docker_version_brew.sh [VERSION]

Helper to find the Homebrew cask commit hash for a specific Docker Desktop
version, by opening the cask commit history and (best-effort) querying the
GitHub API for matches.

Arguments:
  VERSION   Docker Desktop version to search for (default: 4.47.0).

Options:
  -h, --help    Show this help and exit.

Examples:
  get_docker_version_brew.sh
  get_docker_version_brew.sh 4.46.0
EOF
}

# Parse args.
VERSION=""
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
      if [[ -n "$VERSION" ]]; then
        die_usage "unexpected extra argument: $1 (try --help)"
      fi
      VERSION="$1"
      shift
      ;;
  esac
done

VERSION="${VERSION:-4.47.0}"

require_cmd "curl"

echo ""
echo -e "${BLUE}Docker Desktop Version Finder${NC}"
echo -e "${BLUE}==============================${NC}"
echo ""
echo "Searching for version: $VERSION"
echo ""

# URL for the cask commit history.
CASK_COMMITS_URL="https://github.com/Homebrew/homebrew-cask/commits/master/Casks/d/docker-desktop.rb"

echo -e "${GREEN}Step 1:${NC} Opening GitHub in your browser..."
echo "URL: $CASK_COMMITS_URL"
echo ""

# Try to open in default browser.
if command -v open >/dev/null 2>&1; then
  open "$CASK_COMMITS_URL"
elif command -v xdg-open >/dev/null 2>&1; then
  xdg-open "$CASK_COMMITS_URL"
else
  echo -e "${YELLOW}Please manually open: $CASK_COMMITS_URL${NC}"
fi

echo -e "${GREEN}Step 2:${NC} What to do in GitHub:"
echo ""
echo "  1. Look for a commit with version $VERSION in the message"
echo "     (e.g., 'docker-desktop $VERSION' or 'Update docker-desktop to $VERSION')"
echo ""
echo "  2. Click on that commit"
echo ""
echo "  3. Find the 'docker-desktop.rb' file in the commit"
echo ""
echo "  4. Click the three dots (...) next to the file"
echo ""
echo "  5. Select 'View file'"
echo ""
echo "  6. Click the 'Raw' button"
echo ""
echo "  7. Copy the FULL URL from your browser's address bar"
echo ""
echo -e "${GREEN}Step 3:${NC} Once you have the URL:"
echo ""
echo "  The URL will look like:"
echo "  https://raw.githubusercontent.com/Homebrew/homebrew-cask/[HASH]/Casks/d/docker-desktop.rb"
echo ""
echo "  To install that version, run:"
echo -e "  ${YELLOW}brew install --cask [PASTE_THE_URL_HERE]${NC}"
echo ""
echo "  OR use the main rollback script with the commit hash:"
echo -e "  ${YELLOW}./rollback.sh $VERSION${NC}"
echo "  (The script will prompt you for the commit hash)"
echo ""

# Best-effort: try the GitHub API (may hit rate limits).
echo -e "${BLUE}Attempting to fetch recent commits via GitHub API...${NC}"
echo ""

TEMP_FILE="$(mktemp)"
trap 'rm -f "$TEMP_FILE"' EXIT

if curl -s "https://api.github.com/repos/Homebrew/homebrew-cask/commits?path=Casks/d/docker-desktop.rb&per_page=20" >"$TEMP_FILE"; then
  echo "Recent commits:"
  echo ""

  # Parse and display commits.
  grep -E '"sha"|"message"' "$TEMP_FILE" | paste - - | head -n 10 | while IFS= read -r line; do
    sha="$(echo "$line" | grep -oE '"sha": "[^"]+' | cut -d'"' -f4)"
    msg="$(echo "$line" | grep -oE '"message": "[^"]+"' | cut -d'"' -f4)"

    if echo "$msg" | grep -q "$VERSION"; then
      echo -e "${GREEN}✓ MATCH:${NC} $msg"
      echo "  SHA: $sha"
      echo "  URL: https://raw.githubusercontent.com/Homebrew/homebrew-cask/$sha/Casks/d/docker-desktop.rb"
      echo ""
    else
      if echo "$msg" | grep -qE "[0-9]+\.[0-9]+\.[0-9]+"; then
        extracted_version="$(echo "$msg" | grep -oE "[0-9]+\.[0-9]+\.[0-9]+" | head -1)"
        echo "  Version $extracted_version: $sha"
      fi
    fi
  done
else
  echo -e "${YELLOW}Could not fetch from GitHub API (you may be rate limited)${NC}"
  echo "Please use the manual method in your browser."
fi

echo ""
echo -e "${BLUE}==============================${NC}"
echo ""
