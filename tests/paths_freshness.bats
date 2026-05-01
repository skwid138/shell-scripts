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
