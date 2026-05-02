#!/usr/bin/env bats
# Tests for shell/init_profile.zsh — the login-tier barrel.
#
# This file enforces the "minimal-tools" contract from zsh_init_plan.md
# (rev. 6) §3: the login-tier MUST NOT do anything interactive. Login-tier
# runs once per login shell (ssh, GUI Terminal first tab, `zsh -l`); if it
# leaks rc-tier behavior (completions, prompts, ZLE, plugins), those things
# stop being driven by the rc-tier barrel and shells become inconsistent.
#
# Complementary to init_profile.bats (which covers what login-tier DOES);
# this file covers what login-tier MUST NOT do.
#
# What rc-tier owns (and therefore login-tier MUST avoid):
#   - compinit / fpath manipulation for completions
#   - zplug, plugin loading
#   - prompt setup (PROMPT, RPROMPT, prompt_*)
#   - ZLE widgets (zle -N, bindkey)
#   - aliases (rc/aliases.zsh)
#   - functions (rc/functions.zsh) — except auto_nvm helpers which live in lib/
#   - cowsay/fortune/lolcat banner
#   - docker completions
#
# What login-tier owns (allowlisted):
#   - nvm load (login/nvm.zsh)
#   - conda init (login/conda.zsh)
#   - gcloud SDK init (login/gcloud.zsh)
#   - lib/auto_nvm.zsh chpwd hook + immediate load_nvmrc
#   - Wpromote login-tier passthrough

setup() {
  load 'test_helper/bats-support/load'
  load 'test_helper/bats-assert/load'
  REPO="$(cd "$BATS_TEST_DIRNAME/.." && pwd -P)"
}

@test "profile-minimal: does NOT run compinit (rc-tier responsibility)" {
  # If init_profile.zsh ever calls compinit, _COMPINIT_DONE will be set
  # (our central guard).
  #
  # We deliberately do NOT check `${#_comps[@]}` here: zsh auto-loads
  # completion FUNCTION DEFINITIONS from $fpath into _comps lazily on
  # any reference (it can register thousands of entries without
  # compinit ever running). _COMPINIT_DONE is the authoritative signal
  # that OUR central compinit ran.
  run zsh --no-rcs -c "
    unset _COMPINIT_DONE
    source '$REPO/shell/init_env.zsh' >/dev/null 2>&1
    source '$REPO/shell/init_profile.zsh' >/dev/null 2>&1
    print -- \"\${_COMPINIT_DONE:-unset}\"
  "
  assert_success
  assert_output "unset"
}

@test "profile-minimal: does NOT load zplug (rc-tier responsibility)" {
  run zsh --no-rcs -c "
    unset ZPLUG_HOME zplug_home ZPLUG_LOADFILE
    source '$REPO/shell/init_env.zsh' >/dev/null 2>&1
    source '$REPO/shell/init_profile.zsh' >/dev/null 2>&1
    print -- \"\${ZPLUG_HOME:+leaked}\${ZPLUG_LOADFILE:+leaked}\"
  "
  assert_success
  assert_output ""
}

@test "profile-minimal: does NOT define rc-tier aliases (e.g. ll, gst)" {
  # Sample a few aliases that rc/aliases.zsh defines. None should exist
  # after only env+profile have run.
  run zsh --no-rcs -c "
    source '$REPO/shell/init_env.zsh' >/dev/null 2>&1
    source '$REPO/shell/init_profile.zsh' >/dev/null 2>&1
    alias ll 2>/dev/null && print -- 'll-leaked'
    alias gst 2>/dev/null && print -- 'gst-leaked'
    print -- done
  "
  assert_success
  refute_output --partial "leaked"
  assert_output --partial "done"
}

@test "profile-minimal: does NOT define brew() wrapper (rc-tier function)" {
  # The brew() auto-refresh wrapper lives in rc/functions.zsh and must
  # only exist in interactive shells. Non-interactive (cron, LaunchAgent,
  # Brewfile bundle) calls should hit the real /opt/homebrew/bin/brew,
  # not our wrapper that calls 'make refresh-paths'.
  run zsh --no-rcs -c "
    source '$REPO/shell/init_env.zsh' >/dev/null 2>&1
    source '$REPO/shell/init_profile.zsh' >/dev/null 2>&1
    typeset -f brew >/dev/null && print -- 'brew-fn-leaked' || print -- 'ok'
  "
  assert_success
  assert_output "ok"
}

@test "profile-minimal: does NOT print cowsay/fortune banner" {
  run zsh --no-rcs -c "
    source '$REPO/shell/init_env.zsh' >/dev/null 2>&1
    source '$REPO/shell/init_profile.zsh' 2>/dev/null
  "
  assert_success
  # The banner contains ASCII cow art with '\\   ^__^' as a stable marker.
  refute_output --partial "^__^"
}

@test "profile-minimal: does NOT modify PROMPT or RPROMPT" {
  # rc-tier owns prompts. After only env+profile, PROMPT should still be
  # zsh's default ('%m%# ') or empty/unmodified — definitely not the
  # spaceship/p10k themed prompt.
  run zsh --no-rcs -c "
    source '$REPO/shell/init_env.zsh' >/dev/null 2>&1
    source '$REPO/shell/init_profile.zsh' >/dev/null 2>&1
    print -- \"PROMPT_LEN=\${#PROMPT}\"
  "
  assert_success
  # Default zsh PROMPT is '%m%# ' (6 chars). Allow up to 32 chars to cover
  # minor distro-default tweaks. A themed prompt is hundreds of chars.
  reported_len="$(echo "$output" | grep -oE 'PROMPT_LEN=[0-9]+' | cut -d= -f2)"
  assert [ -n "$reported_len" ]
  assert [ "$reported_len" -le 32 ]
}

