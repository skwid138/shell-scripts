#!/usr/bin/env bash
# opencode-daemon.sh — shared helpers for opencode `web` daemon lifecycle.
#
# Source this file from openweb / openattach / opensession to:
#   - Detect whether a daemon is bound to a given port (port-scoped, no globals).
#   - Compute a content hash over $OPENCODE_CONFIG_DIR for staleness detection.
#   - Write / read / compare per-(port, pid) sidecar files that pin the config
#     snapshot a running daemon was started against.
#   - Kill a daemon cleanly and wait for the port to free.
#   - Wait for a freshly-spawned daemon's listener to bind, with identity
#     verification (ps -o comm= — NOT pgrep -f, which matches caffeinate too).
#   - Prompt the user when an attached client lands on a stale daemon.
#
# Design rationale and acceptance criteria:
#   ~/.config/opencode/.project-plans/2026-05-10_q2-openattach-plan.md
#
# Why "self-contained, port-scoped, no globals":
#   1. Every function takes <port> explicitly so OPENCODE_WEB_PORT=other shells
#      behave correctly (no implicit "the daemon").
#   2. Callers pass any captured pid/hash explicitly into log messages — the
#      helpers never set ambient state. This keeps the unit-test surface clean
#      and avoids the classic "which $DAEMON_PID is this referring to" bug.
#   3. Listener identity is verified via `ps -o comm= -p $pid` (basename strip),
#      NOT via `pgrep -f 'opencode web'` set membership. Empirically (2026-05-10)
#      pgrep matches BOTH the opencode listener AND the caffeinate wrapper
#      because caffeinate's argv contains the substring 'opencode web'.
#
# Exit-code convention follows lib/common.sh. Missing tools = exit 3 via
# require_cmd. No graceful degradation — see plan §"Failure modes covered".

# Re-source guard — mirrors lib/keychain.sh / lib/common.sh pattern.
if [[ -n "${_LIB_OPENCODE_DAEMON_LOADED:-}" ]]; then
  return 0 2>/dev/null || exit 0
fi
_LIB_OPENCODE_DAEMON_LOADED=1

# Resolve this file's directory robustly under bash (BASH_SOURCE) AND zsh
# (where BASH_SOURCE is empty and we use %x). Same pattern as keychain.sh.
if [[ -z "${_LIB_COMMON_LOADED:-}" ]]; then
  if [[ -n "${BASH_SOURCE[0]:-}" ]]; then
    _opencode_daemon_self="${BASH_SOURCE[0]}"
  elif [[ -n "${ZSH_VERSION:-}" ]]; then
    eval '_opencode_daemon_self="${(%):-%x}"'
  else
    _opencode_daemon_self="$HOME/code/scripts/lib/opencode-daemon.sh"
  fi
  _opencode_daemon_dir="$(cd "$(dirname "$_opencode_daemon_self")" && pwd)"
  # shellcheck source=common.sh
  source "$_opencode_daemon_dir/common.sh"
  unset _opencode_daemon_self _opencode_daemon_dir
fi

# --- mandatory dependency gates (source-time, no graceful degradation) -------
#
# All system tools the helper relies on are checked here. Absence = exit 3.
# The plan REJECTS fallback paths: it's better to fail loudly at source time
# than silently degrade staleness detection or identity verification.
require_cmd pgrep
require_cmd lsof
require_cmd ps
require_cmd date
require_cmd stat
require_cmd shasum

# Default location of opencode's config tree. Override for tests with
# OPENCODE_CONFIG_DIR=<path>. The daemon itself reads the same env var.
: "${OPENCODE_CONFIG_DIR:=$HOME/.config/opencode}"

# Where sidecar files live. Pinned to ~/.local/share/opencode so it sits next
# to the daemon's SQLite state, NOT under config dir (the hash function would
# otherwise pick up sidecars themselves and create a feedback loop).
: "${OPENCODE_DAEMON_STATE_DIR:=$HOME/.local/share/opencode}"

# --- identity primitives ----------------------------------------------------

