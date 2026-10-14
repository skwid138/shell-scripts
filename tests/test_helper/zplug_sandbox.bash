# shellcheck shell=bash
# zplug_sandbox: shared setup for every suite that sources the RC tier (and
# with it rc/zsh_plugins.zsh, i.e. zplug). Load it from setup() with
# `load 'test_helper/zplug_sandbox'` and call `zplug_sandbox`.
#
# A developer shell that loaded zplug exports ZPLUG_BIN, ZPLUG_REPOS,
# ZPLUG_LOADFILE, ZPLUG_CACHE_DIR, ZPLUG_ERROR_LOG, ZPLUG_ROOT, ... (and
# older zplug versions ZPLUG_SHALLOW/ZPLUG_CACHE_FILE/ZPLUG_CLONE_DEPTH), all
# pointing at the real ~/.zplug, and zplug keeps any value that is already
# set. Exporting only ZPLUG_HOME would leave those inherited paths shared by
# every test (and every parallel bats worker). So: unset every inherited
# ZPLUG_* and _ZPLUG_* variable, then export ZPLUG_HOME under
# BATS_TEST_TMPDIR, so every zplug path derives from the per-test sandbox.
zplug_sandbox() {
  local v
  for v in $(compgen -v ZPLUG_) $(compgen -v _ZPLUG_); do
    unset "$v"
  done
  export ZPLUG_HOME="$BATS_TEST_TMPDIR/.zplug"
  mkdir -p "$ZPLUG_HOME/log"
}

# assert_setup_sandboxes_zplug <zsh source snippet>: regression check for a
# suite's ACTUAL setup(). Points every zplug path override at sentinel dirs
# and files outside the sandbox, exports them, re-runs the suite's setup(),
# then sources the snippet in zsh and prints the zplug paths zplug resolved
# there. When zplug is installed (the init.zsh that rc/zsh_plugins.zsh
# sources exists), zplug must have initialized (its `zplug` function is
# defined) and every path must be set and under the per-test sandbox; when
# it is absent, zplug must not have loaded and only ZPLUG_HOME (exported by
# the setup) may be set. Every sentinel must be byte-unchanged.
# shellcheck disable=SC2154 # status/output are set by bats' run
assert_setup_sandboxes_zplug() {
  local snippet="$1" out="$BATS_TEST_TMPDIR/outside-zplug" n before after line init installed=0
  init="$(sed -n 's/^[[:space:]]*source "\(.*zplug\/init\.zsh\)".*/\1/p' "$REPO/shell/rc/zsh_plugins.zsh" | head -n 1)"
  [[ -n "$init" && -f "$init" ]] && installed=1
  mkdir -p "$out"
  for n in home bin repos cache root; do
    mkdir -p "$out/$n"
    printf 'sentinel %s\n' "$n" >"$out/$n/sentinel"
  done
  for n in loadfile error_log cache_file; do
    printf 'sentinel %s\n' "$n" >"$out/$n"
  done
  before="$(cd "$out" && find . -print | LC_ALL=C sort && find . -type f -exec cksum {} + | LC_ALL=C sort)"
  export ZPLUG_HOME="$out/home" ZPLUG_BIN="$out/bin" ZPLUG_REPOS="$out/repos" \
    ZPLUG_LOADFILE="$out/loadfile" ZPLUG_CACHE_DIR="$out/cache" ZPLUG_ERROR_LOG="$out/error_log" \
    ZPLUG_ROOT="$out/root" ZPLUG_CACHE_FILE="$out/cache_file" ZPLUG_SHALLOW=true ZPLUG_CLONE_DEPTH=1
  setup
  run zsh --no-rcs -c "
    $snippet
    for v in ZPLUG_HOME ZPLUG_BIN ZPLUG_REPOS ZPLUG_LOADFILE ZPLUG_CACHE_DIR ZPLUG_ERROR_LOG; do
      print -r -- \"\$v=\${(P)v}\"
    done
    print -r -- \"ZPLUG_FN=\$+functions[zplug]\"
    print -r -- \"ROOT=\${ZPLUG_ROOT-}\"
    print -r -- \"LEGACY=\${ZPLUG_CACHE_FILE-}\${ZPLUG_SHALLOW-}\${ZPLUG_CLONE_DEPTH-}\""
  [[ "$status" -eq 0 ]] || {
    echo "zsh exited $status: $output" >&2
    return 1
  }
  for n in ZPLUG_HOME ZPLUG_BIN ZPLUG_REPOS ZPLUG_LOADFILE ZPLUG_CACHE_DIR ZPLUG_ERROR_LOG; do
    line="$(printf '%s\n' "$output" | grep "^$n=")" || {
      echo "no $n line in: $output" >&2
      return 1
    }
    line="${line#*=}"
    if [[ $installed -eq 1 || $n == ZPLUG_HOME ]]; then
      [[ "$line" == "$BATS_TEST_TMPDIR/.zplug" || "$line" == "$BATS_TEST_TMPDIR/.zplug/"* ]] || {
        echo "$n is not set inside the sandbox: '$line'" >&2
        return 1
      }
    else
      [[ -z "$line" ]] || {
        echo "zplug is not installed, yet $n is set: '$line'" >&2
        return 1
      }
    fi
  done
  if [[ $installed -eq 1 ]]; then
    printf '%s\n' "$output" | grep -qx "ZPLUG_FN=1" || {
      echo "zplug ($init) is installed but did not initialize: $output" >&2
      return 1
    }
  else
    printf '%s\n' "$output" | grep -qx "ZPLUG_FN=0" || {
      echo "zplug is not installed, yet a zplug function is defined: $output" >&2
      return 1
    }
  fi
  [[ "$output" != *"$out"* ]] || {
    echo "an outside override leaked into zsh: $output" >&2
    return 1
  }
  after="$(cd "$out" && find . -print | LC_ALL=C sort && find . -type f -exec cksum {} + | LC_ALL=C sort)"
  [[ "$after" == "$before" ]] || {
    echo "sentinels changed" >&2
    return 1
  }
}
