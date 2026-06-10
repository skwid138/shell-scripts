#!/usr/bin/env bats
# CLI / argv-construction tests for agent/pi-ssh.sh.
# Stubs `ssh` so no network calls happen.

setup() {
  load 'test_helper/bats-support/load'
  load 'test_helper/bats-assert/load'
  SCRIPT="$BATS_TEST_DIRNAME/../agent/pi-ssh.sh"

  STUBDIR="$(mktemp -d)"
  export PATH="$STUBDIR:$PATH"
  export SSH_STUB_STATE="$BATS_TEST_TMPDIR/ssh-argv.txt"
  export SSH_STUB_EXIT=0
  write_ssh_stub
}

teardown() {
  [[ -d "$STUBDIR" ]] && rm -rf "$STUBDIR"
}

write_ssh_stub() {
  cat >"$STUBDIR/ssh" <<'EOF'
#!/usr/bin/env bash
: "${SSH_STUB_STATE:?}"
{
  printf '__ARGV__\n'
  for arg in "$@"; do
    printf '<%s>\n' "$arg"
  done
} >"$SSH_STUB_STATE"
exit "${SSH_STUB_EXIT:-0}"
EOF
  chmod +x "$STUBDIR/ssh"
}

recorded_argv() {
  printf '%s' "$(<"$SSH_STUB_STATE")"
}

assert_argv_has() {
  local needle="<$1>"
  local argv
  argv="$(recorded_argv)"
  if [[ "$argv" != *"$needle"* ]]; then
    printf 'expected argv to contain %s, got:\n%s\n' "$needle" "$argv" >&2
    return 1
  fi
}

assert_argv_not_has() {
  local needle="<$1>"
  local argv
  argv="$(recorded_argv)"
  if [[ "$argv" == *"$needle"* ]]; then
    printf 'expected argv not to contain %s, got:\n%s\n' "$needle" "$argv" >&2
    return 1
  fi
}

assert_argv_sequence() {
  local expected="$1"
  local argv
  argv="$(recorded_argv)"
  if [[ "$argv" != *"$expected"* ]]; then
    printf 'expected argv sequence:\n%s\n\ngot:\n%s\n' "$expected" "$argv" >&2
    return 1
  fi
}

@test "pi-ssh: ssh exit status is passed through" {
  export SSH_STUB_EXIT=7
  run "$SCRIPT" uptime
  assert_failure 7

  export SSH_STUB_EXIT=255
  run "$SCRIPT" uptime
  assert_failure 255
}

@test "pi-ssh: default target and port are hunter@pi and 22" {
  run "$SCRIPT" uptime
  assert_success
  assert_argv_has "-p"
  assert_argv_has "22"
  assert_argv_has "hunter@pi"
}

@test "pi-ssh: PI_SSH_HOST tailnet IP gets hunter user prepended" {
  run env PI_SSH_HOST=100.86.205.116 "$SCRIPT" uptime
  assert_success
  assert_argv_has "hunter@100.86.205.116"
}

@test "pi-ssh: empty PI_SSH_HOST falls back to pi" {
  run env PI_SSH_HOST= "$SCRIPT" uptime
  assert_success
  assert_argv_has "hunter@pi"
}

@test "pi-ssh: host validation rejects near-misses exactly" {
  local host
  for host in pi.evil.com 192.168.50.53.attacker notpi pi.tailnet.ts.net example.com; do
    run env PI_SSH_HOST="$host" "$SCRIPT" uptime
    assert_failure 2
    assert_output --partial "canonical Pi short form"
  done
}

@test "pi-ssh: host validation rejects whitespace and control-char injections" {
  local host
  for host in $'pi ' $'pi\tx' $'pi\nhunter@evil'; do
    run env PI_SSH_HOST="$host" "$SCRIPT" uptime
    assert_failure 2
    assert_output --partial "canonical Pi short form"
  done
}

@test "pi-ssh: host validation accepts all six Pi identity forms" {
  local identity expected
  for identity in pi hunter@pi 100.86.205.116 hunter@100.86.205.116 192.168.50.53 hunter@192.168.50.53; do
    run env PI_SSH_HOST="$identity" "$SCRIPT" uptime
    assert_success
    case "$identity" in
      hunter@*) expected="$identity" ;;
      *) expected="hunter@$identity" ;;
    esac
    assert_argv_has "$expected"
    assert_argv_not_has "hunter@$expected"
  done
}

@test "pi-ssh: port supports split flag, equals flag, env, and CLI precedence" {
  run "$SCRIPT" --port 2222 uptime
  assert_success
  assert_argv_sequence $'<-p>\n<2222>'

  run "$SCRIPT" --port=2222 uptime
  assert_success
  assert_argv_sequence $'<-p>\n<2222>'

  run env PI_SSH_PORT=2222 "$SCRIPT" uptime
  assert_success
  assert_argv_sequence $'<-p>\n<2222>'

  run env PI_SSH_PORT=2222 "$SCRIPT" --port 2022 uptime
  assert_success
  assert_argv_sequence $'<-p>\n<2022>'
}