# opencode_pid_is_opencode_web <pid>
#
# Exit 0 if $pid's executable basename is exactly "opencode". Non-zero otherwise.
#
# Why basename strip: macOS `ps -o comm=` returns the full executable path
# (e.g. `/opt/homebrew/bin/opencode`); Linux / older macOS may return the bare
# command name. `${comm##*/}` handles both forms. Empty `comm` (process gone
# between calls) yields empty string, which doesn't equal "opencode" → fails.
#
# This replaces the previous reliance on `pgrep -f 'opencode web'` set
# membership for identity. pgrep -f matches caffeinate too (its argv contains
# the substring) so it can't distinguish the listener from the wrapper.
opencode_pid_is_opencode_web() {
  local pid="${1:-}"
  [[ -n "$pid" ]] || return 1
  local comm
  comm="$(ps -o comm= -p "$pid" 2>/dev/null | tr -d '[:space:]')"
  [[ "${comm##*/}" == "opencode" ]]
}

# opencode_port_listener_pid <port>
#
# Prints the pid of WHATEVER process is bound to tcp:<port> in LISTEN state,
# or returns non-zero with no stdout if no listener.
#
# Implementation note: -sTCP:LISTEN is mandatory. Without it, `lsof -ti tcp:N`
# would also match ESTABLISHED connections (e.g. attached opencode TUIs),
# yielding multiple pids and breaking the single-source-of-truth contract.
opencode_port_listener_pid() {
  local port="${1:?port required}"
  local pid
  pid="$(lsof -ti "tcp:$port" -sTCP:LISTEN 2>/dev/null || true)"
  [[ -n "$pid" ]] || return 1
  printf '%s\n' "$pid"
}

# opencode_daemon_pid_for_port <port>
#
# Prints the pid of the opencode-web daemon bound to <port>, or non-zero if
# either (a) nothing is listening on <port>, or (b) something IS listening but
# it isn't an opencode process.
#
# Single source of truth for "is there a daemon for this port." Callers in
# openweb / openattach / opensession go through this — never re-derive it
# from pgrep themselves.
#
# On the "listener exists but isn't opencode" case, emits a debug-stderr note
# with the offending pid + comm so openweb's pre-bind check can produce the
# distinct "port taken by pid N (<comm>), not opencode" error. (The visible
# error message is the caller's responsibility; this helper only signals.)
opencode_daemon_pid_for_port() {
  local port="${1:?port required}"
  local pid
  pid="$(opencode_port_listener_pid "$port" 2>/dev/null)" || return 1
  if opencode_pid_is_opencode_web "$pid"; then
    printf '%s\n' "$pid"
    return 0
  fi
  # Listener exists but isn't opencode-web. Surface the comm so the caller
  # can produce an actionable error. Use debug() so quiet operation stays
  # quiet; caller decides whether to escalate.
  local foreign_comm
  foreign_comm="$(ps -o comm= -p "$pid" 2>/dev/null | tr -d '[:space:]')"
  debug "port :$port held by pid $pid (${foreign_comm##*/}), not opencode"
  return 1
}

# opencode_daemon_start_epoch <pid>
#
# Prints the daemon's start time as a Unix epoch. Used ONLY for human-readable
# warning messages ("daemon started 2 days ago"). Staleness detection is
# content-hash-based — never derive staleness from start time.
#
# macOS `ps -o lstart=` returns BSD-format datetime; parse with BSD `date -j -f`.
# We hard-code /bin/date to dodge the user's coreutils-gnubin shadowing
# /opt/homebrew/opt/coreutils/libexec/gnubin/date, which has different flags.
opencode_daemon_start_epoch() {
  local pid="${1:?pid required}"
  local lstart
  lstart="$(ps -o lstart= -p "$pid" 2>/dev/null | sed -e 's/^ *//' -e 's/ *$//')"
  [[ -n "$lstart" ]] || return 1
  /bin/date -j -f "%a %b %e %H:%M:%S %Y" "$lstart" +%s 2>/dev/null
}

# --- config-relevant file enumeration + content hashing ----------------------