@test "profile-minimal: does NOT register ZLE widgets beyond the zsh baseline" {
  # zle -la lists registered widgets. Compare AFTER env+profile against
  # the zsh-only baseline. Note: zsh autoloads completion-helper widgets
  # (_complete_*, _correct_*, _history-complete-*, etc.) the moment
  # anything references the completion system or fpath — so a few extras
  # are normal even without compinit. rc-tier plugins (fzf,
  # syntax-highlighting, autosuggestions) typically add 50–200 widgets.
  baseline="$(zsh --no-rcs -c 'zle -la 2>/dev/null | wc -l' | tr -d ' ')"
  after="$(zsh --no-rcs -c "
    source '$REPO/shell/init_env.zsh' >/dev/null 2>&1
    source '$REPO/shell/init_profile.zsh' >/dev/null 2>&1
    zle -la 2>/dev/null | wc -l
  " | tr -d ' ')"
  assert [ -n "$baseline" ]
  assert [ -n "$after" ]
  delta=$((after - baseline))
  # Allow up to 30 — covers stock completion-helper autoload (observed
  # ~15 on this machine) plus headroom for distro variation. Anything
  # ≥ 30 indicates real plugin widget leakage from rc-tier.
  assert [ "$delta" -lt 30 ]
}

@test "profile-minimal: does NOT add docker.zsh's fpath entry (delta vs baseline)" {
  # rc/docker.zsh prepends $HOME/.docker/completions to fpath. We compare
  # the count of that entry in fpath BEFORE any sourcing vs AFTER
  # env+profile. If profile-tier accidentally sourced docker.zsh, the
  # count would increment by 1.
  #
  # Why a delta: $HOME/.docker/completions may already be in fpath at
  # zsh startup (Docker Desktop installs a launchd plist that pre-exports
  # FPATH). Asserting absolute count == 0 produces false positives on
  # any machine with Docker Desktop. Asserting "no change vs baseline"
  # cleanly tests that profile-tier didn't double-add it.
  baseline="$(zsh --no-rcs -c "
    print -- \"\$fpath\" | tr ' ' '\n' | grep -cFx \"\$HOME/.docker/completions\" || true
  " | tr -d ' ')"
  after="$(zsh --no-rcs -c "
    source '$REPO/shell/init_env.zsh' >/dev/null 2>&1
    source '$REPO/shell/init_profile.zsh' >/dev/null 2>&1
    print -- \"\$fpath\" | tr ' ' '\n' | grep -cFx \"\$HOME/.docker/completions\" || true
  " | tr -d ' ')"
  assert [ -n "$baseline" ]
  assert [ -n "$after" ]
  assert [ "$baseline" = "$after" ]
}

@test "profile-minimal: env+profile combined silence on stderr" {
  # End-to-end: env-tier + login-tier together produce zero stderr noise.
  # Sandbox a fresh sentinel so the freshness nag doesn't fire.
  #
  # Known-noise denylist: load_nvmrc fires on profile-tier source and
  # warns "command not found: nvm" when nvm isn't installed (CI runners
  # legitimately don't have it). Scrub that expected line before
  # asserting silence; meta-test below confirms the scrub doesn't
  # swallow other warnings. See init_compat.bats for the analogous
  # pattern.
  SANDBOX="$(mktemp -d)"
  mkdir -p "$SANDBOX/.cache/zsh"
  : >"$SANDBOX/.cache/zsh/paths-refreshed"
  run zsh --no-rcs -c "
    XDG_CACHE_HOME='$SANDBOX/.cache'
    source '$REPO/shell/init_env.zsh' 2>&1 >/dev/null
    source '$REPO/shell/init_profile.zsh' 2>&1 >/dev/null
  "
  assert_success
  scrubbed="$(printf '%s\n' "$output" |
    grep -Ev 'load_nvmrc:[0-9]+: command not found: nvm' ||
    true)"
  assert [ -z "$scrubbed" ]
  rm -rf "$SANDBOX"
}

@test "profile-minimal: silence-assertion denylist still catches genuine warnings" {
  # Meta-test mirroring init_compat.bats: confirm the scrub denylist
  # doesn't swallow real warnings.
  SANDBOX="$(mktemp -d)"
  mkdir -p "$SANDBOX/.cache/zsh"
  : >"$SANDBOX/.cache/zsh/paths-refreshed"
  run zsh --no-rcs -c "
    XDG_CACHE_HOME='$SANDBOX/.cache'
    source '$REPO/shell/init_env.zsh' 2>&1 >/dev/null
    source '$REPO/shell/init_profile.zsh' 2>&1 >/dev/null
    print -u2 -- 'GENUINE WARNING that must not be scrubbed'
  "
  scrubbed="$(printf '%s\n' "$output" |
    grep -Ev 'load_nvmrc:[0-9]+: command not found: nvm' ||
    true)"
  assert [ -n "$scrubbed" ]
  echo "$scrubbed" | grep -q 'GENUINE WARNING that must not be scrubbed'
  rm -rf "$SANDBOX"
}
