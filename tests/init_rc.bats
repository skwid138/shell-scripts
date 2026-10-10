#!/usr/bin/env bats
# Tests for shell/init_rc.zsh — the interactive-shell barrel sourced from
# ~/.zshrc on every interactive shell (login or not).
#
# Contract under test (zsh_init_plan.md §3):
#   - Sources rc/* sub-files.
#   - Completion-system guard: `_COMPINIT_DONE=1` means "completion system
#     ready" and is set ONLY when that is true.
#     * If completion is already initialized (compdef defined — e.g. zplug
#       ran compinit against $ZPLUG_HOME/zcompdump), the barrel does NOT
#       call compinit again and writes no second dump file.
#     * Otherwise (zplug absent or its compinit failed) the barrel falls
#       back to its own compinit on ${ZDOTDIR:-$HOME}/.zcompdump: full
#       (audited) when the dump is missing or >=24h old, `-C` when fresh.
#       If that compinit fails or leaves compdef undefined, _COMPINIT_DONE
#       stays unset so a later source can retry.
#     * With `_COMPINIT_DONE` already set, compinit is never called.
#   - Sources lib/auto_nvm.zsh (idempotent re-source, no duplicate hook).
#
# Tests that need exact compinit call counts point SCRIPTS_DIR at an empty
# dir so no rc sub-file (in particular zplug, which calls compinit itself)
# runs; only the barrel's own guard block executes.
#
# HOME, ZDOTDIR and ZPLUG_HOME are exported as per-test temp dirs in setup(),
# so no test (including the full-barrel ones) reads or writes the real
# ~/.zcompdump, ~/.zplug, ~/.nvm, ~/miniconda3 or the private
# ~/code/wpromote layer — all of those are $HOME-relative in production.

setup() {
  load 'test_helper/bats-support/load'
  load 'test_helper/bats-assert/load'
  REPO="$(cd "$BATS_TEST_DIRNAME/.." && pwd -P)"
  # Per-test ZPLUG_HOME isolation. See init_compat.bats setup() for the full
  # rationale: `zplug load` writes to $ZPLUG_HOME/log/load_success.log, and
  # parallel bats workers contending on the shared default (~/.zplug) leak
  # log-write errors to stderr. Per-test dirs eliminate the race. zplug
  # honors a pre-set $ZPLUG_HOME, so behavior outside tests is unchanged.
  export ZPLUG_HOME="$BATS_TEST_TMPDIR/.zplug"
  mkdir -p "$ZPLUG_HOME/log"
  # Sandbox HOME for every zsh this file spawns (see header).
  ISO_HOME="$BATS_TEST_TMPDIR/home"
  mkdir -p "$ISO_HOME"
  export HOME="$ISO_HOME"
  # Keep compinit's default dump (${ZDOTDIR:-$HOME}/.zcompdump) in a temp dir.
  export ZDOTDIR="$BATS_TEST_TMPDIR/zdot"
  mkdir -p "$ZDOTDIR"
  # Isolated-barrel fixtures (see header).
  EMPTY_SCRIPTS_DIR="$BATS_TEST_TMPDIR/empty-scripts"
  mkdir -p "$EMPTY_SCRIPTS_DIR"
  COMPINIT_LOG="$BATS_TEST_TMPDIR/compinit.log"
  : >"$COMPINIT_LOG"
}