# opencode_config_relevant_files
#
# Emits a sorted, NUL-terminated list of regular files AND symlinks under
# $OPENCODE_CONFIG_DIR that the daemon would read at startup, MINUS the
# documented ignore list. Sort order is LC_ALL=C for cross-locale determinism
# (otherwise the digest could vary across machines with identical content).
#
# Ignore patterns (rationale per entry in plan §"opencode_config_relevant_files"):
#   README*.md                — documentation; not loaded at startup
#   .project-plans/*          — working notes (editing this VERY plan must
#                                NOT mark the daemon stale)
#   logs/*, log/*             — runtime output, churns constantly
#   node_modules/*            — vendored deps, huge tree
#   package-lock.json         — lockfile, only relevant for `npm install`
#   .git/*                    — VCS metadata
#   daemon-config-hash-*      — defensive guard against sidecar dirs ever
#                                ending up under config dir
#
# Symlinks are included as ENTRIES (one per link), not dereferenced. Downstream
# the hash function uses readlink output (the target path string), so retargeting
# bin/opencode → another path is detected as a config change while the wrapper
# script's content (living in a different repo) is correctly out of scope.
opencode_config_relevant_files() {
  [[ -d "$OPENCODE_CONFIG_DIR" ]] || return 0
  # Use a process-substitution-free pipeline so this stays bash-3.2 portable.
  # The `cd` makes find emit paths relative to the config dir; that's what
  # ends up in the hash input, so two machines with identically-named configs
  # under different $HOME paths produce identical digests.
  (
    cd "$OPENCODE_CONFIG_DIR" 2>/dev/null || exit 0
    find . \( -type f -o -type l \) -print0 2>/dev/null |
      LC_ALL=C sort -z |
      grep -zvE '(^|/)README[^/]*\.md$' |
      grep -zvE '(^|/)\.project-plans/' |
      grep -zvE '(^|/)logs/' |
      grep -zvE '(^|/)log/' |
      grep -zvE '(^|/)node_modules/' |
      grep -zvE '(^|/)package-lock\.json$' |
      grep -zvE '(^|/)\.git/' |
      grep -zvE '(^|/)daemon-config-hash-'
  )
}

# opencode_config_content_hash
#
# Prints a single 64-char sha256 hex digest representing the content (or
# symlink target string, for symlinks) of every config-relevant file. Stable
# under permission-only changes, atomic byte-identical rewrites, locale
# variation, and ignored-file churn. Changes on:
#   - file content modified
#   - included file added or removed
#   - symlink target changed
#
# Why double-hash (per-file digest then digest-of-digests):
#   - Catches added/removed entries (new/missing line in the inner stream).
#   - Catches per-file content changes (digest changes in the inner stream).
#   - Final hash collapses the variable-length inner stream into a fixed-width
#     digest suitable for a sidecar file.
opencode_config_content_hash() {
  [[ -d "$OPENCODE_CONFIG_DIR" ]] || {
    # Empty config dir hashes deterministically; mirrors `printf '' | shasum`.
    printf '' | shasum -a 256 | awk '{print $1}'
    return 0
  }
  (
    cd "$OPENCODE_CONFIG_DIR" 2>/dev/null || exit 1
    # Stream NUL-terminated relative paths; for each emit "<digest>  <path>".
    opencode_config_relevant_files | while IFS= read -r -d '' rel; do
      # Strip leading ./ for stable paths.
      rel="${rel#./}"
      if [[ -L "$rel" ]]; then
        # Symlink → hash the target path string, NOT the dereferenced content.
        # Threat model: user retargeting bin/opencode is the staleness signal;
        # wrapper content lives in another repo where this mechanism doesn't
        # reach anyway, and dereferencing risks escape-from-config-dir.
        target="$(readlink "$rel")"
        digest="$(printf '%s' "$target" | shasum -a 256 | awk '{print $1}')"
        printf '%s  %s\n' "$digest" "$rel"
      elif [[ -f "$rel" ]]; then
        digest="$(shasum -a 256 <"$rel" | awk '{print $1}')"
        printf '%s  %s\n' "$digest" "$rel"
      fi
    done | shasum -a 256 | awk '{print $1}'
  )
}

# --- sidecar lifecycle -------------------------------------------------------
#
# Sidecar path: $OPENCODE_DAEMON_STATE_DIR/daemon-config-hash-<port>-<pid>
#
# Port AND pid scoped, so:
#   - Two daemons on different ports never collide.
#   - Crashed-daemon leftovers are harmless: a future unrelated process getting
#     the same pid AND happening to be opencode-web on the same port AND somehow
#     not going through openweb is the only way an orphan matches. Option Y
#     ensures every openweb-started daemon overwrites its sidecar at start.

