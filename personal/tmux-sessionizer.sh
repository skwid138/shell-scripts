#!/usr/bin/env bash
# tmux-sessionizer — fast project switcher for tmux.
#
# Inspired by ThePrimeagen's tmux-sessionizer but rewritten to follow
# this repo's conventions (lib/common.sh helpers, --help, bats tests).
#
# Behavior:
#   - With no args: fzf-pick over PROJECT_DIRS (~/code/* and ~/code/wpromote/*).
#   - With one arg: treat as a path; skip fzf.
#   - Sanitizes session name from basename (dots → underscores, : → _).
#   - If session exists: switch-client / attach. Else create detached then switch.
#   - Outside tmux: detach-and-attach. Inside tmux: switch-client.
#
# Bound from tmux.conf:
#   bind -r f run-shell "tmux neww ~/code/scripts/personal/tmux-sessionizer.sh"
#
# Exit codes (per docs/EXIT-CODES.md):
#   0  success (or user cancelled fzf)
#   2  usage error
#   3  missing dependency (fzf, fd, tmux)

set -uo pipefail
source "$(dirname "$0")/../lib/common.sh"

usage() {
  cat <<'EOF'
Usage: tmux-sessionizer [PATH]

Fast project switcher for tmux. With no PATH, fuzzy-picks from project dirs.

Arguments:
  PATH    Optional path to use as the session root. Skips fzf.

Options:
  -h, --help    Show this help.

Project search dirs (override via TMUX_SESSIONIZER_DIRS, colon-separated):
  ~/code
  ~/code/wpromote

Behavior:
  - Picks (or accepts) a directory.
  - Sanitizes a session name from its basename.
  - Reuses an existing tmux session with that name, or creates one.
  - Switches the active tmux client into it (or attaches if outside tmux).

Examples:
  tmux-sessionizer                   # interactive
  tmux-sessionizer ~/code/scripts    # direct
EOF
}

if [[ "${1:-}" == "-h" || "${1:-}" == "--help" ]]; then
  usage
  exit 0
fi

# Reject unknown flags (anything starting with -).
if [[ "${1:-}" == -* ]]; then
  die_usage "unknown flag: $1 (try --help)"
fi

require_cmd "tmux" "brew install tmux"

# Default project dirs; override via env. Colon-separated.
PROJECT_DIRS="${TMUX_SESSIONIZER_DIRS:-$HOME/code:$HOME/code/wpromote}"

# Sanitize a path's basename into a valid tmux session name.
# tmux disallows '.' and ':' in session names — replace both with '_'.
sanitize_name() {
  local raw="$1"
  raw="$(basename "$raw")"
  printf '%s' "${raw//[.:]/_}"
}

# Pick a directory.
selected=""
if [[ $# -ge 1 ]]; then
  selected="$1"
else
  require_cmd "fzf" "brew install fzf"
  require_cmd "fd" "brew install fd"

  # Build search paths array, skipping any that don't exist.
  IFS=':' read -ra search_paths <<<"$PROJECT_DIRS"
  existing_paths=()
  for p in "${search_paths[@]}"; do
    [[ -d "$p" ]] && existing_paths+=("$p")
  done
  [[ ${#existing_paths[@]} -gt 0 ]] || die "No project dirs exist (looked in: $PROJECT_DIRS)"

  # `fd --max-depth 1 --type d` lists immediate subdirs across all roots.
  selected="$(fd --max-depth 1 --type d . "${existing_paths[@]}" 2>/dev/null | fzf --prompt='project> ' || true)"

  # Empty = user cancelled fzf; exit cleanly (not an error).
  [[ -n "$selected" ]] || exit 0
fi

[[ -d "$selected" ]] || die "Not a directory: $selected"

session_name="$(sanitize_name "$selected")"

# Detect whether we're already inside a tmux session.
in_tmux=0
[[ -n "${TMUX:-}" ]] && in_tmux=1

# Detect whether tmux server is running at all (has any sessions).
tmux_server_running=0
tmux has-session 2>/dev/null && tmux_server_running=1

# If no server is running and we're not in tmux: just attach to a new session.
if [[ $in_tmux -eq 0 && $tmux_server_running -eq 0 ]]; then
  exec tmux new-session -s "$session_name" -c "$selected"
fi

# Server is running (or we're inside it). Reuse if session exists, else create.
if ! tmux has-session -t="$session_name" 2>/dev/null; then
  tmux new-session -ds "$session_name" -c "$selected"
fi

if [[ $in_tmux -eq 1 ]]; then
  tmux switch-client -t "$session_name"
else
  exec tmux attach-session -t "$session_name"
fi
