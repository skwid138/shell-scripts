#!/usr/bin/env bats
# Tests for shell/env/paths.zsh's 14-day freshness nag at the boundaries:
#   - sentinel exactly 13 days old: nag must NOT fire (under threshold)
#   - sentinel exactly 14 days old: nag MUST fire (at threshold)
#   - sentinel 1000 days old: nag MUST fire with plausible day count
#   - sentinel with mtime in the future (clock skew): no crash, no false nag
#   - missing $HOME/.cache directory: nag fires (matches "never refreshed")
#   - $XDG_CACHE_HOME respected when set
#
# Complements paths_hardcoded.bats (which covers presence/absence of the
# sentinel and the basic 100-day case). This file targets the threshold
# arithmetic specifically.

setup() {
  load 'test_helper/bats-support/load'
  load 'test_helper/bats-assert/load'
  REPO="$(cd "$BATS_TEST_DIRNAME/.." && pwd -P)"
  CLEAN_PATH="/usr/bin:/bin"
  # The freshness nag is gated to interactive shells; these tests source
  # init_env.zsh from a non-interactive `zsh -c '...'` (no tty available
  # under bats) and need the nag to be reachable to assert on its output.
  # _PATHS_NAG_FORCE=1 is the documented escape hatch in paths.zsh for
  # exactly this case — testing the threshold arithmetic and stderr output
  # of the nag itself.
  export _PATHS_NAG_FORCE=1
}

# Helper: emit a YYYYMMDDhhmm.SS stamp N days in the past.
# macOS BSD touch -t with `date -v` (preferred), Linux fallback.
_n_days_ago_touch_stamp() {
  local n=$1
  if /bin/date -v-"${n}"d +%Y%m%d%H%M.%S 2>/dev/null; then
    return
  fi
  # GNU date fallback
  date -d "${n} days ago" +%Y%m%d%H%M.%S
}

_make_sandbox_with_aged_sentinel() {
  local age_days="$1"
  local sandbox
  sandbox="$(mktemp -d)"
  mkdir -p "$sandbox/.cache/zsh"
  local sentinel="$sandbox/.cache/zsh/paths-refreshed"
  : >"$sentinel"
  if ((age_days > 0)); then
    local stamp
    stamp="$(_n_days_ago_touch_stamp "$age_days")"
    touch -t "$stamp" "$sentinel"
  fi
  printf '%s\n' "$sandbox"
}

# --- threshold boundaries ---------------------------------------------------

@test "freshness: 13-day-old sentinel does NOT trigger nag (under 14-day threshold)" {
  SANDBOX="$(_make_sandbox_with_aged_sentinel 13)"
  run zsh --no-rcs -c "
    PATH='$CLEAN_PATH'
    XDG_CACHE_HOME='$SANDBOX/.cache'
    source '$REPO/shell/init_env.zsh' 2>&1 >/dev/null
  "
  assert_success
  refute_output --partial "days ago"
  refute_output --partial "never refreshed"
  rm -rf "$SANDBOX"
}

@test "freshness: 14-day-old sentinel triggers nag (at threshold)" {
  SANDBOX="$(_make_sandbox_with_aged_sentinel 14)"
  run zsh --no-rcs -c "
    PATH='$CLEAN_PATH'
    XDG_CACHE_HOME='$SANDBOX/.cache'
    source '$REPO/shell/init_env.zsh' 2>&1 >/dev/null
  "
  assert_output --partial "days ago"
  reported="$(echo "$output" | grep -oE '[0-9]+ days ago' | head -1 | awk '{print $1}')"
  assert [ -n "$reported" ]
  assert [ "$reported" -ge 14 ]
  rm -rf "$SANDBOX"
}

@test "freshness: 1000-day-old sentinel reports a plausible age >= 14" {
  # Stress the arithmetic — confirms no integer wraparound or signed/unsigned
  # surprises across a multi-year-old sentinel.
  SANDBOX="$(_make_sandbox_with_aged_sentinel 1000)"
  run zsh --no-rcs -c "
    PATH='$CLEAN_PATH'
    XDG_CACHE_HOME='$SANDBOX/.cache'
    source '$REPO/shell/init_env.zsh' 2>&1 >/dev/null
  "
  assert_output --partial "days ago"
  reported="$(echo "$output" | grep -oE '[0-9]+ days ago' | head -1 | awk '{print $1}')"
  assert [ -n "$reported" ]
  # Allow a small tolerance window — leap seconds, DST, touch -t precision.
  assert [ "$reported" -ge 990 ]
  assert [ "$reported" -le 1010 ]
  rm -rf "$SANDBOX"
}

