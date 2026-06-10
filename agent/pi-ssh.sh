#!/usr/bin/env bash
set -uo pipefail
source "$(cd "$(dirname "${BASH_SOURCE[0]}")" && pwd)/../lib/common.sh"

usage() {
  cat <<'EOF'
Usage: pi-ssh [wrapper-options] [--] [remote-command...]

Pi-only scoped SSH wrapper for opencode agents.

This is a convenience/scoping wrapper, not a safety tool. Once allow-listed in
opencode it permits unprompted arbitrary remote command execution on the Pi,
including remote sudo. It does not inspect or police the remote command.

Options consumed by this wrapper before the remote command begins:
  --port N, --port=N                  SSH port (default: PI_SSH_PORT or 22)
  --connect-timeout N, --connect-timeout=N
                                      SSH ConnectTimeout seconds (default: 10)
  -t, -T                              Pass tty control through to ssh
  --                                  End wrapper options; following tokens are
                                      the remote command verbatim
  -h, --help                          Show this help

Host resolution:
  Target defaults to PI_SSH_HOST or "pi". If no user@ is present, "hunter@" is
  prepended. Only these canonical short Pi identities are accepted:
    pi, hunter@pi,
    100.86.205.116, hunter@100.86.205.116,
    192.168.50.53, hunter@192.168.50.53

  FQDNs and near-matches are intentionally unsupported. There is no arbitrary
  host mode, no --host, and no --lan flag.

Parser contract:
  Wrapper flags are recognized only before the remote command begins. The first
  non-dash positional token begins the remote command; from that token onward,
  every token is passed verbatim to ssh, even if it looks like a wrapper flag.
  Use -- before a remote command that itself starts with a dash.

Connection behavior:
  The wrapper executes:
    ssh [tty opts] -o ConnectTimeout=N [-o BatchMode=yes] -p PORT TARGET [cmd...]

  BatchMode=yes is added only when a remote command is present. StrictHostKeyChecking
  is not overridden; a fresh machine needs a one-time interactive connect or
  ssh-keyscan setup so known_hosts already trusts the Pi key.

Contract exceptions:
  1. Exit status is ssh/remote passthrough after exec. ssh returns 255 for
     connection/auth failures; otherwise the remote command's exit code is
     returned. Remote exit codes 1, 2, 3, 4, and 5 are indistinguishable from
     this repo's normal wrapper error codes.
  2. stdout is transparent ssh/remote-command passthrough. This script does not
     emit the normal agent-script JSON envelope.
  3. Security posture is deliberately not read-only or safe-by-default: when
     allow-listed, arbitrary remote Pi execution including sudo is unprompted.
     opencode's local start-anchored "sudo *" deny rule does not catch remote
     sudo issued through this wrapper.

Examples:
  pi-ssh uptime
  pi-ssh journalctl -u unbound -n 50
  pi-ssh -t sudo systemctl edit unbound
  pi-ssh -- --remote-command-starting-with-dash
EOF
}

validate_port() {
  local value="$1"
  if ! [[ "$value" =~ ^[0-9]+$ ]]; then
    die_usage "port must be numeric and in range 1-65535: $value"
  fi
  if ((10#$value < 1 || 10#$value > 65535)); then
    die_usage "port must be numeric and in range 1-65535: $value"
  fi
}

validate_connect_timeout() {
  local value="$1"
  if ! [[ "$value" =~ ^[0-9]+$ ]]; then
    die_usage "connect timeout must be numeric: $value"
  fi
}

resolve_target() {
  local raw_target="$1"
  case "$raw_target" in
    pi | hunter@pi | 100.86.205.116 | hunter@100.86.205.116 | 192.168.50.53 | hunter@192.168.50.53) ;;
    *)
      return 2
      ;;
  esac

  if [[ "$raw_target" == *@* ]]; then
    printf '%s\n' "$raw_target"
  else
    printf 'hunter@%s\n' "$raw_target"
  fi
}

main() {
  local port="${PI_SSH_PORT:-22}"
  local connect_timeout="10"
  local raw_target="${PI_SSH_HOST:-pi}"
  local target
  local tty_opts=()
  local remote_cmd=()
  local ssh_argv=()

  while (($# > 0)); do
    case "$1" in
      -h | --help)
        usage
        return 0
        ;;
      --)
        shift
        remote_cmd=("$@")
        break
        ;;
      --port=*)
        port="${1#--port=}"
        shift
        ;;
      --port)
        (($# >= 2)) || die_usage "--port requires a value"
        port="$2"
        shift 2
        ;;
      --connect-timeout=*)
        connect_timeout="${1#--connect-timeout=}"
        shift
        ;;
      --connect-timeout)
        (($# >= 2)) || die_usage "--connect-timeout requires a value"
        connect_timeout="$2"
        shift 2
        ;;
      -t | -T)
        tty_opts+=("$1")
        shift
        ;;
      -*)
        die_usage "unknown wrapper option '$1'. If this is a remote command, use -- before it."
        ;;
      *)
        remote_cmd=("$@")
        break
        ;;
    esac
  done

  require_cmd "ssh"
  validate_port "$port"
  validate_connect_timeout "$connect_timeout"
  if ! target="$(resolve_target "$raw_target")"; then
    die_usage "PI_SSH_HOST must exactly match a canonical Pi short form (pi, hunter@pi, 100.86.205.116, hunter@100.86.205.116, 192.168.50.53, hunter@192.168.50.53); FQDNs and near-matches are unsupported."
  fi

  if ((${#tty_opts[@]} > 0)); then
    ssh_argv+=("${tty_opts[@]}")
  fi
  ssh_argv+=(-o "ConnectTimeout=$connect_timeout")
  if ((${#remote_cmd[@]} > 0)); then
    ssh_argv+=(-o "BatchMode=yes")
  fi
  ssh_argv+=(-p "$port" "$target")
  if ((${#remote_cmd[@]} > 0)); then
    ssh_argv+=("${remote_cmd[@]}")
  fi

  exec ssh "${ssh_argv[@]}"
}

main "$@"
