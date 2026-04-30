#!/bin/bash

# Latest version: https://gist.github.com/skwid138/161cab8f97b73eccb2cb054695fd21c1

# Default values for optional arguments
VOICE=""
MESSAGE="workflow completed"
WORKFLOW_NAME=""

function show_help() {
  echo "Usage: workflow_tail.sh [options]"
  echo ""
  echo "Options:"
  echo "  -w, --workflow  Specify the workflow name to tail (optional, defaults to latest workflow)"
  echo "  -v, --voice     Specify the voice for the 'say' command (optional)"
  echo "  -m, --message   Customize the message for 'say' after the workflow completes (default: 'workflow completed')"
  echo "  -h, --help      Display this help message"
  exit 0
}

# Parse arguments
while [[ "$#" -gt 0 ]]; do
  case $1 in
    -w | --workflow)
      WORKFLOW_NAME="$2"
      shift
      ;;
    -v | --voice)
      VOICE="$2"
      shift
      ;;
    -m | --message)
      MESSAGE="$2"
      shift
      ;;
    -h | --help) show_help ;;
    *)
      echo "Unknown option: $1"
      show_help
      ;;
  esac
  shift
done

# Check if gh CLI is installed
if ! command -v gh &>/dev/null; then
  echo "Error: GitHub CLI (gh) is not installed. Please install it and try again."
  exit 1
fi

# Check if the user is authenticated with GitHub CLI
if ! gh auth status &>/dev/null; then
  echo "Error: GitHub CLI is not authenticated. Run 'gh auth login' to authenticate."
  exit 1
fi

# Get the GitHub repository info from the current directory's Git configuration
REPO_URL=$(git config --get remote.origin.url)

# Check if we're in a git repository with a GitHub remote
if [ -z "$REPO_URL" ]; then
  echo "Error: Not a git repository or no remote.origin.url found. Please navigate to a GitHub repository and try again."
  exit 1
fi

# Format the user/repo structure from the Git remote URL
USER_REPO=$(echo "$(dirname "$REPO_URL")/$(basename -s .git "$REPO_URL")" | cut -d: -f2)

# Fetch the workflow runs, optionally filtering by name
if [ -n "$WORKFLOW_NAME" ]; then
  # Filter by workflow name
  RUN_ID=$(gh run list --repo "$USER_REPO" --json databaseId,name --jq ".[] | select(.name | contains(\"$WORKFLOW_NAME\")) | .databaseId" | head -n 1)
else
  # Get the latest workflow run
  RUN_ID=$(gh run list --repo "$USER_REPO" --limit 1 --json databaseId --jq ".[0].databaseId")
fi

if [ -z "$RUN_ID" ]; then
  echo "Error: Could not retrieve the specified workflow run. Please check your GitHub permissions, workflow name, or if the repository has any matching workflows."
  exit 1
fi

# Watch the workflow log in real-time
gh run watch "$RUN_ID" --repo "$USER_REPO"

# Say a message after the workflow completes
if [ -n "$VOICE" ]; then
  say -v "$VOICE" "$MESSAGE"
else
  say "$MESSAGE"
fi