# Source only init_rc.zsh's own logic (no rc sub-files, no zplug), with a
# logging compinit stub that models a successful compinit (defines compdef).
# $1 = zsh snippet run before sourcing (may redefine compinit).
run_isolated_rc_with_stub() {
  run zsh --no-rcs -c "
    SCRIPTS_DIR='$EMPTY_SCRIPTS_DIR'
    compinit() { print -r -- \"compinit\${*:+ \$*}\" >>'$COMPINIT_LOG'; compdef() { :; }; }
    $1
    source '$REPO/shell/init_rc.zsh'
    print -- \"done=\${_COMPINIT_DONE:-unset}\"
  "
}

# touch -t timestamp for N minutes ago (BSD date on macOS, GNU date on Linux CI).
stamp_minutes_ago() {
  date -v-"$1"M +%Y%m%d%H%M.%S 2>/dev/null || date -d "-$1 minutes" +%Y%m%d%H%M.%S
}

# --- completion-system guard -----------------------------------------------

@test "init_rc: sets _COMPINIT_DONE=1 after first source" {
  # compaudit stubbed: on a tty-less runner with group-writable fpath dirs
  # the real audit aborts compinit, and _COMPINIT_DONE (correctly) stays
  # unset. That's a harness artifact, not what this test is about.
  run zsh --no-rcs -c "
    compaudit() { return 0; }
    source '$REPO/shell/init_env.zsh' >/dev/null 2>&1
    source '$REPO/shell/init_rc.zsh' >/dev/null 2>&1
    print -- \"\$_COMPINIT_DONE\"
  "
  assert_success
  assert_output "1"
}

@test "init_rc: skips compinit when completion is already initialized (compdef defined)" {
  # Simulates zplug having already run compinit (which defines compdef).
  run_isolated_rc_with_stub 'compdef() { :; }'
  assert_success
  assert_output "done=1"
  run cat "$COMPINIT_LOG"
  assert_output ""
}

@test "init_rc: fallback runs full (audited) compinit when no dump exists" {
  # zplug absent / failed: compdef undefined, so the barrel must init.
  run_isolated_rc_with_stub ''
  assert_success
  assert_output "done=1"
  run cat "$COMPINIT_LOG"
  assert_output "compinit"
}

@test "init_rc: fallback runs fast 'compinit -C' when the dump is fresh" {
  touch "$ZDOTDIR/.zcompdump"
  run_isolated_rc_with_stub ''
  assert_success
  assert_output "done=1"
  run cat "$COMPINIT_LOG"
  assert_output "compinit -C"
}

@test "init_rc: fallback runs full (audited) compinit when the dump is >24h old" {
  touch -t 202001010000 "$ZDOTDIR/.zcompdump"
  run_isolated_rc_with_stub ''
  assert_success
  assert_output "done=1"
  run cat "$COMPINIT_LOG"
  assert_output "compinit"
}

@test "init_rc: fallback boundary — dump aged 24h30m gets full compinit" {
  # Guards against hour-granularity qualifiers: `mh+24` truncates to whole
  # hours and only matches at >=25h, so 24h30m would wrongly take `-C`.
  touch -t "$(stamp_minutes_ago 1470)" "$ZDOTDIR/.zcompdump"
  run_isolated_rc_with_stub ''
  assert_success
  assert_output "done=1"
  run cat "$COMPINIT_LOG"
  assert_output "compinit"
}

@test "init_rc: fallback boundary — dump aged 23h30m gets fast 'compinit -C'" {
  touch -t "$(stamp_minutes_ago 1410)" "$ZDOTDIR/.zcompdump"
  run_isolated_rc_with_stub ''
  assert_success
  assert_output "done=1"
  run cat "$COMPINIT_LOG"
  assert_output "compinit -C"
}

@test "init_rc: fallback dump check does not leak EXTENDED_GLOB into the shell" {
  run zsh --no-rcs -c "
    SCRIPTS_DIR='$EMPTY_SCRIPTS_DIR'
    compinit() { compdef() { :; }; }
    unsetopt extendedglob
    source '$REPO/shell/init_rc.zsh'
    [[ -o extendedglob ]] && print -- leaked || print -- clean
  "
  assert_success
  assert_output "clean"
}

@test "init_rc: leaves _COMPINIT_DONE unset when fallback compinit fails" {
  # Stub models a failed compinit: non-zero status, compdef never defined.
  run_isolated_rc_with_stub "compinit() { print -r -- compinit >>'$COMPINIT_LOG'; return 1; }"
  assert_success
  assert_output "done=unset"
  run cat "$COMPINIT_LOG"
  assert_output "compinit"
}

@test "init_rc: leaves _COMPINIT_DONE unset when compinit succeeds but compdef is missing" {
  run_isolated_rc_with_stub "compinit() { print -r -- compinit >>'$COMPINIT_LOG'; return 0; }"
  assert_success
  assert_output "done=unset"
}

@test "init_rc: leaves _COMPINIT_DONE unset when compinit fails even though compdef got defined" {
  # Isolates the return-status gate from the compdef gate: compdef exists
  # afterwards, so only compinit's non-zero status can keep the flag unset.
  run_isolated_rc_with_stub "compinit() { print -r -- compinit >>'$COMPINIT_LOG'; compdef() { :; }; return 1; }"
  assert_success
  assert_output "done=unset"
}

@test "init_rc: a later source retries compinit after a failed fallback" {
  run zsh --no-rcs -c "
    SCRIPTS_DIR='$EMPTY_SCRIPTS_DIR'
    compinit() { print -r -- \"fail\${*:+ \$*}\" >>'$COMPINIT_LOG'; return 1; }
    source '$REPO/shell/init_rc.zsh'
    print -- \"first=\${_COMPINIT_DONE:-unset}\"
    compinit() { print -r -- \"ok\${*:+ \$*}\" >>'$COMPINIT_LOG'; compdef() { :; }; }
    source '$REPO/shell/init_rc.zsh'
    print -- \"second=\${_COMPINIT_DONE:-unset}\"
  "
  assert_success
  assert_line "first=unset"
  assert_line "second=1"
  run cat "$COMPINIT_LOG"
  assert_line --index 0 "fail"
  assert_line --index 1 "ok"
}

@test "init_rc: never calls compinit when _COMPINIT_DONE is already set" {
  run_isolated_rc_with_stub '_COMPINIT_DONE=1'
  assert_success
  assert_output "done=1"
  run cat "$COMPINIT_LOG"
  assert_output ""
}

@test "init_rc: re-sourcing does not re-run compinit" {
  run zsh --no-rcs -c "
    SCRIPTS_DIR='$EMPTY_SCRIPTS_DIR'
    compinit() { print -r -- \"compinit\${*:+ \$*}\" >>'$COMPINIT_LOG'; compdef() { :; }; }
    source '$REPO/shell/init_rc.zsh'
    source '$REPO/shell/init_rc.zsh'
    print -- \"done=\${_COMPINIT_DONE:-unset}\"
  "
  assert_success
  assert_output "done=1"
  run cat "$COMPINIT_LOG"
  assert_output "compinit"
}

@test "init_rc: prior (zplug-style) compinit means the barrel writes no second dump" {
  # Real compinit, no stubs. A prior `compinit -C -d <dumpA>` mirrors what
  # zplug's init does; afterwards the barrel must not produce
  # ${ZDOTDIR}/.zcompdump.
  DUMP_A="$BATS_TEST_TMPDIR/zplug-zcompdump"
  run zsh --no-rcs -c "
    SCRIPTS_DIR='$EMPTY_SCRIPTS_DIR'
    autoload -Uz compinit
    compinit -C -d '$DUMP_A'
    source '$REPO/shell/init_rc.zsh'
    print -- \"done=\${_COMPINIT_DONE:-unset} compdef=\${+functions[compdef]}\"
  "
  assert_success
  assert_output "done=1 compdef=1"
  assert [ -f "$DUMP_A" ]
  assert [ ! -e "$ZDOTDIR/.zcompdump" ]
  assert [ ! -e "$ISO_HOME/.zcompdump" ]
}

@test "init_rc: without prior compinit the fallback initializes completion and writes its dump" {
  # Control for the previous test: proves the dump-absence assertion is
  # meaningful (the fallback path does write ${ZDOTDIR}/.zcompdump).
  # compaudit is stubbed so a tty-less CI runner with group-writable fpath
  # dirs can't abort compinit's audit; this test is about the dump, not the
  # audit.
  run zsh --no-rcs -c "
    SCRIPTS_DIR='$EMPTY_SCRIPTS_DIR'
    compaudit() { return 0; }
    source '$REPO/shell/init_rc.zsh'
    print -- \"done=\${_COMPINIT_DONE:-unset} compdef=\${+functions[compdef]}\"
  "
  assert_success
  assert_output "done=1 compdef=1"
  assert [ -f "$ZDOTDIR/.zcompdump" ]
}

@test "init_rc: with real zplug, only zplug's dump is written (no duplicate compinit)" {
  [[ -f /opt/homebrew/opt/zplug/init.zsh ]] || skip "zplug not installed"
  # zplug lives under the brew prefix, not $HOME; HOME/ZPLUG_HOME/ZDOTDIR
  # are still the per-test temp dirs from setup().
  run zsh --no-rcs -c "
    compaudit() { return 0; }
    XDG_CACHE_HOME='$ISO_HOME/.cache'
    source '$REPO/shell/init_env.zsh' >/dev/null 2>&1
    source '$REPO/shell/init_rc.zsh' >/dev/null 2>&1
    print -- \"done=\${_COMPINIT_DONE:-unset} compdef=\${+functions[compdef]}\"
  " </dev/null
  assert_success
  assert_output "done=1 compdef=1"
  assert [ -f "$ZPLUG_HOME/zcompdump" ]
  assert [ ! -e "$ZDOTDIR/.zcompdump" ]
}

# --- auto_nvm dual-source idempotency --------------------------------------

@test "init_rc: sourcing after init_profile does not duplicate chpwd hook" {
  # The dual-source contract: lib/auto_nvm.zsh is sourced from BOTH
  # init_profile (login) and init_rc (interactive). add-zsh-hook dedups
  # identical (hook,fn) pairs, so chpwd_functions should contain load_nvmrc
  # exactly once.
  run zsh --no-rcs -c "
    source '$REPO/shell/init_env.zsh' >/dev/null 2>&1
    source '$REPO/shell/init_profile.zsh' >/dev/null 2>&1
    source '$REPO/shell/init_rc.zsh' >/dev/null 2>&1
    # Print only the chpwd_functions array, one per line, then count load_nvmrc.
    print -l \"\${chpwd_functions[@]}\" | grep -c '^load_nvmrc\$'
  "
  assert_success
  assert_output "1"
}

# --- rc-tier sub-file loading -----------------------------------------------

@test "init_rc: defines brew() function (from rc/functions.zsh)" {
  run zsh --no-rcs -c "
    source '$REPO/shell/init_env.zsh' >/dev/null 2>&1
    source '$REPO/shell/init_rc.zsh' >/dev/null 2>&1
    typeset -f brew >/dev/null && print -- yes || print -- no
  "
  assert_success
  assert_output "yes"
}

@test "init_rc: defines aliases (from rc/aliases.zsh)" {
  # `v=nvim` is one of the more durable aliases in aliases.zsh; if any future
  # alias-set rename happens, this test will catch it and prompt updating.
  run zsh --no-rcs -c "
    source '$REPO/shell/init_env.zsh' >/dev/null 2>&1
    source '$REPO/shell/init_rc.zsh' >/dev/null 2>&1
    alias v 2>/dev/null
  "
  assert_success
  assert_output --partial "v="
}

@test "init_rc: returns success exit status" {
  run zsh --no-rcs -c "
    source '$REPO/shell/init_env.zsh' >/dev/null 2>&1
    source '$REPO/shell/init_rc.zsh' >/dev/null 2>&1
  "
  assert_success
}
