#!/bin/bash

## Count all regular files (including hidden) recursively under a given directory
## Example: countf ~/code/scripts
countf() {
  local dir="${1:?usage: countf <dir>}"
  find "$dir" -type f | wc -l
}

## Count all non-hidden regular files recursively under a given directory
## "Non-hidden" = no path component starts with '.'
## Example: countf_a ~/code/scripts
countf_a() {
  local dir="${1:?usage: countf_a <dir>}"
  # -not -path '*/.*' prunes any path containing a hidden segment.
  # Works on macOS BSD find and GNU find alike.
  find "$dir" -type f -not -path '*/.*' | wc -l
}

## Debug key codes (zsh-only)
key_debug() {
  echo "Press any key combination to see its code (Ctrl+C to exit)"
  while true; do
    # zsh-specific: -k reads N characters from terminal input.
    # SC2162 (info-level) suggests -r, but -r is for backslash handling
    # in line-mode reads, irrelevant for character-mode key sniffing.
    # shellcheck disable=SC2162
    read -k 1
    echo -n "$REPLY" | hexdump -C
  done
}

## Convert a video's format to a different format using FFmpeg
## Example: clipflip input.mov output.mp4
# The first argument is the input file, and the second argument is the output file
clipflip() {
  local input="$1"
  local output="$2"
  ffmpeg -i "$input" -c:v libx264 -c:a aac "$output"
}

## brew wrapper — auto-refresh hardcoded prefixes in shell/env/paths.zsh
## after path-affecting subcommands. Function form (not alias) so all
## subcommands behave identically to the real binary; only the listed
## mutating commands trigger the regeneration.
##
## Non-interactive caveat (rev. 5 of zsh_init_plan.md §5): this lives in
## rc-tier and is therefore not defined in non-interactive shells. The
## 14-day staleness nag in env/paths.zsh is the safety net for those
## cases (and for background HOMEBREW_AUTO_UPDATE, Brewfile bundles,
## idle machines, brand-new clones).
brew() {
  command brew "$@" || return $?
  case "$1" in
    upgrade | install | uninstall | reinstall | bundle | update)
      # Subshell so cwd is preserved.
      (cd "$HOME/code/scripts" && make refresh-paths) ||
        printf 'warn: brew wrapper: make refresh-paths failed; PATH may be stale\n' >&2
      ;;
  esac
}