# _opencode_sidecar_path <port> <pid>  (internal)
_opencode_sidecar_path() {
  printf '%s/daemon-config-hash-%s-%s\n' "$OPENCODE_DAEMON_STATE_DIR" "$1" "$2"
}

# opencode_daemon_write_sidecar <port> <pid>
#
# Atomically writes the current content hash to the sidecar for (port, pid).
# Atomicity matters because a concurrent openattach staleness check could
# race a half-written file; using tempfile + mv (same filesystem) eliminates
# the partial-read window.
#
# Returns non-zero on any failure (disk full, EROFS, hash failure). Callers
# under `set -euo pipefail` (openweb) abort on failure, leaving the daemon
# with no sidecar; the next openattach treats that as stale + warns. The plan
# explicitly forbids `|| true` wrapping here — that would hide real disk
# failures and produce silent staleness on every subsequent attach.
opencode_daemon_write_sidecar() {
  local port="${1:?port required}" pid="${2:?pid required}"
  mkdir -p "$OPENCODE_DAEMON_STATE_DIR" || return 1
  local final tmp hash
  final="$(_opencode_sidecar_path "$port" "$pid")"
  tmp="$OPENCODE_DAEMON_STATE_DIR/.daemon-config-hash-${port}-${pid}.tmp.$$"
  hash="$(opencode_config_content_hash)" || return 1
  [[ -n "$hash" ]] || return 1
  printf '%s\n' "$hash" >"$tmp" || {
    rm -f "$tmp"
    return 1
  }
  mv -f "$tmp" "$final" || {
    rm -f "$tmp"
    return 1
  }
}

# opencode_daemon_remove_sidecar <port> <pid>
#
# Removes the sidecar for (port, pid). Missing sidecar is not an error
# (crash-restart, pre-feature daemon, manual cleanup). Called by
# opencode_kill_daemon after the port is verified free.
opencode_daemon_remove_sidecar() {
  local port="${1:?port required}" pid="${2:?pid required}"
  rm -f "$(_opencode_sidecar_path "$port" "$pid")"
}

# opencode_daemon_is_stale <port> <pid>
#
# Contract: caller MUST have already confirmed via opencode_daemon_pid_for_port
# that a daemon exists on <port> with this <pid>. This function does NOT
# re-verify daemon liveness. Calling it without a daemon is a programming error.
#
# Return semantics:
#   0 = stale     (sidecar missing OR corrupt OR hash mismatch)
#   1 = fresh     (sidecar present, well-formed, matches current hash)
#
# The missing/corrupt cases also emit a `warn` so users can distinguish
# "config genuinely changed since daemon start" from "we don't actually know
# the daemon's start-time config because the sidecar is gone." The latter
# matters for the user's mental model — a missing sidecar after a daemon
# crash is a real piece of information, not a routine.
opencode_daemon_is_stale() {
  local port="${1:?port required}" pid="${2:?pid required}"
  local sidecar
  sidecar="$(_opencode_sidecar_path "$port" "$pid")"

  if [[ ! -r "$sidecar" ]]; then
    warn "no config-hash sidecar for daemon on :$port (pid $pid); treating as stale (crash-restart? pre-feature daemon? sidecar deleted?)"
    return 0
  fi

  local recorded
  recorded="$(<"$sidecar")"
  # Validate: must be exactly 64 lowercase hex chars (sha256 hex output).
  if [[ ! "$recorded" =~ ^[0-9a-f]{64}$ ]]; then
    warn "sidecar for daemon on :$port (pid $pid) is corrupt; treating as stale"
    return 0
  fi

  local current
  current="$(opencode_config_content_hash)"
  [[ "$current" != "$recorded" ]] # 0 (stale) iff they differ
}

# opencode_kill_daemon <pid> <port> [timeout=5]
#
# Sends SIGTERM to <pid> (NOT SIGKILL — opencode needs the WAL to flush
# cleanly), polls opencode_port_listener_pid until the port is free or the
# timeout expires. On success removes the sidecar for this (port, pid).
#
# Takes <port> so it can verify the kill actually freed THIS port — important
# if the daemon's pid was somehow reused mid-kill (extremely unlikely but
# cheap to guard against).
opencode_kill_daemon() {
  local pid="${1:?pid required}" port="${2:?port required}" timeout="${3:-5}"
  kill -TERM "$pid" 2>/dev/null || true
  local deadline waited
  deadline=$(($(date +%s) + timeout))
  while (($(date +%s) < deadline)); do
    if ! opencode_port_listener_pid "$port" >/dev/null 2>&1; then
      opencode_daemon_remove_sidecar "$port" "$pid"
      return 0
    fi
    sleep 0.2
  done
  return 1
}

