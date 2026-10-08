#!/usr/bin/env bats
# Tests for shell/rc/zsh_config.zsh — RC-tier zle/keymap configuration.
#
# Contract under test:
#   - The `main` keymap is emacs, even when zsh started in vi mode. zsh
#     auto-selects viins when $EDITOR/$VISUAL contain "vi" (we export
#     EDITOR=vim), which makes Ctrl+A/Ctrl+E insert literal ^A/^E.
#   - The custom reminder/word-nav bindings land in the emacs keymap (i.e.
#     `bindkey -e` runs BEFORE the custom bindkey calls, not after).

setup() {
  load 'test_helper/bats-support/load'
  load 'test_helper/bats-assert/load'
  REPO="$(cd "$BATS_TEST_DIRNAME/.." && pwd -P)"
}

@test "zsh_config: selects emacs keymap and keeps custom bindings when started in vi mode" {
  # Start explicitly in viins (rather than relying on $EDITOR timing) to
  # reproduce the interactive-shell condition deterministically.
  run zsh -f -c "
    bindkey -v
    source '$REPO/shell/rc/zsh_config.zsh'
    bindkey -lL main
    bindkey '^A'
    bindkey '^E'
    bindkey '^[[H'
    bindkey '^[[F'
    bindkey '^[[102;6u'
    bindkey '^[[98;6u'
  "
  assert_success
  assert_line 'bindkey -A emacs main'
  assert_line '"^A" beginning-of-line'
  assert_line '"^E" end-of-line'
  assert_line '"^[[H" beginning_of_line_with_reminder'
  assert_line '"^[[F" end_of_line_with_reminder'
  assert_line '"^[[102;6u" forward-word'
  assert_line '"^[[98;6u" backward-word'
}
