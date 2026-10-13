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
# shellcheck source=../lib/gitleaks-private.sh
source "$SCRIPT_DIR/../lib/gitleaks-private.sh"

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
              With a private store for the repo (below), its validated files
              are added: --config <gitleaks.toml> and/or
              --gitleaks-ignore-path <gitleaksignore>.
  --status    Show the hook registration (with config origin), the gitleaks
              version, and the git binary/version in use.
  -h, --help  Show this help.

Exit codes (--run):
  0   no findings, or gitleaks is not installed (warns on stderr)
  1   findings (gitleaks rc 10; commit blocked with guidance), a gitleaks
      scan error (any other rc; reported as "not a finding"), or a private
      suppression store that fails validation (also "not a finding")
  2   usage error

Private suppressions (this machine only; never committed to the repo):
  ~/.config/gitleaks-audit/repos/<rel>/gitleaks.toml   -> --config
  ~/.config/gitleaks-audit/repos/<rel>/gitleaksignore  -> --gitleaks-ignore-path
  <rel> is the repo's path under ~/code (a linked worktree uses its main
  repo's; a submodule has its own; repos outside ~/code have none). Shared
  with gitleaks-audit.sh. Before use, every path from $HOME down to each file
  must be a real (non-symlink) directory/file owned by you, not group/other
  writable, with no ACL entry letting anyone else write; gitleaks.toml must
  be `[extend] useDefault = true` plus [[allowlists]] blocks that each target
  one rule with condition "AND", anchored paths, and anchored line regexes
  (a strict RE2 subset: no wildcards, no quantified anchors, no \Q..\E);
  gitleaksignore may hold only full-SHA history fingerprints. A repo with its
  own .gitleaks.toml cannot also have a private gitleaks.toml. Anything else
  blocks the commit. The store is validated again after gitleaks returns: a
  store that stopped validating, or whose file set or file content changed
  during the scan, blocks too (a transient edit that is undone within the scan window cannot
  be seen; the threat model is accidents, not same-user tampering). Off
  macOS (no BSD stat / ACLs) an existing store blocks with a "require macOS"
  error. The repo's own .gitleaksignore and inline `gitleaks:allow` comments
  stay trusted.

Opt out for one repository:
  git config hook.gitleaks.enabled false

Environment:
  GITLEAKS_HOOK_FALLBACK_PATH  dirs appended to PATH when looking for
                               gitleaks (default /opt/homebrew/bin:/usr/local/bin,
                               for GUI git clients with a minimal PATH;
                               set empty to disable)
  GITLEAKS_SUPPRESS_DIR        tests only: the private store base dir instead
                               of ~/.config/gitleaks-audit (not a security
                               boundary)
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

# Private store flags for this run (validated files only).
PRIV_ARGS=()

finding_guidance() {
  local details="gitleaks git --pre-commit --staged --redact=100 --verbose" a
  for a in ${PRIV_ARGS[@]+"${PRIV_ARGS[@]}"}; do
    details="$details $(printf '%q' "$a")"
  done
  details="$details ."
  cat >&2 <<'EOF'

gitleaks: potential secret(s) in the changes being committed. Commit blocked.

  1. If this is a real secret: rotate/revoke it FIRST (treat it as exposed),
     then remove it from the staged changes and re-stage.
  2. Only for a verified false positive: mark the line with an inline
     `gitleaks:allow` comment, or add the finding's fingerprint to
     .gitleaksignore at the repo root.
EOF
  printf '  3. Details (secrets redacted):\n       %s\n' "$details" >&2
  if [[ ${#PRIV_ARGS[@]} -gt 0 ]]; then
    printf '     (includes this repo'"'"'s private suppressions under %s)\n' "$GLP_STORE" >&2
  fi
  cat >&2 <<'EOF'
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
  # Private store: validated before use; any problem blocks (fail closed).
  if ! glp_lookup "$top" "$top"; then
    printf 'gitleaks hook: private suppression store error (not a finding): %s\n' "$GLP_ERR" >&2
    printf 'Commit blocked: fix the private store under %s (see gitleaks-hook.sh --help) and retry.\n' "$GLP_BASE" >&2
    return 1
  fi
  [[ -n "$GLP_TOML" ]] && PRIV_ARGS+=(--config "$GLP_TOML")
  [[ -n "$GLP_IGNORE" ]] && PRIV_ARGS+=(--gitleaks-ignore-path "$GLP_IGNORE")
  local used_digest=""
  if [[ ${#PRIV_ARGS[@]} -gt 0 ]] && ! used_digest="$(glp_files_digest)"; then
    printf 'gitleaks hook: private suppression store error (not a finding): could not hash the private files before the scan\n' >&2
    return 1
  fi
  # GIT_INDEX_FILE is deliberately NOT unset: git points it at the index it
  # is committing (temp index for `commit <paths>`, index.lock for `-a`).
  (
    cd "$top" || exit 1
    unset GITLEAKS_CONFIG GITLEAKS_CONFIG_TOML
    exec gitleaks git --pre-commit --staged --redact=100 --no-banner --exit-code=10 \
      ${PRIV_ARGS[@]+"${PRIV_ARGS[@]}"} .
  )
  rc=$?
  # Re-validate after the scan: a store that stopped validating, or whose
  # file set changed, while gitleaks was reading it blocks the commit.
  local used_toml="$GLP_TOML" used_ignore="$GLP_IGNORE"
  if ! glp_lookup "$top" "$top"; then
    printf 'gitleaks hook: private suppression store error (not a finding): the store changed during the scan and no longer validates: %s\n' "$GLP_ERR" >&2
    printf 'Commit blocked: fix the private store under %s and retry.\n' "$GLP_BASE" >&2
    return 1
  fi
  if [[ "$GLP_TOML" != "$used_toml" || "$GLP_IGNORE" != "$used_ignore" ]]; then
    printf 'gitleaks hook: private suppression store error (not a finding): the store changed during the scan (private files added or removed); retry the commit\n' >&2
    return 1
  fi
  if [[ ${#PRIV_ARGS[@]} -gt 0 ]]; then
    local now_digest
    if ! now_digest="$(glp_files_digest)"; then
      printf 'gitleaks hook: private suppression store error (not a finding): could not hash the private files after the scan\n' >&2
      return 1
    fi
    if [[ "$now_digest" != "$used_digest" ]]; then
      printf 'gitleaks hook: private suppression store error (not a finding): the store changed during the scan (private file content differs); retry the commit\n' >&2
      return 1
    fi
  fi
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
  private_status
  return 0
}

# private_status: the private store state for the repo in the cwd.
private_status() {
  local top files=""
  top="$(git rev-parse --show-toplevel 2>/dev/null)"
  if [[ -z "$top" ]]; then
    echo "private suppressions: n/a (not inside a git work tree)"
    return 0
  fi
  if ! glp_lookup "$top" "$top"; then
    echo "private suppressions: ERROR: $GLP_ERR (commits are blocked until fixed)"
    return 0
  fi
  if [[ -z "$GLP_REL" ]]; then
    echo "private suppressions: none (no store at $GLP_REPOS, or the repo is outside ~/code)"
    return 0
  fi
  [[ -n "$GLP_TOML" ]] && files="gitleaks.toml"
  [[ -n "$GLP_IGNORE" ]] && files="${files:+$files, }gitleaksignore"
  echo "private suppressions: $GLP_REL: ${files:-none} ($GLP_REPOS/$GLP_REL)"
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
