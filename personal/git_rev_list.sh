#!/usr/bin/env bash
# git-rev-list — list commits between a base branch and a compare branch.
#
# Behavior:
#   - Determines a base branch (default: origin/develop, then origin/main,
#     then origin/master) unless one is passed via --base.
#   - Uses the current branch as the compare branch unless --compare is set.
#   - Runs `git fetch --all` to make sure refs are current.
#   - Reports how many commits compare is behind/ahead of base via
#     `git rev-list --left-right --count`.
#
# Examples:
#   git_rev_list.sh
#   git_rev_list.sh --base origin/main
#   git_rev_list.sh -b origin/develop -c feature/foo
#
# Exit codes (per docs/EXIT-CODES.md):
#   0  success
#   1  generic runtime failure (not a git repo, base/compare invalid, fetch failed)
#   2  usage error
#   3  missing dependency (git)

set -uo pipefail
source "$(dirname "$0")/../lib/common.sh"

usage() {
  cat <<'EOF'
Usage: git_rev_list.sh [OPTIONS]

Compare the commits between a base branch and a compare branch in the current
Git repository.

Arguments:
  (none)

Options:
  -b, --base BRANCH      Base branch to compare against.
                         Default: origin/develop, then origin/main, then origin/master.
  -c, --compare BRANCH   Branch to compare with the base.
                         Default: current branch (HEAD).
  -h, --help             Show this help and exit.

Examples:
  git_rev_list.sh
  git_rev_list.sh --base origin/main
  git_rev_list.sh -b origin/develop -c feature/foo
EOF
}

base_branch=""
compare_branch=""

while [[ $# -gt 0 ]]; do
  case "$1" in
    -h | --help)
      usage
      exit 0
      ;;
    -b | --base)
      [[ -n "${2:-}" ]] || die_usage "--base requires a value"
      base_branch="$2"
      shift 2
      ;;
    -c | --compare)
      [[ -n "${2:-}" ]] || die_usage "--compare requires a value"
      compare_branch="$2"
      shift 2
      ;;
    -*)
      die_usage "unknown flag: $1 (try --help)"
      ;;
    *)
      die_usage "unexpected argument: $1 (try --help)"
      ;;
  esac
done

require_cmd "git"

# Must be inside a Git work tree.
if ! git rev-parse --is-inside-work-tree >/dev/null 2>&1; then
  die "Not inside a Git repository."
fi

# Determine the base branch if not explicitly set.
if [[ -z "$base_branch" ]]; then
  echo "Determining the base branch..."
  if git show-ref --verify --quiet refs/remotes/origin/develop; then
    base_branch="origin/develop"
  elif git show-ref --verify --quiet refs/remotes/origin/main; then
    base_branch="origin/main"
  elif git show-ref --verify --quiet refs/remotes/origin/master; then
    base_branch="origin/master"
  else
    die "No base branch found. Repo lacks origin/develop, origin/main, and origin/master. Pass --base explicitly."
  fi
fi

# Get the current branch if compare branch is not provided.
if [[ -z "$compare_branch" ]]; then
  compare_branch="$(git rev-parse --abbrev-ref HEAD)"
fi

# Ensure refs are current before comparing.
echo "Fetching latest changes..."
git fetch --all || die "git fetch --all failed"

# Run the git rev-list command.
echo "Comparing $base_branch to $compare_branch..."
behind_ahead="$(git rev-list --left-right --count "$base_branch...$compare_branch" 2>/dev/null)" ||
  die "Failed to compare $base_branch and $compare_branch. Ensure both branches exist."

# Split the output into variables for clarity.
behind="$(echo "$behind_ahead" | awk '{print $1}')"
ahead="$(echo "$behind_ahead" | awk '{print $2}')"

# Display the formatted output.
echo "Behind $base_branch by: $behind commits"
echo "Ahead of $base_branch by: $ahead commits"
