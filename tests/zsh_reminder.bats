#!/usr/bin/env bats
# Tests for the fn+arrow reminder widgets in shell/rc/zsh_config.zsh.
#
# Contract under test (driven through a real interactive zsh via zsh/zpty;
# see tests/fixtures/zsh_reminder/driver.zsh):
#   - fn+left (\e[H) / fn+right (\e[F) move the cursor to the start / end
#     of the line (asserted via CURSOR/BUFFER) and show a tip.
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

# Every probe record ends with this: self-insert must remain the stand-in
# wrapper throughout (the reminder never redefines it).
SI='si=user:_zr_self_insert'

# fn+left: a, b; then home is cleared by a typed char (c lands at the start),
# by backspace, and by an arrow key. Plain keys with nothing pending (a, b, d,
# e) exercise the hook's no-op path. cur/buf prove beginning-of-line ran and
# that the wrapper's .self-insert inserted at the cursor.
expected_home_transcript() {
  local w=beginning_of_line_with_reminder
  local tip='▶ TIP: You can also use Ctrl+A to move to beginning of line'
  cat <<EOF
@a
wrap
redraw lw=self-insert cur=1 buf=[a] msg=[] $SI
@b
wrap
redraw lw=self-insert cur=2 buf=[ab] msg=[] $SI
@home
redraw lw=$w cur=0 buf=[ab] msg=[$tip] $SI
@c
wrap
redraw lw=self-insert cur=1 buf=[cab] msg=[] $SI
@home
redraw lw=$w cur=0 buf=[cab] msg=[$tip] $SI
@bs
redraw lw=backward-delete-char cur=0 buf=[cab] msg=[] $SI
@d
wrap
redraw lw=self-insert cur=1 buf=[dcab] msg=[] $SI
@home
redraw lw=$w cur=0 buf=[dcab] msg=[$tip] $SI
@left
redraw lw=backward-char cur=0 buf=[dcab] msg=[] $SI
@e
wrap
redraw lw=self-insert cur=1 buf=[edcab] msg=[] $SI
EOF
}

# fn+right: the cursor is moved off the end before every end key so
# end-of-line is observable; the tip is cleared by a typed char (c lands at
# the end), by backspace, and by an arrow key.
expected_end_transcript() {
  local w=end_of_line_with_reminder
  local tip='▶ TIP: You can also use Ctrl+E to move to end of line'
  cat <<EOF
@a
wrap
redraw lw=self-insert cur=1 buf=[a] msg=[] $SI
@b
wrap
redraw lw=self-insert cur=2 buf=[ab] msg=[] $SI
@left
redraw lw=backward-char cur=1 buf=[ab] msg=[] $SI
@left
redraw lw=backward-char cur=0 buf=[ab] msg=[] $SI
@end
redraw lw=$w cur=2 buf=[ab] msg=[$tip] $SI
@c
wrap
redraw lw=self-insert cur=3 buf=[abc] msg=[] $SI
@left
redraw lw=backward-char cur=2 buf=[abc] msg=[] $SI
@end
redraw lw=$w cur=3 buf=[abc] msg=[$tip] $SI
@bs
redraw lw=backward-delete-char cur=2 buf=[ab] msg=[] $SI
@left
redraw lw=backward-char cur=1 buf=[ab] msg=[] $SI
@end
redraw lw=$w cur=2 buf=[ab] msg=[$tip] $SI
@left
redraw lw=backward-char cur=1 buf=[ab] msg=[] $SI
@d
wrap
redraw lw=self-insert cur=2 buf=[adb] msg=[] $SI
EOF
}

@test "zsh reminder: fn+left moves to start, tip clears on next key without clobbering self-insert or later hooks" {
  drive a b home c home bs d home left e
  assert_success
  assert_output "$(expected_home_transcript)"
}

@test "zsh reminder: fn+right moves to end, tip clears on next key without clobbering self-insert or later hooks" {
  drive a b left left end c left end bs left end left d
  assert_success
  assert_output "$(expected_end_transcript)"
}
