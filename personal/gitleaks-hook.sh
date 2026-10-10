#!/usr/bin/env bash
# gitleaks-hook.sh — global pre-commit secret scan, registered as a git
# config hook (hook.gitleaks.command / hook.gitleaks.event = pre-commit) in
# the dotfiles ~/.gitconfig. Config hooks run BEFORE the repo's own
# .git/hooks/pre-commit or core.hooksPath hook; both still run.
#
# The registered one-liner fails open ONLY when this script is missing; once
# it runs, its exit status is the hook's exit status.
#
# Bash 3.2-compatible; never uses `set -e`.

set -uo pipefail

SCRIPT_DIR="$(cd "$(dirname "${BASH_SOURCE[0]}")" && pwd)"
# shellcheck source=../lib/common.sh
source "$SCRIPT_DIR/../lib/common.sh"

usage() {
  cat <<'EOF'
Usage: gitleaks-hook --run | --status | --help

Global gitleaks pre-commit hook (registered in ~/.gitconfig as a git config
hook named "gitleaks").

Modes:
  --run       Scan exactly what is being committed:
                gitleaks git --pre-commit --staged --redact=100 \
                  --no-banner --exit-code=10 .
              from the repository top level. GIT_INDEX_FILE is inherited
              from git, so `git commit <paths>` and `git commit -a` are
              scanned against the index git is actually committing.
              GITLEAKS_CONFIG / GITLEAKS_CONFIG_TOML are unset for the scan
              so the effective config is the repo's .gitleaks.toml (or the
              gitleaks default), never an ambient environment override.
  --status    Show the hook registration (with config origin), the gitleaks
              version, and the git binary/version in use.
  -h, --help  Show this help.

Exit codes (--run):
  0   no findings, or gitleaks is not installed (warns on stderr)
  1   findings (gitleaks rc 10; commit blocked with guidance), or a gitleaks
      scan error (any other rc; reported as "not a finding")
  2   usage error

Opt out for one repository:
  git config hook.gitleaks.enabled false

Environment:
  GITLEAKS_HOOK_FALLBACK_PATH  dirs appended to PATH when looking for
                               gitleaks (default /opt/homebrew/bin:/usr/local/bin,
                               for GUI git clients with a minimal PATH;
                               set empty to disable)
EOF
}

MODE=""
while [[ $# -gt 0 ]]; do
  case "$1" in
    -h | --help)
      usage
      exit 0
      ;;
    --run | --status)
      [[ -z "$MODE" ]] || die_usage "only one of --run/--status may be given"
      MODE="${1#--}"
      shift
      ;;
    *) die_usage "unknown argument: $1 (see --help)" ;;
  esac
done
[[ -n "$MODE" ]] || die_usage "a mode is required: --run or --status (see --help)"

# Append (never prepend) the fallback dirs: the caller's PATH wins.
FALLBACK_PATH="${GITLEAKS_HOOK_FALLBACK_PATH-/opt/homebrew/bin:/usr/local/bin}"
if [[ -n "$FALLBACK_PATH" ]]; then
  PATH="${PATH:+$PATH:}$FALLBACK_PATH"
  export PATH
fi

finding_guidance() {
  cat >&2 <<'EOF'

gitleaks: potential secret(s) in the changes being committed. Commit blocked.

  1. If this is a real secret: rotate/revoke it FIRST (treat it as exposed),
     then remove it from the staged changes and re-stage.
  2. Only for a verified false positive: mark the line with an inline
     `gitleaks:allow` comment, or add the finding's fingerprint to
     .gitleaksignore at the repo root.
  3. Details (secrets redacted):
       gitleaks git --pre-commit --staged --redact=100 --verbose .
  4. `git commit --no-verify` skips this check AND every other pre-commit /
     commit-msg hook in this repo (lint, format, tests).
  5. To disable this hook for this repository only:
       git config hook.gitleaks.enabled false
EOF
}

do_run() {
  local top rc
  if ! command -v gitleaks >/dev/null 2>&1; then
    warn "gitleaks hook: gitleaks not found on PATH; secret scan skipped (brew install gitleaks)"
    return 0
  fi
  top="$(git rev-parse --show-toplevel 2>/dev/null)"
  if [[ -z "$top" ]]; then
    printf 'gitleaks hook: not inside a git work tree; refusing to pass unscanned\n' >&2
    return 1
  fi
  # GIT_INDEX_FILE is deliberately NOT unset: git points it at the index it
  # is committing (temp index for `commit <paths>`, index.lock for `-a`).
  (
    cd "$top" || exit 1
    unset GITLEAKS_CONFIG GITLEAKS_CONFIG_TOML
    exec gitleaks git --pre-commit --staged --redact=100 --no-banner --exit-code=10 .
  )
  rc=$?
  case "$rc" in
    0) return 0 ;;
    10)
      finding_guidance
      return 1
      ;;
    *)
      printf 'gitleaks scan error (not a finding), rc=%s\n' "$rc" >&2
      printf 'Commit blocked because the staged changes could not be scanned.\n' >&2
      return 1
      ;;
  esac
}

do_status() {
  local gl gv gitp
  echo "hook registration (git config --show-origin --get-regexp '^hook\\.gitleaks'):"
  if ! git config --show-origin --get-regexp '^hook\.gitleaks' 2>/dev/null | sed 's/^/  /'; then
    echo "  (none)"
  fi
  if gl="$(command -v gitleaks 2>/dev/null)"; then
    gv="$(gitleaks version 2>/dev/null || echo unknown)"
    echo "gitleaks: $gl ($gv)"
  else
    echo "gitleaks: not found on PATH (the hook warns and allows commits)"
  fi
  gitp="$(command -v git 2>/dev/null || echo 'not found')"
  echo "git: $gitp ($(git --version 2>/dev/null || echo unknown))"
  return 0
}

case "$MODE" in
  run)
    do_run
    exit $?
    ;;
  status)
    do_status
    exit $?
    ;;
esac