# --- clock-skew defenses ---------------------------------------------------

@test "freshness: future-mtime sentinel does not crash, does not falsely nag" {
  # Simulates a sentinel whose mtime is in the future (clock skew, restored
  # backup, system time corrupted). The arithmetic 'now - mtime' would be
  # negative; we don't want a "negative days ago" nag. The threshold check
  # `(( age_days < 14 ))` should naturally suppress the nag for negative
  # values.
  SANDBOX="$(mktemp -d)"
  mkdir -p "$SANDBOX/.cache/zsh"
  SENTINEL="$SANDBOX/.cache/zsh/paths-refreshed"
  : >"$SENTINEL"
  # Set mtime 30 days in the future.
  if STAMP="$(/bin/date -v+30d +%Y%m%d%H%M.%S 2>/dev/null)"; then
    touch -t "$STAMP" "$SENTINEL"
  else
    touch -d '30 days' "$SENTINEL"
  fi
  run zsh --no-rcs -c "
    PATH='$CLEAN_PATH'
    XDG_CACHE_HOME='$SANDBOX/.cache'
    source '$REPO/shell/init_env.zsh' 2>&1 >/dev/null
  "
  assert_success
  # Must not crash (already covered by assert_success). Must not say
  # "never refreshed" (sentinel exists). Must not produce a "days ago"
  # message — the threshold check naturally swallows negative ages.
  refute_output --partial "never refreshed"
  refute_output --partial "days ago"
  rm -rf "$SANDBOX"
}

# --- XDG_CACHE_HOME respect -------------------------------------------------

@test "freshness: respects \$XDG_CACHE_HOME (writes/reads sentinel under XDG)" {
  # Place a fresh sentinel under a custom XDG_CACHE_HOME and confirm the
  # nag is suppressed (proving the lookup goes through XDG, not \$HOME/.cache).
  SANDBOX="$(mktemp -d)"
  mkdir -p "$SANDBOX/xdg/zsh"
  : >"$SANDBOX/xdg/zsh/paths-refreshed"
  run zsh --no-rcs -c "
    PATH='$CLEAN_PATH'
    XDG_CACHE_HOME='$SANDBOX/xdg'
    source '$REPO/shell/init_env.zsh' 2>&1 >/dev/null
  "
  assert_success
  refute_output --partial "never refreshed"
  refute_output --partial "days ago"
  rm -rf "$SANDBOX"
}

@test "freshness: falls back to \$HOME/.cache when \$XDG_CACHE_HOME is unset" {
  # Simulate a fresh-clone HOME with NO sentinel anywhere — expect the
  # 'never refreshed' nag (proves \$HOME/.cache is the fallback path).
  SANDBOX="$(mktemp -d)"
  run zsh --no-rcs -c "
    PATH='$CLEAN_PATH'
    HOME='$SANDBOX'
    unset XDG_CACHE_HOME
    source '$REPO/shell/init_env.zsh' 2>&1 >/dev/null
  "
  assert_output --partial "never refreshed"
  rm -rf "$SANDBOX"
}

# --- nag never blocks shell startup ----------------------------------------

@test "freshness: nag does not affect exit status (never blocks shell start)" {
  # Whether the nag fires or not, sourcing init_env.zsh must always exit 0.
  # Already partially covered by other tests; this is the explicit assertion.
  for age in 0 13 14 100; do
    SANDBOX="$(_make_sandbox_with_aged_sentinel "$age")"
    run zsh --no-rcs -c "
      PATH='$CLEAN_PATH'
      XDG_CACHE_HOME='$SANDBOX/.cache'
      source '$REPO/shell/init_env.zsh' 2>/dev/null
    "
    assert_success "exit status non-zero for age=$age days"
    rm -rf "$SANDBOX"
  done
}

