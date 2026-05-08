#!/usr/bin/env bash
# opencode-wrapper.sh — conditional-config launcher for opencode.
#
# Lives at the source-of-truth path; symlinked from
# ~/.config/opencode/bin/opencode so that PATH-prepending the
# ~/.config/opencode/bin directory makes it intercept `opencode`
# invocations transparently.
#
# Why this exists
# ----------------
# opencode has no native conditional instruction loading: every entry in
# `instructions[]` is loaded into every session regardless of $PWD.
# The personal config carries Wpromote-only context (codebase topology,
# private scripts) that is noise outside ~/code/wpromote/. This wrapper
# uses opencode's documented OPENCODE_CONFIG_CONTENT injection point to
# append the Wpromote instruction file ONLY when invoked from a path
# under ~/code/wpromote/.
#
# Carve-outs
# ----------
# - `opencode web` and `opencode attach` are passed through untouched.
#   `web` boots a long-lived server whose config is frozen at startup —
#   conditional injection there would freeze whatever wpromote-state was
#   true at boot for every later session. `attach` is a TUI client; the
#   server already made its decision. Both are cleaner as "global config
#   only" than as "wpromote-state-frozen-at-boot".
# - `--no-conditional` is a manual escape hatch: skip the injection and
#   exec opencode unmodified.
# - `--help` / `-h` print this wrapper's own usage and exit 0. They do
#   NOT pass through to the real opencode; that would make the wrapper
#   indistinguishable from the binary it wraps and break the --help
#   contract that scripts-doctor enforces.
#
# Verbose mode
# ------------
# Set OPENCODE_WRAPPER_VERBOSE=1 to see a one-line stderr note when the
# wpromote injection fires. Off by default to keep openweb / openattach /
# pipeline invocations quiet.
#
# Recursion safety
# ----------------
# The wrapper resolves the "real" opencode by walking $PATH and skipping
# any candidate that resolves (via realpath) to this same script. If no
# real binary is found, the wrapper exits 3 with an install hint. This
# means putting the wrapper directory at the front of PATH cannot loop
# even if $PATH is misconfigured.
#
# Exit codes follow lib/common.sh:
#   0  success / clean exec into real opencode
#   2  usage error (unknown flag)
#   3  missing dependency (real opencode not found on PATH)

set -uo pipefail

SCRIPT_DIR="$(cd "$(dirname "${BASH_SOURCE[0]}")" && pwd)"
# shellcheck source=../lib/common.sh
source "$SCRIPT_DIR/../lib/common.sh"

usage() {
  cat <<'EOF'
Usage: opencode-wrapper.sh [--no-conditional] [opencode-args...]

A thin wrapper around `opencode` that conditionally injects Wpromote
instruction context (via OPENCODE_CONFIG_CONTENT) when $PWD is under
~/code/wpromote/.

Options:
  --no-conditional   Skip the conditional injection; exec opencode unmodified.
  -h, --help         Show this help. Does NOT pass through to opencode.

Carve-outs (always passed through unmodified):
  opencode web       Long-lived server; injection would freeze wpromote-state.
  opencode attach    TUI client; server already loaded its config.

Environment:
  OPENCODE_WRAPPER_VERBOSE=1   Print a stderr note when injection fires.

Symlink:
  Source-of-truth: ~/code/scripts/personal/opencode-wrapper.sh
  PATH entry:      ~/.config/opencode/bin/opencode  (symlink)

  Repair the symlink with:
    ~/.config/opencode/bin/install-wrapper.sh

  Audit it via:
    scripts-doctor

See:
  ~/.config/opencode/README.md  (Conditional Wpromote instructions section)
EOF
}

# --- arg parsing -------------------------------------------------------------
#
# We do a *minimal* parse: peek at our own flags / help, otherwise pass the
# entire argv through to the real opencode. We must not consume opencode's
# own flags by accident.

NO_CONDITIONAL=0
# A bare `--help` / `-h` as the FIRST argument is treated as ours. Anything
# after positional args belongs to opencode (e.g. `opencode run --help`
# would target `run`'s help, but our wrapper never sees that pattern as
# arg #1 anyway).
case "${1:-}" in
  -h | --help)
    usage
    exit 0
    ;;
  --no-conditional)
    NO_CONDITIONAL=1
    shift
    ;;
