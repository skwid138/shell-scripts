#!/usr/bin/env bash

####################################################################
# Docker Desktop Version Finder
#
# This helper script helps you find the Homebrew cask commit hash
# for a specific Docker Desktop version
#
# Usage: ./get_docker_version_brew.sh [VERSION]
# Example: ./get_docker_version_brew.sh 4.47.0
####################################################################

set -euo pipefail

# Colors
BLUE='\033[0;34m'
GREEN='\033[0;32m'
YELLOW='\033[1;33m'
NC='\033[0m'

VERSION="${1:-4.47.0}"

echo ""
echo -e "${BLUE}Docker Desktop Version Finder${NC}"
echo -e "${BLUE}==============================${NC}"
echo ""
echo "Searching for version: $VERSION"
echo ""

# Open the browser to the commits page
CASK_COMMITS_URL="https://github.com/Homebrew/homebrew-cask/commits/master/Casks/d/docker-desktop.rb"

echo -e "${GREEN}Step 1:${NC} Opening GitHub in your browser..."
echo "URL: $CASK_COMMITS_URL"
echo ""

# Try to open in default browser
if command -v open &>/dev/null; then
  open "$CASK_COMMITS_URL"
elif command -v xdg-open &>/dev/null; then
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
echo "  ${YELLOW}brew install --cask [PASTE_THE_URL_HERE]${NC}"
echo ""
echo "  OR use the main rollback script with the commit hash:"
echo "  ${YELLOW}./rollback.sh $VERSION${NC}"
echo "  (The script will prompt you for the commit hash)"
echo ""

# Alternative: Try to use GitHub API (may hit rate limits)
echo -e "${BLUE}Attempting to fetch recent commits via GitHub API...${NC}"
echo ""

TEMP_FILE=$(mktemp)
if curl -s "https://api.github.com/repos/Homebrew/homebrew-cask/commits?path=Casks/d/docker-desktop.rb&per_page=20" >"$TEMP_FILE"; then
  echo "Recent commits:"
  echo ""

  # Parse and display commits
  grep -E '"sha"|"message"' "$TEMP_FILE" | paste - - | head -n 10 | while IFS= read -r line; do
    sha=$(echo "$line" | grep -oE '"sha": "[^"]+' | cut -d'"' -f4)
    msg=$(echo "$line" | grep -oE '"message": "[^"]+"' | cut -d'"' -f4)

    # Highlight if it contains our version
    if echo "$msg" | grep -q "$VERSION"; then
      echo -e "${GREEN}✓ MATCH:${NC} $msg"
      echo "  SHA: $sha"
      echo "  URL: https://raw.githubusercontent.com/Homebrew/homebrew-cask/$sha/Casks/d/docker-desktop.rb"
      echo ""
    else
      # Show version if present in message
      if echo "$msg" | grep -qE "[0-9]+\.[0-9]+\.[0-9]+"; then
        extracted_version=$(echo "$msg" | grep -oE "[0-9]+\.[0-9]+\.[0-9]+" | head -1)
        echo "  Version $extracted_version: $sha"
      fi
    fi
  done
else
  echo -e "${YELLOW}Could not fetch from GitHub API (you may be rate limited)${NC}"
  echo "Please use the manual method in your browser."
fi

rm -f "$TEMP_FILE"

echo ""
echo -e "${BLUE}==============================${NC}"
echo ""