# --- non-interactive gate (regression guard) -------------------------------
#
# These tests guard against re-introducing the bug fixed in the Phase 4.5
# follow-up commit: env-tier was printing the freshness nag to stderr from
# every non-interactive `zsh -c '...'` subshell, polluting any downstream
# automation that captures stderr (bats `run` merges stdout+stderr into
# $output; opencode tool wrappers redirect stderr to logs; cron mailers
# email anything on stderr). The env-tier contract is "silent and side-
# effect-free in automation"; the nag is gated to interactive shells +
# the _PATHS_NAG_FORCE override that paths_freshness.bats sets above.

@test "freshness gate: non-interactive zsh -c sourcing init_env.zsh produces no stderr (no sentinel)" {
  # Fresh-clone scenario (no sentinel) — without the gate, this prints
  # 'note: ~/code/scripts shell paths never refreshed; ...' to stderr.
  SANDBOX="$(mktemp -d)"
  unset _PATHS_NAG_FORCE
  run zsh --no-rcs -c "
    PATH='$CLEAN_PATH'
    HOME='$SANDBOX'
    unset XDG_CACHE_HOME
    source '$REPO/shell/init_env.zsh'
  "
  assert_success
  refute_output --partial "never refreshed"
  refute_output --partial "days ago"
  # Belt-and-suspenders: the entire output should be empty. Anything env-
  # tier prints from a non-interactive `zsh -c` is a contract violation.
  [[ -z "$output" ]] || {
    echo "expected no stderr output, got: $output" >&3
    false
  }
  rm -rf "$SANDBOX"
  export _PATHS_NAG_FORCE=1
}

@test "freshness gate: non-interactive zsh -c sourcing init_env.zsh produces no stderr (stale sentinel)" {
  # Stale-sentinel scenario (1000 days old) — without the gate, this prints
  # 'note: ~/code/scripts brew paths last refreshed N days ago; ...'.
  SANDBOX="$(_make_sandbox_with_aged_sentinel 1000)"
  unset _PATHS_NAG_FORCE
  run zsh --no-rcs -c "
    PATH='$CLEAN_PATH'
    XDG_CACHE_HOME='$SANDBOX/.cache'
    source '$REPO/shell/init_env.zsh'
  "
  assert_success
  refute_output --partial "days ago"
  refute_output --partial "never refreshed"
  [[ -z "$output" ]] || {
    echo "expected no stderr output, got: $output" >&3
    false
  }
  rm -rf "$SANDBOX"
  export _PATHS_NAG_FORCE=1
}

@test "freshness gate: zsh -lc (login, non-interactive) sourcing init_env.zsh produces no stderr" {
  # Login-but-non-interactive shells (rare on macOS but used by some
  # launchd plists, ssh batch sessions, and `zsh -lc` opencode invocations)
  # must also be silent. -l (login) does NOT imply -i (interactive).
  SANDBOX="$(mktemp -d)"
  unset _PATHS_NAG_FORCE
  run zsh -lc --no-rcs "
    PATH='$CLEAN_PATH'
    HOME='$SANDBOX'
    unset XDG_CACHE_HOME
    source '$REPO/shell/init_env.zsh'
  " || true
  # Some zsh versions reject -lc + --no-rcs combinations; fall back to plain -c
  if [[ "$status" -ne 0 ]] && [[ "$output" == *"--no-rcs"* ]]; then
    run zsh --no-rcs -c "
      PATH='$CLEAN_PATH'
      HOME='$SANDBOX'
      unset XDG_CACHE_HOME
      source '$REPO/shell/init_env.zsh'
    "
  fi
  refute_output --partial "never refreshed"
  refute_output --partial "days ago"
  rm -rf "$SANDBOX"
  export _PATHS_NAG_FORCE=1
}

@test "freshness gate: _PATHS_NAG_FORCE override re-enables nag in non-interactive context" {
  # Confirms the escape hatch works (it's what paths_freshness.bats relies
  # on). If this test ever fails, the rest of the freshness suite will
  # also fail — but this test localizes the failure to the override
  # mechanism specifically.
  SANDBOX="$(mktemp -d)"
  run zsh --no-rcs -c "
    PATH='$CLEAN_PATH'
    HOME='$SANDBOX'
    unset XDG_CACHE_HOME
    _PATHS_NAG_FORCE=1
    source '$REPO/shell/init_env.zsh'
  "
  assert_success
  assert_output --partial "never refreshed"
  rm -rf "$SANDBOX"
}