@test "pi-ssh: invalid ports exit usage error" {
  run "$SCRIPT" --port abc uptime
  assert_failure 2
  assert_output --partial "port must be numeric"

  run "$SCRIPT" --port 70000 uptime
  assert_failure 2
  assert_output --partial "range 1-65535"
}

@test "pi-ssh: connect-timeout defaults to 10 and accepts split and equals flags" {
  run "$SCRIPT" uptime
  assert_success
  assert_argv_has "ConnectTimeout=10"

  run "$SCRIPT" --connect-timeout 30 uptime
  assert_success
  assert_argv_has "ConnectTimeout=30"
  assert_argv_not_has "ConnectTimeout=10"

  run "$SCRIPT" --connect-timeout=30 uptime
  assert_success
  assert_argv_has "ConnectTimeout=30"
  assert_argv_not_has "ConnectTimeout=10"
}

@test "pi-ssh: BatchMode is present only for remote commands" {
  run "$SCRIPT" uptime
  assert_success
  assert_argv_has "BatchMode=yes"

  run "$SCRIPT"
  assert_success
  assert_argv_not_has "BatchMode=yes"
}

@test "pi-ssh: remote command parser leaves docker -t verbatim" {
  run "$SCRIPT" docker run -t img
  assert_success
  assert_argv_sequence $'<docker>\n<run>\n<-t>\n<img>'
}

@test "pi-ssh: wrapper-like flags after remote command stay remote" {
  run "$SCRIPT" foo --port 5
  assert_success
  assert_argv_sequence $'<-p>\n<22>'
  assert_argv_has "hunter@pi"
  assert_argv_sequence $'<foo>\n<--port>\n<5>'
}

@test "pi-ssh: bare flag-bearing journalctl remote command works" {
  run "$SCRIPT" journalctl -u unbound -n 50
  assert_success
  assert_argv_sequence $'<journalctl>\n<-u>\n<unbound>\n<-n>\n<50>'
}

@test "pi-ssh: double-dash separates wrapper options from remote command" {
  run "$SCRIPT" -- ls
  assert_success
  assert_argv_sequence $'<hunter@pi>\n<ls>'
}

@test "pi-ssh: dash-starting remote tokens after double-dash stay verbatim" {
  run "$SCRIPT" -- -J attacker
  assert_success
  assert_argv_sequence $'<hunter@pi>\n<-J>\n<attacker>'

  run "$SCRIPT" -- -o ProxyCommand=evil
  assert_success
  assert_argv_sequence $'<hunter@pi>\n<-o>\n<ProxyCommand=evil>'
}

@test "pi-ssh: leading -t and -T pass through to ssh before remote command" {
  run "$SCRIPT" -t sudo systemctl edit x
  assert_success
  assert_argv_sequence $'<-t>\n<-o>\n<ConnectTimeout=10>'
  assert_argv_sequence $'<sudo>\n<systemctl>\n<edit>\n<x>'

  run "$SCRIPT" -T uptime
  assert_success
  assert_argv_sequence $'<-T>\n<-o>\n<ConnectTimeout=10>'
}

@test "pi-ssh: leading unknown wrapper flag exits 2 and hints to use separator" {
  run "$SCRIPT" -x
  assert_failure 2
  assert_output --partial "use --"
}

@test "pi-ssh: dangerous ssh and host-pivot wrapper flags stay rejected" {
  # These surfaces were deliberately removed or never added to close local-RCE
  # and host-pivot vectors (ProxyCommand, ProxyJump, and -F config). Keep them
  # rejected if someone later adds a parser arm for -o or --ssh-arg.
  local flag
  for flag in -o --ssh-arg -J -F --host --lan; do
    run "$SCRIPT" "$flag" ProxyCommand=evil
    assert_failure 2
    assert_output --partial "use --"
  done
}

@test "pi-ssh: missing ssh dependency exits 3" {
  local isolated_path
  isolated_path="$BATS_TEST_TMPDIR/no-ssh-path"
  mkdir -p "$isolated_path"
  ln -s /usr/bin/dirname "$isolated_path/dirname"

  run env PATH="$isolated_path" /bin/bash "$SCRIPT" uptime
  assert_failure 3
  assert_output --partial "Missing dependency:"
}

@test "pi-ssh: interactive empty remote command path works under macOS bash 3.2" {
  run /bin/bash "$SCRIPT"
  assert_success
  assert_argv_has "hunter@pi"
  assert_argv_not_has "BatchMode=yes"
}

@test "pi-ssh: --help documents exceptions and Pi-only non-goals" {
  run "$SCRIPT" --help
  assert_success
  assert_output --partial "Exit status is ssh/remote passthrough"
  assert_output --partial "Remote exit codes 1, 2, 3, 4, and 5"
  assert_output --partial "emit the normal agent-script JSON envelope"
  assert_output --partial "arbitrary remote Pi execution including sudo is unprompted"
  assert_output --partial "does not override trusted local ~/.ssh/config"
  assert_output --partial "There is no arbitrary"
  assert_output --partial "FQDNs and near-matches are intentionally unsupported"
}
