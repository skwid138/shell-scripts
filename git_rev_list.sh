#!/bin/bash

# Latest version: https://gist.github.com/skwid138/5905e2179b5682666ca6be7502409cf9

# Default values
base_branch=""
compare_branch=""

# Help documentation
usage() {
    echo "Usage: $0 [OPTIONS]"
    echo ""
    echo "Options:"
    echo "  --base, -b       Specify the base branch to compare against (default: origin/develop, origin/main, or origin/master)"
    echo "  --compare, -c    Specify the branch to compare with the base branch (default: current branch)"
    echo "  --help, -h       Display this help message"
    echo ""
    echo "Description:"
    echo "This script compares the number of commits between a base branch and a compare branch"
    echo "within the current Git repository. If no compare branch is specified, the current branch"
    echo "is used."
    echo ""
    exit 0
}

# Parse arguments
while [[ "$#" -gt 0 ]]; do
    case $1 in
    --base | -b)
        base_branch="$2"
        shift 2
        ;;
    --compare | -c)
        compare_branch="$2"
        shift 2
        ;;
    --help | -h)
        usage
        ;;
    *)
        echo "Unknown option: $1"
        usage
        ;;
    esac
done

# Check if we're in a Git repository
if ! git rev-parse --is-inside-work-tree >/dev/null 2>&1; then
    echo "Error: Not inside a Git repository." >&2
    exit 1
fi

# Determine the base branch if not explicitly set
if [[ -z "$base_branch" ]]; then
    echo "Determining the base branch..."
    if git show-ref --verify --quiet refs/remotes/origin/develop; then
        base_branch="origin/develop"
    elif git show-ref --verify --quiet refs/remotes/origin/main; then
        base_branch="origin/main"
    elif git show-ref --verify --quiet refs/remotes/origin/master; then
        base_branch="origin/master"
    else
        echo "Error: No base branch found. This repository doesn't have 'origin/develop', 'origin/main', or 'origin/master'."
        echo "Please specify a base branch explicitly using --base or -b."
        exit 1
    fi
fi

# Get the current branch if compare branch is not provided
if [[ -z "$compare_branch" ]]; then
    compare_branch=$(git rev-parse --abbrev-ref HEAD)
fi

# Ensure you have the latest changes before comparing
echo "Fetching latest changes..."
git fetch --all

# Run the git rev-list command
echo "Comparing $base_branch to $compare_branch..."
behind_ahead=$(git rev-list --left-right --count "$base_branch...$compare_branch" 2>/dev/null)

# Check for errors in the rev-list command
if [[ $? -ne 0 ]]; then
    echo "Error: Failed to compare $base_branch and $compare_branch. Ensure both branches exist."
    exit 1
fi

# Split the output into variables for clarity
behind=$(echo "$behind_ahead" | awk '{print $1}')
ahead=$(echo "$behind_ahead" | awk '{print $2}')

# Display the formatted output
echo "Behind $base_branch by: $behind commits"
echo "Ahead of $base_branch by: $ahead commits"