# opencode_wait_for_port_free <port> [timeout=5]
#
# Polls opencode_port_listener_pid <port> until no listener is bound, or the
# timeout expires. Returns 0 once the port is free, non-zero on timeout.
#
# Distinct from opencode_kill_daemon's internal polling because:
#   - This helper does NOT send a signal — the caller is responsible for that.
#   - This helper does NOT touch the sidecar (the foreign-process case has no
#     sidecar to remove).
#
# Used by openweb's --force path, where we kill whatever holds the port
# (opencode-web daemon OR foreign listener) and need to confirm the port
# actually frees before we spawn the replacement.
opencode_wait_for_port_free() {
  local port="${1:?port required}" timeout="${2:-5}"
  local deadline
  deadline=$(($(date +%s) + timeout))
  while (($(date +%s) < deadline)); do
    if ! opencode_port_listener_pid "$port" >/dev/null 2>&1; then
      return 0
    fi
    sleep 0.2
  done
  return 1
}

# opencode_wait_for_opencode_listener <port> [timeout=5]
#
# Polls until a process is bound to tcp:<port> AND that process passes the
# `comm`-based opencode-identity check. On success prints the verified pid to
# stdout and returns 0. Used by openweb (post-spawn) and opensession (after
# background-spawning openweb) as the authoritative way to discover the real
# daemon pid for sidecar writes / log messages.
#
# Listener-identity fail-fast (race regression): if the port becomes bound
# but the listener's `comm` is NOT "opencode", emit die_upstream with the
# offending pid + comm. This is the regression Saruman flagged for the
# "some other process grabs the port between our pre-check and the daemon
# binding" race.
#
# Timeout with no listener = quiet non-zero return; caller decides the message.
opencode_wait_for_opencode_listener() {
  local port="${1:?port required}" timeout="${2:-5}"
  local deadline pid comm
  deadline=$(($(date +%s) + timeout))
  while (($(date +%s) < deadline)); do
    pid="$(opencode_port_listener_pid "$port" 2>/dev/null)" || {
      sleep 0.1
      continue
    }
    if opencode_pid_is_opencode_web "$pid"; then
      printf '%s\n' "$pid"
      return 0
    fi
    # Port bound, but by a non-opencode process. Fail fast with the
    # listener-identity message (covers the race regression).
    comm="$(ps -o comm= -p "$pid" 2>/dev/null | tr -d '[:space:]')"
    die_upstream "port :$port taken by pid $pid (${comm##*/}), not opencode — kill it or use OPENCODE_WEB_PORT=…"
  done
  return 1
}

# prompt_continue_on_stale <pid> <start_epoch> <port>
#
# Extracted from openattach for testability. Reads y/n from fd 3 and writes
# prompt UI to fd 4. The caller is responsible for wiring those fds — typically
# fd 3 ← /dev/tty, fd 4 → /dev/tty — gated by the `: >/dev/tty 2>/dev/null`
# writability check. Keeping /dev/tty knowledge out of this function is what
# makes it bats-testable with stub fds.
#
# Returns 0 if user types y/Y, non-zero on n/empty/EOF/anything else.
prompt_continue_on_stale() {
  local pid="${1:?pid required}" start_epoch="${2:?start_epoch required}" port="${3:?port required}"
  local started reply
  started="$(/bin/date -r "$start_epoch" '+%Y-%m-%d %H:%M:%S' 2>/dev/null || printf 'unknown')"
  printf 'Stale daemon on :%s (pid %s, started %s).\n' "$port" "$pid" "$started" >&4
  printf 'Config has changed since daemon start.\n' >&4
  printf 'Continue attaching anyway? [y/N] ' >&4
  reply=""
  IFS= read -r reply <&3 || reply=""
  [[ "$reply" =~ ^[yY] ]]
}