esac

# --- locate the real opencode binary ----------------------------------------
#
# We walk $PATH manually rather than calling `command -v opencode` because
# `command -v` would happily return our own symlink if the wrapper directory
# is earlier on PATH (which is the *expected* configuration). Skipping any
# candidate whose realpath equals this script's realpath is the recursion
# guard.

# realpath isn't on every macOS box; fall back to a portable readlink loop.
canonicalize() {
  local p="$1"
  if command -v realpath >/dev/null 2>&1; then
    realpath "$p" 2>/dev/null && return 0
  fi
  # Portable fallback: readlink-loop. Bash 3.2 safe.
  local prev=""
  while [[ -L "$p" && "$p" != "$prev" ]]; do
    prev="$p"
    local target
    target="$(readlink "$p" 2>/dev/null)" || break
    if [[ "$target" == /* ]]; then
      p="$target"
    else
      p="$(dirname "$p")/$target"
    fi
  done
  # Resolve dirname to absolute, then re-attach basename.
  local dir base
  dir="$(cd "$(dirname "$p")" 2>/dev/null && pwd)" || {
    printf '%s\n' "$p"
    return 0
  }
  base="$(basename "$p")"
  printf '%s/%s\n' "$dir" "$base"
}

self_real="$(canonicalize "${BASH_SOURCE[0]}")"

find_real_opencode() {
  local IFS=:
  # shellcheck disable=SC2206  # intentional word splitting on $PATH
  local parts=($PATH)
  local d cand cand_real
  for d in "${parts[@]}"; do
    [[ -n "$d" ]] || continue
    cand="$d/opencode"
    [[ -x "$cand" ]] || continue
    cand_real="$(canonicalize "$cand")"
    [[ "$cand_real" != "$self_real" ]] || continue
    printf '%s\n' "$cand"
    return 0
  done
  return 1
}

REAL_OPENCODE="$(find_real_opencode)" || die_missing_dep \
  "real 'opencode' binary not found on PATH (the wrapper at $self_real is the only match). Install with: brew install anomalyco/tap/opencode"

# --- subcommand carve-out: web / attach pass through unmodified --------------

case "${1:-}" in
  web | attach)
    exec "$REAL_OPENCODE" "$@"
    ;;
esac

# --- conditional injection ---------------------------------------------------

WPROMOTE_ROOT="$HOME/code/wpromote"
WPROMOTE_INSTRUCTION="$HOME/.config/opencode/instruction/wpromote-context.md"

# Trailing-slash compare so /Users/hunter/code/wpromotex doesn't match.
# Use $PWD/ vs "$WPROMOTE_ROOT/" prefix.
under_wpromote=0
case "$PWD/" in
  "$WPROMOTE_ROOT"/*) under_wpromote=1 ;;
esac

if [[ "$NO_CONDITIONAL" -eq 0 && "$under_wpromote" -eq 1 ]]; then
  if [[ -f "$WPROMOTE_INSTRUCTION" ]]; then
    # OPENCODE_CONFIG_CONTENT is a JSON-encoded config that opencode merges
    # at load time. `instructions[]` arrays are concatenated across config
    # layers (see ~/.config/opencode/.project-plans/radagast-conditional-instructions.md).
    # We use ~/ in the path; opencode expands it at instruction resolution.
    export OPENCODE_CONFIG_CONTENT='{"instructions":["~/.config/opencode/instruction/wpromote-context.md"]}'
    if [[ "${OPENCODE_WRAPPER_VERBOSE:-0}" == "1" ]]; then
      info "wpromote conditional context loaded ($PWD)"
    fi
  else
    # Symlink/install drift detected. Don't fail — the user's session is
    # more important than the conditional context — but warn audibly so
    # they fix it.
    warn "wpromote instruction file missing at $WPROMOTE_INSTRUCTION; skipping conditional context. Run: ~/.config/opencode/bin/install-wrapper.sh --check"
  fi
fi

exec "$REAL_OPENCODE" "$@"
