#!/usr/bin/env bash
# require-real-gitleaks-tests.sh — CI gate: the real-gitleaks hook tests in
# tests/gitleaks-hook.bats must have RUN (TAP "ok", never "# skip") in this
# job. Without it, a runner that silently lost gitleaks (or git config hook
# support) would turn the tests into skips and the job would still be green.
#
# Usage: require-real-gitleaks-tests.sh <bats-tap-output-file>
#        require-real-gitleaks-tests.sh --list   (print the required names)
#
# Exit: 0 all required tests ok; 1 any missing, skipped, or failed; 2 usage
# or unreadable input.

set -uo pipefail

REQUIRED=(
  "gitleaks-hook (real gitleaks): staged secret is blocked; worktree-only secret is allowed"
  "gitleaks-hook (real gitleaks): 'git commit fileA' uses a temp index, so fileB's staged secret is not scanned or committed"
  "gitleaks-hook (real gitleaks): 'git commit -a' with a modified tracked file containing a secret is blocked"
  "gitleaks-hook (real gitleaks): --no-verify bypasses even a real staged secret"
)

if [[ "${1-}" == "--list" ]]; then
  printf '%s\n' "${REQUIRED[@]}"
  exit 0
fi
if [[ $# -ne 1 ]]; then
  echo "usage: $0 <bats-tap-output-file> | --list" >&2
  exit 2
fi
tap="$1"
if [[ ! -f "$tap" || ! -r "$tap" ]]; then
  echo "require-real-gitleaks-tests: cannot read TAP output $tap" >&2
  exit 2
fi

# status_of <name>: "ok", "skip", "notok", or "missing" from exact TAP lines
# "ok N <name>", "ok N <name> # skip ...", "not ok N <name>".
status_of() {
  REQ_NAME="$1" LC_ALL=C awk '
    BEGIN { want = ENVIRON["REQ_NAME"]; st = "missing" }
    {
      line = $0
      sub(/\r$/, "", line)
      notok = 0
      if (line ~ /^not ok [0-9]+ /) { notok = 1; sub(/^not ok [0-9]+ /, "", line) }
      else if (line ~ /^ok [0-9]+ /) sub(/^ok [0-9]+ /, "", line)
      else next
      if (notok && (line == want || index(line, want " # ") == 1)) { st = "notok"; exit }
      if (line == want) { if (st == "missing") st = "ok"; next }
      if (index(line, want " # skip") == 1 || index(line, want " # SKIP") == 1) { st = "skip"; exit }
    }
    END { print st }' "$tap"
}

fail=0
n_ok=0
for name in "${REQUIRED[@]}"; do
  case "$(status_of "$name")" in
    ok) n_ok=$((n_ok + 1)) ;;
    skip)
      echo "SKIPPED: $name"
      fail=1
      ;;
    notok)
      echo "FAILED: $name"
      fail=1
      ;;
    *)
      echo "MISSING: $name"
      fail=1
      ;;
  esac
done
echo "real-gitleaks hook tests ran: $n_ok/${#REQUIRED[@]}"
exit $fail
