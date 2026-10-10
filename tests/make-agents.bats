#!/usr/bin/env bats
bats_require_minimum_version 1.5.0
# Tests for the launchd-agent Makefile targets: install-agents,
# uninstall-agents, agents-status. They loop over the explicit AGENTS list
# (cache-prune gitleaks-audit) and call $(AGENTS_DIR)/<agent>.sh with
# --install/--uninstall/--status. Every agent runs even if an earlier one
# fails; the target then exits nonzero and names the failures.
#
# AGENTS_DIR is pointed at stub scripts so no real launchctl is reached.

setup() {
  load 'test_helper/bats-support/load'
  load 'test_helper/bats-assert/load'
  REPO="$(cd "$BATS_TEST_DIRNAME/.." && pwd -P)"
  T="$BATS_TEST_TMPDIR"
  STUBS="$T/agents"
  CALLS="$T/calls.log"
  mkdir -p "$STUBS"
  : >"$CALLS"
  local a
  for a in cache-prune gitleaks-audit; do
    cat >"$STUBS/$a.sh" <<STUB
#!/bin/bash
printf '%s %s\n' "$a" "\$*" >>"$CALLS"
exit "\$(cat "$T/rc.$a" 2>/dev/null || echo 0)"
STUB
    chmod +x "$STUBS/$a.sh"
  done
}

run_make() { run --separate-stderr make --no-print-directory -C "$REPO" "$@" AGENTS_DIR="$STUBS"; }

@test "make install-agents: calls each agent's --install exactly once, in order" {
  run_make install-agents
  assert_success
  run cat "$CALLS"
  assert_output "$(printf '%s\n' 'cache-prune --install' 'gitleaks-audit --install')"
}

@test "make install-agents: a failing first agent still runs the second; exit nonzero names the failure" {
  echo 1 >"$T/rc.cache-prune"
  run_make install-agents
  assert_failure
  [[ "$stderr" == *"failed:"*"cache-prune"* ]]
  [[ "$stderr" != *"gitleaks-audit"* ]]
  run cat "$CALLS"
  assert_output "$(printf '%s\n' 'cache-prune --install' 'gitleaks-audit --install')"
}

@test "make install-agents: every failure is named" {
  echo 1 >"$T/rc.cache-prune"
  echo 3 >"$T/rc.gitleaks-audit"
  run_make install-agents
  assert_failure
  [[ "$stderr" == *"cache-prune"* && "$stderr" == *"gitleaks-audit"* ]]
}

@test "make uninstall-agents: dispatches --uninstall to each agent" {
  run_make uninstall-agents
  assert_success
  run cat "$CALLS"
  assert_output "$(printf '%s\n' 'cache-prune --uninstall' 'gitleaks-audit --uninstall')"
}

@test "make uninstall-agents: failures are aggregated too" {
  echo 1 >"$T/rc.gitleaks-audit"
  run_make uninstall-agents
  assert_failure
  [[ "$stderr" == *"gitleaks-audit"* ]]
  run grep -c . "$CALLS"
  assert_output "2"
}

@test "make agents-status: dispatches --status to each agent" {
  run_make agents-status
  assert_success
  run cat "$CALLS"
  assert_output "$(printf '%s\n' 'cache-prune --status' 'gitleaks-audit --status')"
}

@test "make agents: the real AGENTS_DIR scripts exist and support every dispatched flag" {
  local a
  for a in cache-prune gitleaks-audit; do
    [[ -x "$REPO/personal/$a.sh" ]]
    run "$REPO/personal/$a.sh" --help
    assert_success
    assert_output --partial -- "--install"
    assert_output --partial -- "--uninstall"
    assert_output --partial -- "--status"
  done
}

@test "make help: lists the agent targets" {
  run make --no-print-directory -C "$REPO" help
  assert_success
  assert_output --partial "install-agents"
  assert_output --partial "uninstall-agents"
  assert_output --partial "agents-status"
}
