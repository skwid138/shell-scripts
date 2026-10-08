#!/usr/bin/env bats
# Tests for the fn+arrow reminder widgets in shell/rc/zsh_config.zsh.
#
# Contract under test (driven through a real interactive zsh via zsh/zpty;
# see tests/fixtures/zsh_reminder/driver.zsh):
#   - fn+left (\e[H) / fn+right (\e[F) move the cursor and show a tip.
#   - The tip clears on the NEXT keypress of any kind: a typed char,
#     backspace, or an arrow key — not just on self-insert.
#   - The reminder never redefines self-insert, so a user wrapper installed
#     later (zsh-autosuggestions / zsh-syntax-highlighting style) stays
#     bound and keeps running.
#   - The reminder's line-pre-redraw hook never blocks hooks registered
#     after it (add-zle-hook-widget stops the chain on a non-zero return),
#     on both the clearing path and the no-op path.

setup() {
  load 'test_helper/bats-support/load'
  load 'test_helper/bats-assert/load'
  REPO="$(cd "$BATS_TEST_DIRNAME/.." && pwd -P)"
  DRIVER="$BATS_TEST_DIRNAME/fixtures/zsh_reminder/driver.zsh"
  if ! zsh -f -c 'zmodload zsh/zpty' 2>/dev/null; then
    skip "zsh with the zsh/zpty module is required to drive an interactive shell"
  fi
}

# Run the driver against the real config with the given key sequence.
drive() {
  run zsh -f "$DRIVER" "$REPO/shell/rc/zsh_config.zsh" "$BATS_TEST_TMPDIR/zr" "$@"
}

# Expected transcript for one reminder key ($1 = driver key name,
# $2 = reminder widget, $3 = tip text). Sequence:
#   x            typed char, nothing pending      (hook no-op path)
#   REM, x       tip shown, then cleared by a typed char
#   REM, bs      tip shown, then cleared by backspace
#   REM, left    tip shown, then cleared by an arrow key
#   x            nothing pending again            (hook no-op path)
# Every key must yield a record from the later stand-in hook, and
# self-insert must remain the stand-in wrapper throughout.
expected_transcript() {
  local key=$1 widget=$2 tip=$3
  local si='si=user:_zr_self_insert'
  cat <<EOF
@x
wrap
redraw lw=self-insert msg=[] $si
@$key
redraw lw=$widget msg=[$tip] $si
@x
wrap
redraw lw=self-insert msg=[] $si
@$key
redraw lw=$widget msg=[$tip] $si
@bs
redraw lw=backward-delete-char msg=[] $si
@$key
redraw lw=$widget msg=[$tip] $si
@left
redraw lw=backward-char msg=[] $si
@x
wrap
redraw lw=self-insert msg=[] $si
EOF
}

@test "zsh reminder: fn+left tip clears on next key without clobbering self-insert or later hooks" {
  drive x home x home bs home left x
  assert_success
  assert_output "$(expected_transcript home beginning_of_line_with_reminder \
    '▶ TIP: You can also use Ctrl+A to move to beginning of line')"
}

@test "zsh reminder: fn+right tip clears on next key without clobbering self-insert or later hooks" {
  drive x end x end bs end left x
  assert_success
  assert_output "$(expected_transcript end end_of_line_with_reminder \
    '▶ TIP: You can also use Ctrl+E to move to end of line')"
}
