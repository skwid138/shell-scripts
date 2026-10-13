#!/usr/bin/env bats
bats_require_minimum_version 1.5.0
# Tests for lib/gitleaks-private.sh: the private, per-repo gitleaks
# suppression store shared by personal/gitleaks-hook.sh and
# personal/gitleaks-audit.sh (repo identity, store validation, and the
# whitelist grammars of the private gitleaks.toml / gitleaksignore files).
#
# Every library call runs under `env -i` with a temp HOME (containing spaces)
# and /bin/bash (3.2 on macOS), with either a system-only PATH or a GNU-first
# PATH (coreutils/gawk/gnu-sed/grep gnubin dirs ahead of the system dirs).
#
# macOS-only (BSD stat, ls -le ACLs, chmod +a). Skipped elsewhere.

setup() {
  load 'test_helper/bats-support/load'
  load 'test_helper/bats-assert/load'

  [[ "$(uname -s)" == "Darwin" ]] || skip "gitleaks-private is macOS-only (BSD stat, ACLs)"

  LIB="$BATS_TEST_DIRNAME/../lib/gitleaks-private.sh"
  T="$BATS_TEST_TMPDIR"
  FAKE_HOME="$T/home dir"
  CODE="$FAKE_HOME/code"
  BASE="$FAKE_HOME/.config/gitleaks-audit"
  REPOS="$BASE/repos"
  GITBIN="$T/gitbin"
  mkdir -p "$CODE" "$GITBIN" "$T/fixture-home"
  /bin/chmod 755 "$FAKE_HOME"
  # The real binary (type -P ignores the git() fixture wrapper below).
  REAL_GIT="$(type -P git)"
  [[ "$REAL_GIT" == /* ]] || skip "no git binary on PATH"
  ln -s "$REAL_GIT" "$GITBIN/git"
  LPATH="$GITBIN:/usr/bin:/bin:/usr/sbin:/sbin"
  ME="$(id -un)"
}

teardown() {
  # Restore permissions/ACLs a failed assertion may have left behind.
  /bin/chmod -RN "$BATS_TEST_TMPDIR" 2>/dev/null
  /bin/chmod -R u+rwx "$BATS_TEST_TMPDIR" 2>/dev/null
  return 0
}

# use_gnu_path: PATH with GNU coreutils/gawk/gnu-sed/grep gnubin dirs ahead
# of the system dirs (Homebrew on Apple silicon or Intel). Skips, naming what
# is missing, unless GNU stat, awk, sed, and grep all resolve first.
use_gnu_path() {
  local dirs="" pkg d prefix found tool
  for pkg in coreutils gawk gnu-sed grep; do
    found=""
    for prefix in /opt/homebrew /usr/local; do
      d="$prefix/opt/$pkg/libexec/gnubin"
      if [[ -d "$d" ]]; then
        found="$d"
        break
      fi
    done
    [[ -n "$found" ]] || skip "GNU $pkg not installed (brew install coreutils gawk gnu-sed grep)"
    dirs="$dirs:$found"
  done
  LPATH="$GITBIN${dirs}:/usr/bin:/bin:/usr/sbin:/sbin"
  for tool in stat awk sed grep; do
    PATH="$LPATH" "$tool" --version 2>/dev/null | head -n1 | grep -q 'GNU' ||
      skip "GNU $tool does not resolve first on the GNU-first PATH"
  done
}

# lib <shell snippet>: source the library in a hermetic /bin/bash and eval.
lib() {
  run --separate-stderr env -i HOME="$FAKE_HOME" PATH="$LPATH" "${EXTRA_ENV[@]}" \
    /bin/bash -c 'set -uo pipefail; source "$1" || exit 99; eval "$2"' _ "$LIB" "$1"
}
EXTRA_ENV=(TERM=dumb)

# git: fixture git never sees the real HOME, global/system config, or the
# real global gitleaks config hook (commits also pass --no-verify).
git() {
  HOME="$T/fixture-home" GIT_CONFIG_GLOBAL=/dev/null GIT_CONFIG_NOSYSTEM=1 \
    GIT_AUTHOR_NAME=t GIT_AUTHOR_EMAIL=t@e GIT_COMMITTER_NAME=t GIT_COMMITTER_EMAIL=t@e \
    command git "$@"
}

mkrepo() { # <abs>
  mkdir -p "$1"
  git -C "$1" init -q -b main
  git -C "$1" commit -q --no-verify --allow-empty -m init
}

# store <rel> [toml-content] [ignore-content]: a valid private store entry.
store() {
  local d="$REPOS/$1"
  mkdir -p "$d"
  /bin/chmod 700 "$FAKE_HOME/.config" "$BASE" "$REPOS"
  local p="$d"
  while [[ "$p" != "$REPOS" ]]; do
    /bin/chmod 700 "$p"
    p="$(dirname "$p")"
  done
  if [[ -n "${2-}" ]]; then
    printf '%s\n' "$2" >"$d/gitleaks.toml"
    /bin/chmod 600 "$d/gitleaks.toml"
  fi
  if [[ -n "${3-}" ]]; then
    printf '%s\n' "$3" >"$d/gitleaksignore"
    /bin/chmod 600 "$d/gitleaksignore"
  fi
}

VALID_TOML="# private suppressions
[extend]
useDefault = true

[[allowlists]]
description = 'design tokens'
targetRules = ['generic-api-key']
condition = \"AND\"
paths = ['^tools/tokens/design\\.vars\\.json\$', '^src/a\\.json\$']
regexTarget = \"line\"
regexes = ['^\\n?[ \\t]*\"key\": \"[0-9a-f]{40}\",?\$']"

FP40="0123456789abcdef0123456789abcdef01234567"

toml_check() { # <content>
  printf '%s\n' "$1" >"$T/t.toml"
  lib 'glp_check_toml "$HOME/../t.toml"'
}

# --- gitleaks.toml grammar ----------------------------------------------------

@test "gitleaks-private: a well-formed private gitleaks.toml is accepted" {
  toml_check "$VALID_TOML"
  assert_success
  assert_output "OK"
}

@test "gitleaks-private: toml without [extend] useDefault = true is rejected (defaults must stay on)" {
  toml_check "$VALID_TOML"
  assert_output "OK"
  toml_check "$(printf '%s\n' "$VALID_TOML" | grep -v '^useDefault')"
  assert_failure
  refute_output "OK"
  toml_check "$(printf '%s\n' "$VALID_TOML" | sed 's/^useDefault = true$/useDefault = false/')"
  assert_failure
  toml_check "$(printf '%s\n' "$VALID_TOML" | grep -v -e '^useDefault' -e '^\[extend\]')"
  assert_failure
}

@test "gitleaks-private: an allowlist without targetRules (a global allowlist) is rejected" {
  toml_check "$(printf '%s\n' "$VALID_TOML" | grep -v '^targetRules')"
  assert_failure
  assert_output --partial "targetRules"
}

@test "gitleaks-private: unanchored path or line regexes are rejected" {
  local bad
  for bad in \
    "paths = ['tools/tokens/design\\.vars\\.json\$']" \
    "paths = ['^tools/tokens/design\\.vars\\.json']" \
    "paths = ['^a\\\$']" \
    "paths = ['^a\$|b']" \
    "paths = ['^a\$', 'b\$']" \
    "regexes = ['\"key\": \"[0-9a-f]{40}\"']" \
    "regexes = ['^\"key\"|.*\$']" \
    "regexes = ['^[a|]b\$|c']"; do
    toml_check "$(printf '%s\n' "$VALID_TOML" | grep -v "^${bad%% *} ")
$bad"
    if [[ "$status" -eq 0 ]]; then
      echo "accepted: $bad" >&3
      false
    fi
  done
  # Alternation inside a group and | inside a class are fine.
  toml_check "$(printf '%s\n' "$VALID_TOML" | grep -v '^paths ')
paths = ['^src/(a|b)\\.json\$', '^[|]x\$']"
  assert_success
}

@test "gitleaks-private: every other grammar violation class is rejected" {
  toml_check "$VALID_TOML"
  assert_output "OK"
  local -a cases=(
    "no-extend:$(printf '%s\n' "$VALID_TOML" | grep -v '^\[extend\]')"
    "extend-twice:$VALID_TOML
[extend]
useDefault = true"
    "allowlists-before-extend:[[allowlists]]
targetRules = ['x']
[extend]
useDefault = true"
    "missing-condition:$(printf '%s\n' "$VALID_TOML" | grep -v '^condition')"
    "condition-or:$(printf '%s\n' "$VALID_TOML" | sed 's/^condition = "AND"/condition = "OR"/')"
    "missing-paths:$(printf '%s\n' "$VALID_TOML" | grep -v '^paths')"
    "missing-regextarget:$(printf '%s\n' "$VALID_TOML" | grep -v '^regexTarget')"
    "regextarget-match:$(printf '%s\n' "$VALID_TOML" | sed 's/^regexTarget = "line"/regexTarget = "match"/')"
    "missing-regexes:$(printf '%s\n' "$VALID_TOML" | grep -v '^regexes')"
    "two-rules:$(printf '%s\n' "$VALID_TOML" | sed "s/^targetRules = .*/targetRules = ['generic-api-key', 'jwt']/")"
    "bad-rule-id:$(printf '%s\n' "$VALID_TOML" | sed "s/^targetRules = .*/targetRules = ['Generic_API']/")"
    "basic-string-path:$(printf '%s\n' "$VALID_TOML" | sed 's/^paths = .*/paths = ["^a$"]/')"
    "basic-string-description:$(printf '%s\n' "$VALID_TOML" | sed 's/^description = .*/description = "x"/')"
    "multiline-array:$(printf '%s\n' "$VALID_TOML" | grep -v '^paths')
paths = [
  '^a\$',
]"
    "multiline-string:$(printf '%s\n' "$VALID_TOML" | grep -v '^paths')
paths = ['''^a\$''']"
    "quoted-key:$(printf '%s\n' "$VALID_TOML" | sed 's/^paths = /"paths" = /')"
    "dotted-key:$VALID_TOML
allowlists.paths = ['^a\$']"
    "inline-table:$VALID_TOML
x = { paths = ['^a\$'] }"
    "extend-path:$(printf '%s\n' "$VALID_TOML" | sed "s/^useDefault = true/useDefault = true\\
path = '\\/tmp\\/x.toml'/")"
    "disabled-rules:$(printf '%s\n' "$VALID_TOML" | sed "s/^useDefault = true/useDefault = true\\
disabledRules = ['generic-api-key']/")"
    "rules-table:$VALID_TOML
[[rules]]
id = 'x'"
    "single-bracket:$(printf '%s\n' "$VALID_TOML" | sed 's/^\[\[allowlists\]\]/[allowlists]/')"
    "top-level-title:title = 'x'
$VALID_TOML"
    "trailing-comment:$(printf '%s\n' "$VALID_TOML" | sed 's/^condition = "AND"/condition = "AND" # and/')"
    "duplicate-key:$VALID_TOML
condition = \"AND\""
    "lookahead:$(printf '%s\n' "$VALID_TOML" | sed "s/^regexes = .*/regexes = ['^(?=a)b\$']/")"
    "flag-group:$(printf '%s\n' "$VALID_TOML" | sed "s/^regexes = .*/regexes = ['^(?i)b\$']/")"
    "unbalanced:$(printf '%s\n' "$VALID_TOML" | sed "s/^regexes = .*/regexes = ['^(a\$']/")"
    "unknown-key:$VALID_TOML
stopwords = ['x']"
  )
  local c name
  for c in "${cases[@]}"; do
    name="${c%%:*}"
    toml_check "${c#*:}"
    if [[ "$status" -eq 0 || "$output" == "OK" ]]; then
      echo "accepted: $name" >&3
      false
    fi
  done
}

@test "gitleaks-private: an unreadable toml is an error, not an empty (valid) file" {
  toml_check "$VALID_TOML"
  assert_output "OK"
  printf '%s\n' "$VALID_TOML" >"$T/t.toml"
  /bin/chmod 000 "$T/t.toml"
  lib 'glp_check_toml "$HOME/../t.toml"'
  /bin/chmod 600 "$T/t.toml"
  assert_failure
  refute_output "OK"
}

# --- gitleaksignore grammar ---------------------------------------------------

ignore_check() { # <content>
  printf '%s\n' "$1" >"$T/ig"
  lib 'glp_check_ignore "$HOME/../ig"'
}

@test "gitleaks-private: gitleaksignore accepts full-SHA four-field fingerprints, comments and blanks" {
  ignore_check "# historical FPs

$FP40:src/a b.json:generic-api-key:12
  # indented comment
$FP40:x:jwt:1"
  assert_success
  assert_output "OK"
}

@test "gitleaks-private: gitleaksignore rejects short SHAs and three-field (staged) fingerprints" {
  ignore_check "$FP40:src/a.json:generic-api-key:12"
  assert_output "OK"
  ignore_check "${FP40:0:12}:src/a.json:generic-api-key:12"
  assert_failure
  ignore_check "src/a.json:generic-api-key:12"
  assert_failure
  ignore_check "${FP40}0:src/a.json:generic-api-key:12"
  assert_failure
}

@test "gitleaks-private: gitleaksignore rejects every other malformed line" {
  ignore_check "$FP40:a:generic-api-key:1"
  assert_output "OK"
  local bad
  for bad in "$(tr a-f A-F <<<"$FP40"):a:generic-api-key:1" "$FP40:a:generic-api-key:1 " " $FP40:a:generic-api-key:1" \
    "$FP40:a:Generic:1" "$FP40:a:generic-api-key:x" "$FP40::generic-api-key:1" "$FP40:a:generic-api-key" "garbage"; do
    ignore_check "$bad"
    if [[ "$status" -eq 0 ]]; then
      echo "accepted: '$bad'" >&3
      false
    fi
  done
}

# --- ACL parsing --------------------------------------------------------------

acl_check() { # <ls -led output>
  printf '%s\n' "$1" >"$T/acl.txt"
  lib 'glp_acl_parse '"$ME"' <"$HOME/../acl.txt"'
}

@test "gitleaks-private: the exact HOME ACL on this machine (everyone deny delete) passes" {
  acl_check "drwxr-x---+ 80 example  staff  2560 Oct  9 12:23 /Users/example
 0: group:everyone deny delete"
  assert_success
  assert_output "ok"
  # Owner allow entries and read-only non-owner allow entries are fine too.
  acl_check "-rw-------+ 1 x staff 0 Oct 12 09:28 /p q
 0: user:$ME allow write,append,delete
 1: group:everyone inherited allow read,readattr,readextattr,readsecurity,execute
 2: group:staff inherited deny write,delete
 3: group:everyone allow list,search,file_inherit,directory_inherit,limit_inherit,only_inherit"
  assert_success
  # No ACL at all.
  acl_check "-rw------- 1 x staff 0 Oct 12 09:28 /p"
  assert_success
}

@test "gitleaks-private: a non-owner allow entry granting any write-class permission fails" {
  acl_check "drwx------+ 2 x staff 64 Oct 12 09:28 /p
 0: group:everyone allow read"
  assert_output "ok"
  local p
  for p in write append add_file add_subdirectory delete delete_child writeattr writeextattr writesecurity chown; do
    acl_check "drwx------+ 2 x staff 64 Oct 12 09:28 /p
 0: group:everyone allow read,$p"
    if [[ "$status" -eq 0 ]]; then
      echo "accepted allow $p" >&3
      false
    fi
    acl_check "drwx------+ 2 x staff 64 Oct 12 09:28 /p
 0: user:someoneelse inherited allow $p"
    [[ "$status" -ne 0 ]]
  done
}

@test "gitleaks-private: an unrecognized ACL entry line fails closed" {
  acl_check "drwx------+ 2 x staff 64 Oct 12 09:28 /p
 0: group:everyone deny delete"
  assert_output "ok"
  local line
  for line in " 0: group:everyone allow frobnicate" " 0: group:everyone permit read" "garbage" \
    " 0: group:everyone allow" " x: group:everyone deny delete" " 0: group:everyone deny delete extra"; do
    acl_check "drwx------+ 2 x staff 64 Oct 12 09:28 /p
$line"
    if [[ "$status" -eq 0 ]]; then
      echo "accepted: '$line'" >&3
      false
    fi
  done
}

# --- node / chain validation (real filesystem) --------------------------------

resolve_rel() { # <rel>
  lib "glp_resolve '$1'; rc=\$?; printf 'rc=%s\ntoml=%s\nignore=%s\nerr=%s\n' \"\$rc\" \"\$GLP_TOML\" \"\$GLP_IGNORE\" \"\$GLP_ERR\""
}

@test "gitleaks-private: no store (repos/ absent) resolves cleanly with no files" {
  resolve_rel "acme/widget"
  assert_success
  assert_line "rc=0"
  assert_line "toml="
  assert_line "ignore="
}

@test "gitleaks-private: a valid store resolves both files; a store dir without files resolves to none" {
  store "wp/my repo" "$VALID_TOML" "$FP40:a:jwt:1"
  resolve_rel "wp/my repo"
  assert_line "rc=0"
  assert_line "toml=$REPOS/wp/my repo/gitleaks.toml"
  assert_line "ignore=$REPOS/wp/my repo/gitleaksignore"
  store "wp/other"
  resolve_rel "wp/other"
  assert_line "rc=0"
  assert_line "toml="
  resolve_rel "wp/absent"
  assert_line "rc=0"
  assert_line "toml="
}

@test "gitleaks-private: a group- or other-writable component anywhere from HOME to the file is an error" {
  store "wp/r" "$VALID_TOML" "$FP40:a:jwt:1"
  local p
  for p in "$FAKE_HOME" "$FAKE_HOME/.config" "$BASE" "$REPOS" "$REPOS/wp" "$REPOS/wp/r" \
    "$REPOS/wp/r/gitleaks.toml" "$REPOS/wp/r/gitleaksignore"; do
    local old
    old="$(/usr/bin/stat -f %Lp "$p")"
    /bin/chmod g+w "$p"
    resolve_rel "wp/r"
    /bin/chmod "$old" "$p"
    if ! [[ "$output" == *"rc=2"* && "$output" == *"writable"* ]]; then
      echo "g+w not detected: $p" >&3
      false
    fi
    /bin/chmod o+w "$p"
    resolve_rel "wp/r"
    /bin/chmod "$old" "$p"
    assert_line "rc=2"
  done
  resolve_rel "wp/r"
  assert_line "rc=0"
}

@test "gitleaks-private: a symlink anywhere in the chain (or as a private file) is an error" {
  store "wp/r" "$VALID_TOML" "$FP40:a:jwt:1"
  mv "$REPOS/wp" "$T/wp-real"
  ln -s "$T/wp-real" "$REPOS/wp"
  resolve_rel "wp/r"
  assert_line "rc=2"
  assert_output --partial "symlink"
  rm "$REPOS/wp"
  mv "$T/wp-real" "$REPOS/wp"

  mv "$BASE" "$T/base-real"
  ln -s "$T/base-real" "$BASE"
  resolve_rel "wp/r"
  assert_line "rc=2"
  rm "$BASE"
  mv "$T/base-real" "$BASE"

  mv "$REPOS/wp/r/gitleaks.toml" "$T/real.toml"
  ln -s "$T/real.toml" "$REPOS/wp/r/gitleaks.toml"
  resolve_rel "wp/r"
  assert_line "rc=2"
  rm "$REPOS/wp/r/gitleaks.toml"
  mv "$T/real.toml" "$REPOS/wp/r/gitleaks.toml"

  # A dangling symlink is not "absent".
  ln -s "$T/nowhere" "$REPOS/wp/r/gitleaksignore.tmp"
  mv "$REPOS/wp/r/gitleaksignore" "$T/ig.real"
  mv "$REPOS/wp/r/gitleaksignore.tmp" "$REPOS/wp/r/gitleaksignore"
  resolve_rel "wp/r"
  assert_line "rc=2"
  rm "$REPOS/wp/r/gitleaksignore"

  resolve_rel "wp/r"
  assert_line "rc=0"
}

@test "gitleaks-private: a non-regular private file or a non-directory component is an error" {
  store "wp/r"
  mkdir "$REPOS/wp/r/gitleaks.toml"
  resolve_rel "wp/r"
  assert_line "rc=2"
  rmdir "$REPOS/wp/r/gitleaks.toml"
  rm -rf "$REPOS/wp"
  : >"$REPOS/wp"
  /bin/chmod 600 "$REPOS/wp"
  resolve_rel "wp/r"
  assert_line "rc=2"
}

@test "gitleaks-private: an unreadable private file is an error" {
  store "wp/r" "$VALID_TOML" "$FP40:a:jwt:1"
  /bin/chmod 000 "$REPOS/wp/r/gitleaksignore"
  resolve_rel "wp/r"
  /bin/chmod 600 "$REPOS/wp/r/gitleaksignore"
  assert_line "rc=2"
  /bin/chmod 000 "$REPOS/wp/r/gitleaks.toml"
  resolve_rel "wp/r"
  /bin/chmod 600 "$REPOS/wp/r/gitleaks.toml"
  assert_line "rc=2"
}

@test "gitleaks-private: a stat failure (unsearchable store dir) is an error, never 'absent'" {
  store "wp/r" "$VALID_TOML"
  /bin/chmod 000 "$REPOS/wp"
  resolve_rel "wp/r"
  /bin/chmod 700 "$REPOS/wp"
  assert_line "rc=2"
  assert_output --partial "cannot stat"
  /bin/chmod 000 "$REPOS/wp/r"
  resolve_rel "wp/r"
  /bin/chmod 700 "$REPOS/wp/r"
  assert_line "rc=2"
}

@test "gitleaks-private: a grammar violation in a private file is a resolve error" {
  store "wp/r" "$VALID_TOML" "${FP40:0:7}:a:jwt:1"
  resolve_rel "wp/r"
  assert_line "rc=2"
  assert_output --partial "gitleaksignore"
  store "wp/s" "[extend]
useDefault = true
[[allowlists]]
condition = \"AND\""
  resolve_rel "wp/s"
  assert_line "rc=2"
  assert_output --partial "gitleaks.toml"
}

@test "gitleaks-private: a real non-owner ACL allow entry is an error; a deny entry (like HOME's) passes" {
  store "wp/r" "$VALID_TOML"
  /bin/chmod +a "group:everyone deny delete" "$FAKE_HOME" || skip "ACLs unsupported on this filesystem"
  resolve_rel "wp/r"
  assert_line "rc=0"
  /bin/chmod +a "group:everyone allow write" "$REPOS/wp/r/gitleaks.toml"
  resolve_rel "wp/r"
  /bin/chmod -N "$REPOS/wp/r/gitleaks.toml"
  assert_line "rc=2"
  assert_output --partial "ACL"
  /bin/chmod +a "group:staff allow add_file" "$REPOS/wp"
  resolve_rel "wp/r"
  /bin/chmod -N "$REPOS/wp"
  assert_line "rc=2"
  /bin/chmod -N "$FAKE_HOME"
}

@test "gitleaks-private: a component owned by another uid is an error" {
  store "wp/r" "$VALID_TOML"
  lib 'GLP_UID=4242424; glp_resolve "wp/r"; echo "rc=$? err=$GLP_ERR"'
  assert_output --partial "rc=2"
  assert_output --partial "owned by uid"
}

@test "gitleaks-private: validation behaves the same under a GNU-first PATH" {
  use_gnu_path
  store "wp/r" "$VALID_TOML" "$FP40:a:jwt:1"
  resolve_rel "wp/r"
  assert_line "rc=0"
  assert_line "toml=$REPOS/wp/r/gitleaks.toml"
  /bin/chmod g+w "$REPOS/wp/r/gitleaks.toml"
  resolve_rel "wp/r"
  assert_line "rc=2"
  /bin/chmod 600 "$REPOS/wp/r/gitleaks.toml"
  toml_check "$VALID_TOML"
  assert_output "OK"
  toml_check "$(printf '%s\n' "$VALID_TOML" | grep -v '^targetRules')"
  assert_failure
  ignore_check "${FP40:0:12}:a:jwt:1"
  assert_failure
}

@test "gitleaks-private: GITLEAKS_SUPPRESS_DIR relocates the store (tests only)" {
  local alt="$T/alt store"
  mkdir -p "$alt/repos/wp/r"
  /bin/chmod 700 "$alt" "$alt/repos" "$alt/repos/wp" "$alt/repos/wp/r"
  printf '%s\n' "$VALID_TOML" >"$alt/repos/wp/r/gitleaks.toml"
  /bin/chmod 600 "$alt/repos/wp/r/gitleaks.toml"
  EXTRA_ENV=(GITLEAKS_SUPPRESS_DIR="$alt")
  resolve_rel "wp/r"
  assert_line "rc=0"
  assert_line "toml=$alt/repos/wp/r/gitleaks.toml"
}

# --- identity -----------------------------------------------------------------

ident_of() {
  lib "glp_identity '$1'; rc=\$?; printf 'rc=%s rel=%s\n' \"\$rc\" \"\$GLP_REL\""
}

@test "gitleaks-private: identity of a repo under ~/code is its path relative to ~/code (spaces ok)" {
  mkrepo "$CODE/wp/my repo"
  mkdir -p "$CODE/wp/my repo/sub dir"
  ident_of "$CODE/wp/my repo/sub dir"
  assert_output "rc=0 rel=wp/my repo"
}

@test "gitleaks-private: a linked worktree shares its main repo's identity (inside or outside ~/code)" {
  mkrepo "$CODE/wp/main"
  git -C "$CODE/wp/main" worktree add -q "$CODE/wp/main-wt" -b wt
  git -C "$CODE/wp/main" worktree add -q "$T/outside wt" -b wt2
  ident_of "$CODE/wp/main-wt"
  assert_output "rc=0 rel=wp/main"
  ident_of "$T/outside wt"
  assert_output "rc=0 rel=wp/main"
}

@test "gitleaks-private: a submodule has its own identity" {
  mkrepo "$T/subsrc"
  mkrepo "$CODE/super"
  git -C "$CODE/super" -c protocol.file.allow=always submodule -q add "$T/subsrc" "mods/sub" 2>/dev/null
  ident_of "$CODE/super/mods/sub"
  assert_output "rc=0 rel=super/mods/sub"
}

@test "gitleaks-private: repos outside ~/code (or a prefix-sibling like ~/code2, or ~/code itself) have no identity" {
  mkrepo "$T/elsewhere"
  ident_of "$T/elsewhere"
  assert_output "rc=1 rel="
  mkrepo "$FAKE_HOME/code2/x"
  ident_of "$FAKE_HOME/code2/x"
  assert_output "rc=1 rel="
  mkrepo "$CODE"
  ident_of "$CODE"
  assert_output "rc=1 rel="
  ident_of "$T"
  assert_output "rc=1 rel="
}

@test "gitleaks-private: identity canonicalizes a symlinked ~/code and /var vs /private/var" {
  mkdir -p "$T/real code"
  rmdir "$CODE"
  ln -s "$T/real code" "$CODE"
  mkrepo "$T/real code/wp/r"
  ident_of "$CODE/wp/r"
  assert_output "rc=0 rel=wp/r"
  ident_of "$T/real code/wp/r"
  assert_output "rc=0 rel=wp/r"
  # HOME spelled through /var while git reports /private/var (or vice versa).
  local alt
  case "$FAKE_HOME" in
    /private/var/*) alt="${FAKE_HOME#/private}" ;;
    /var/*) alt="/private$FAKE_HOME" ;;
    *) skip "temp dir is not under /var" ;;
  esac
  [[ -d "$alt" ]] || skip "no /var alias for $FAKE_HOME"
  FAKE_HOME="$alt"
  ident_of "$CODE/wp/r"
  assert_output "rc=0 rel=wp/r"
}

# --- regex lexer: Go RE2 syntax the anchoring check must not misread --------

re_check() { # <regex>: OK or the reason
  lib 'glp_check_re "$GLP_TEST_RE"'
}

@test "gitleaks-private: Go \\Q...\\E quoting is rejected (it can hide a top-level |)" {
  local re
  for re in '^\Q(\Ea|b\Q)\E$' '^\Qa|b\E$' '^a\E$' '^\Q$'; do
    EXTRA_ENV=(GLP_TEST_RE="$re")
    re_check
    if [[ "$status" -eq 0 ]]; then
      echo "accepted: $re" >&3
      false
    fi
  done
  EXTRA_ENV=(GLP_TEST_RE='^a\.b$')
  re_check
  assert_output "OK"
}

@test "gitleaks-private: only whitelisted escapes are allowed" {
  local re
  for re in '^\p{L}+$' '^\pL$' '^\P{L}$' '^\x41$' '^\x{41}$' '^\bfoo$' '^\Bx$' '^\Afoo$' '^a\z$' '^\1$' \
    '^\0$' '^\a$' '^\f$' '^\r$' '^\v$' '^\C$' '^\K$' '^\,$' '^[\p{L}]$' '^[\Q]\E]$'; do
    EXTRA_ENV=(GLP_TEST_RE="$re")
    re_check
    if [[ "$status" -eq 0 ]]; then
      echo "accepted: $re" >&3
      false
    fi
  done
  for re in '^\.\-\/\[\]\(\)\{\}\|\*\+\?\^\$\"\#\ $' '^\d\w\t$' '^\n?\d$' '^a\\$' '^[\d\-\]\[]+$'; do
    EXTRA_ENV=(GLP_TEST_RE="$re")
    re_check
    if [[ "$output" != "OK" ]]; then
      echo "rejected: $re ($output)" >&3
      false
    fi
  done
}

@test "gitleaks-private: groups other than plain and (?:...) are rejected" {
  local re
  for re in '^(?P<n>a)$' '^(?<n>a)$' '^(?i)a$' '^(?i:a)$' '^(?s)a$' '^(?m:a)$' '^(?=a)$' '^(?!a)$' '^(?<=a)b$' \
    '^(?#c)a$' '^(?U)a*$'; do
    EXTRA_ENV=(GLP_TEST_RE="$re")
    re_check
    if [[ "$status" -eq 0 ]]; then
      echo "accepted: $re" >&3
      false
    fi
  done
  for re in '^(a|b)$' '^(?:a|b)$' '^x(?:a(b|c))?y$'; do
    EXTRA_ENV=(GLP_TEST_RE="$re")
    re_check
    assert_output "OK"
  done
}

@test "gitleaks-private: character classes: | ( ) inside are literal; ambiguous ] / [ / POSIX classes are rejected" {
  local re
  for re in '^[|()]$' '^a[|]b$' '^[a-z0-9_]+$' '^[ \t]*x$'; do
    EXTRA_ENV=(GLP_TEST_RE="$re")
    re_check
    if [[ "$output" != "OK" ]]; then
      echo "rejected: $re ($output)" >&3
      false
    fi
  done
  for re in '^[]a]$' '^[^]a]$' '^[[:alpha:]]$' '^[a[b]$' '^[a$' '^a]$' '^[a]|b$' '^[|]|x$'; do
    EXTRA_ENV=(GLP_TEST_RE="$re")
    re_check
    if [[ "$status" -eq 0 ]]; then
      echo "accepted: $re" >&3
      false
    fi
  done
}

@test "gitleaks-private: the anchored data_key and JSON-member line shapes are accepted" {
  local re
  for re in '^\n?[ \t]*"key": "[0-9a-f]{40}",?$' \
    '^\n? +(?:[a-z0-9_]+: [A-Za-z\[\]]+ = field\(metadata=\{"data_key": "[A-Za-z0-9]+"\}\)|(?:default=None, )?metadata=\{"data_key": "[A-Za-z0-9]+"\})$' \
    '^src/app(_dsp)?/schema/(models|sb_models)\.py$'; do
    EXTRA_ENV=(GLP_TEST_RE="$re")
    re_check
    assert_output "OK"
  done
}

# --- non-macOS ------------------------------------------------------------------

@test "gitleaks-private: off macOS an existing store fails closed with a macOS-only error; no store is fine" {
  store "wp/r" "$VALID_TOML"
  lib 'OSTYPE=linux-gnu; glp_resolve "wp/r"; echo "rc=$? toml=$GLP_TOML err=$GLP_ERR"'
  assert_output --partial "rc=2 toml= err="
  assert_output --partial "require macOS"
  mkrepo "$CODE/wp/r"
  lib 'OSTYPE=linux-gnu; glp_lookup "$HOME/code/wp/r" "$HOME/code/wp/r"; echo "rc=$? err=$GLP_ERR"'
  assert_output --partial "rc=2"
  assert_output --partial "require macOS"
  # A repo outside ~/code never consults the store, on any OS.
  mkrepo "$T/outside"
  lib 'OSTYPE=linux-gnu; glp_lookup "$HOME/../outside" "$HOME/../outside"; echo "rc=$? toml=$GLP_TOML"'
  assert_output "rc=0 toml="
  rm -rf "$REPOS"
  lib 'OSTYPE=linux-gnu; glp_lookup "$HOME/code/wp/r" "$HOME/code/wp/r"; echo "rc=$? toml=$GLP_TOML"'
  assert_output "rc=0 toml="
}

@test "gitleaks-private: a repo rel with a backslash or control character is a resolve error (fail closed)" {
  store "wp/r" "$VALID_TOML"
  local rel
  for rel in 'wp\r' "$(printf 'wp/t\tab')" "$(printf 'wp/c\001')"; do
    EXTRA_ENV=(GLP_TEST_REL="$rel")
    lib 'glp_resolve "$GLP_TEST_REL"; echo "rc=$? err=$GLP_ERR"'
    assert_output --partial "rc=2"
    assert_output --partial "backslash or control character"
  done
}

# re_reject / re_accept <regex...>: each must be rejected / accepted.
re_reject() {
  local re
  for re in "$@"; do
    EXTRA_ENV=(GLP_TEST_RE="$re")
    re_check
    if [[ "$status" -eq 0 ]]; then
      echo "accepted: $re" >&3
      return 1
    fi
  done
}
re_accept() {
  local re
  for re in "$@"; do
    EXTRA_ENV=(GLP_TEST_RE="$re")
    re_check
    if [[ "$output" != "OK" ]]; then
      echo "rejected: $re ($output)" >&3
      return 1
    fi
  done
}

@test "gitleaks-private: a quantified or misplaced anchor is rejected (^? ^* ^+ ^{n}, mid-pattern ^ or \$)" {
  re_accept '^x$' '^\n?x$' '^\n?[ \t]*"key": "[0-9a-f]{40}",?$' '^[$^]x$' '^a\$b\^c$'
  re_reject '^?x$' '^*x$' '^+x$' '^{0,1}x$' '^{1}x$' \
    '^a$b$' '^a$?$' '^a$*$' '^(a$)$' '^a(^b)$' '^a^b$' '^(^)?a$' '^x$$'
}

@test "gitleaks-private: \\n is allowed only as the exact ^\\n? prefix" {
  re_accept '^\n?x$'
  re_reject '^\n*x$' '^\n+x$' '^\n{0,2}x$' '^\n??x$' '^\n?*x$' '^\nx$' '^x\n?$' '^\n?\n?x$' '^(\n?)x$' '^a\n$' '^[\n]x$'
}

@test "gitleaks-private: wildcards are rejected: unescaped ., negated classes, \\S \\W \\D" {
  re_accept '^a\.b$' '^[.]$' '^[a-z.]+$'
  re_reject '^a.b$' '^.*$' '^x.+$' '^(?:.)$' '^[^x]+$' '^[^]x]$' '^\S+$' '^\W$' '^\D$' '^[\S]$'
}

@test "gitleaks-private: \\s is rejected inside and outside classes (it matches newlines; write [ \\t])" {
  re_accept '^[ \t]*x$' '^ +x$'
  re_reject '^\s*x$' '^a\s+b$' '^[\s]x$' '^[a\s]+$'
}

@test "gitleaks-private: an empty private file and an absent one have different digests; an md5 failure is an error" {
  : >"$T/empty.toml"
  lib 'GLP_TOML="$HOME/../empty.toml"; GLP_IGNORE=""; glp_files_digest; echo "rc=$?"'
  assert_line --regexp '^.*/empty\.toml [0-9a-f]{32}$'
  assert_line "rc=0"
  lib 'GLP_TOML=""; GLP_IGNORE=""; glp_files_digest; echo "rc=$?"'
  assert_output "rc=0"
  printf '#!/bin/bash\nexit 1\n' >"$T/bad-md5"
  chmod +x "$T/bad-md5"
  EXTRA_ENV=(GITLEAKS_MD5="$T/bad-md5")
  lib 'GLP_TOML="$HOME/../empty.toml"; GLP_IGNORE=""; glp_files_digest; echo "rc=$?"'
  assert_line "rc=1"
}

# --- repo paths and the protected manifest grammar (shared with the store
# export/import) ---------------------------------------------------------------

@test "gitleaks-private: glp_valid_rel accepts nested repo paths and rejects empty, '.', '..', absolute, and control characters" {
  local r
  for r in alpha "team x/beta" "a/b/c" "dots.in.name/x-y_z"; do
    EXTRA_ENV=(TERM=dumb R="$r")
    lib 'glp_valid_rel "$R"'
    assert_success
  done
  for r in "" "/abs" "a/" "./a" "a/./b" "a/../b" ".." "a//b" 'a\b' $'a\tb'; do
    EXTRA_ENV=(TERM=dumb R="$r")
    lib 'glp_valid_rel "$R"'
    assert_failure
  done
  EXTRA_ENV=(TERM=dumb)
}

@test "gitleaks-private: glp_check_protected accepts '<rel> <full fingerprint>' lines and rejects the rest with a line number" {
  printf '# rotate first\n\nalpha %s:src/a.txt:generic-api-key:3\nteam x/beta %s:b:jwt:1\n' "$FP40" "$FP40" >"$T/prot"
  lib 'glp_check_protected "$HOME/../prot"'
  assert_success
  assert_output "OK"
  local bad
  for bad in "alpha ${FP40:0:12}:src/a.txt:jwt:3" "a/../b $FP40:x:jwt:1" "/abs $FP40:x:jwt:1" "alpha" "alpha $FP40:x:jwt"; do
    printf '# c\n%s\n' "$bad" >"$T/prot"
    lib 'glp_check_protected "$HOME/../prot"'
    assert_failure
    assert_output --regexp '^line 2: '
  done
  printf 'a\\b %s:x:jwt:1\n' "$FP40" >"$T/prot"
  lib 'glp_check_protected "$HOME/../prot"'
  assert_failure
  assert_output "line 1: the repo path contains a backslash or control character"
}
