#!/usr/bin/env bash
# gitleaks-private.sh — private, per-repo gitleaks suppressions shared by
# personal/gitleaks-hook.sh (pre-commit) and personal/gitleaks-audit.sh
# (daily history audit). Shared Library: sourced, no main; defines glp_*
# functions and GLP_* variables only.
#
# Store (local to this machine; never committed to the scanned repos, so it
# only affects this user's hook and audit):
#   <base>/repos/<rel>/gitleaks.toml   passed as `gitleaks --config`
#   <base>/repos/<rel>/gitleaksignore  passed as `--gitleaks-ignore-path`
#   <base>/protected                   rotate-first fingerprints (audit only)
# <base> is ~/.config/gitleaks-audit. GITLEAKS_SUPPRESS_DIR overrides it for
# tests only: it is NOT a security boundary (anything that can set this
# user's environment can already run code as this user).
#
# <rel> is the repo's identity relative to the canonical ~/code (see
# glp_identity): linked worktrees share their main repo's store, submodules
# have their own, and repos outside ~/code have no store at all.
#
# Threat model: accidental unsafe permissions or symlinks, not same-user
# malicious code. Before any private file is used, every path component from
# $HOME (inclusive) down to the file must be: not a symlink, owned by the
# current uid, not group/other writable, and free of ACL entries that let
# anyone but the owner write to it (deny entries are fine). Components above
# $HOME are not checked. stat/ls failures are errors, never "absent". Only an
# ENOENT from stat means absent.
#
# Both private files must also pass a strict whitelist grammar (see
# glp_check_toml / glp_check_ignore). Note for line regexes: gitleaks'
# regexTarget = "line" target starts with a newline for every line except
# the first of a fragment (verified with 8.30.1, staged and history), so a
# whole-line regex must begin `^\n?` to match at all. The repo's own
# .gitleaksignore and inline `gitleaks:allow` comments stay trusted.
#
# Bash 3.2-compatible; never uses `set -e`. External tools are called by
# absolute path where GNU versions on PATH would differ (/usr/bin/stat,
# /bin/ls); awk/grep usage is POSIX.

GLP_BASE="${GITLEAKS_SUPPRESS_DIR:-${HOME-}/.config/gitleaks-audit}"
GLP_REPOS="$GLP_BASE/repos"
GLP_PROTECTED="$GLP_BASE/protected"
# Current uid / user name: looked up lazily (glp_ids), so sourcing this file
# and the no-store fast path cost no extra processes.
GLP_UID="${GLP_UID:-}"
GLP_USER="${GLP_USER:-}"

# md5 used for content digests; GITLEAKS_MD5 overrides it for tests only (not
# a security boundary).
GLP_MD5="${GITLEAKS_MD5:-/sbin/md5}"

GLP_ERR=""
GLP_REL=""
GLP_ROOT=""
GLP_STORE=""
GLP_TOML=""
GLP_IGNORE=""
GLP_ST_TYPE=""
GLP_ST_UID=""
GLP_ST_MODE=""

# glp_platform_check: the validator needs BSD stat and `ls -le` ACLs. Off
# macOS a store that exists fails closed (2, GLP_ERR); no store is fine (0).
glp_platform_check() {
  case "${OSTYPE:-}" in
    darwin*) return 0 ;;
  esac
  if [[ -e "$GLP_REPOS" || -L "$GLP_REPOS" || -e "$GLP_PROTECTED" || -L "$GLP_PROTECTED" ]]; then
    GLP_ERR="private suppressions under $GLP_BASE require macOS (BSD stat and ACL validation); move the store away on this OS"
    return 2
  fi
  return 0
}

# glp_bad_rel <rel>: 0 when <rel> contains a backslash or a control
# character. Such paths are rejected outright (fail closed) so every consumer
# (awk, grep -F, line-based files) sees the same literal string.
glp_bad_rel() {
  local LC_ALL=C
  [[ "$1" == *\\* || "$1" =~ [[:cntrl:]] ]]
}

glp_ids() {
  [[ -n "$GLP_UID" ]] || GLP_UID="$(id -u 2>/dev/null)"
  [[ -n "$GLP_USER" ]] || GLP_USER="$(id -un 2>/dev/null)"
}

# glp_lstat <path>: one lstat via BSD /usr/bin/stat (no -L: symlinks are
# reported, not followed). Sets GLP_ST_TYPE (dir|file|link|other),
# GLP_ST_UID, GLP_ST_MODE (octal permission bits). Returns 0 = present,
# 1 = absent (ENOENT only), 2 = error (GLP_ERR set; e.g. EACCES on a parent).
glp_lstat() {
  local out
  GLP_ST_TYPE=""
  GLP_ST_UID=""
  GLP_ST_MODE=""
  if out="$(LC_ALL=C /usr/bin/stat -f '%HT|%u|%Lp' -- "$1" 2>&1)"; then
    case "${out%%|*}" in
      Directory) GLP_ST_TYPE="dir" ;;
      "Regular File") GLP_ST_TYPE="file" ;;
      "Symbolic Link") GLP_ST_TYPE="link" ;;
      *) GLP_ST_TYPE="other" ;;
    esac
    out="${out#*|}"
    GLP_ST_UID="${out%%|*}"
    GLP_ST_MODE="${out#*|}"
    if [[ ! "$GLP_ST_UID" =~ ^[0-9]+$ || ! "$GLP_ST_MODE" =~ ^[0-7]+$ ]]; then
      GLP_ERR="cannot stat $1: unexpected stat output"
      return 2
    fi
    return 0
  fi
  case "$out" in
    *": No such file or directory") return 1 ;;
  esac
  GLP_ERR="cannot stat $1: ${out##*: }"
  return 2
}

# glp_acl_parse <owner-name>: reads `/bin/ls -led <path>` output on stdin and
# prints "ok", or "error: <reason>" (returns 1). The first line is the long
# listing; every further line must be an ACL entry
#   " N: <principal> [inherited ]allow|deny <perm>[,<perm>...]"
# with known permission names. A non-owner allow entry granting any
# write-class permission is an error; deny entries and read-class allow
# entries are fine. Anything unrecognized fails closed.
glp_acl_parse() {
  GLP_OWNER="user:$1" awk '
    BEGIN {
      owner = ENVIRON["GLP_OWNER"]
      split("read readattr readextattr readsecurity execute list search file_inherit directory_inherit limit_inherit only_inherit", a, " ")
      for (i in a) safe[a[i]] = 1
      split("write append add_file add_subdirectory delete delete_child writeattr writeextattr writesecurity chown", b, " ")
      for (i in b) danger[b[i]] = 1
      err = ""
    }
    NR == 1 { next }
    err != "" { next }
    {
      line = $0
      if (line !~ /^ *[0-9]+: /) { err = "unrecognized ACL line"; next }
      sub(/^ *[0-9]+: /, "", line)
      n = split(line, f, " ")
      i = 2
      if (f[i] == "inherited") i++
      kind = f[i]
      perms = f[i + 1]
      if (n != i + 1 || (kind != "allow" && kind != "deny") || perms == "") { err = "unrecognized ACL entry"; next }
      m = split(perms, p, ",")
      for (j = 1; j <= m; j++) {
        if (!(p[j] in safe) && !(p[j] in danger)) { err = "unrecognized ACL permission"; next }
        if (kind == "allow" && f[1] != owner && (p[j] in danger)) { err = "ACL entry lets " f[1] " " p[j]; next }
      }
    }
    END {
      if (err != "") { print "error: " err; exit 1 }
      print "ok"
    }'
}

# glp_check_node <path> <dir|file>: validate one path component. Returns 0 =
# present and safe, 1 = absent, 2 = error (GLP_ERR set).
glp_check_node() {
  local p="$1" want="$2" rc mode out
  glp_ids
  glp_lstat "$p"
  rc=$?
  [[ $rc -eq 0 ]] || return $rc
  if [[ "$GLP_ST_TYPE" == link ]]; then
    GLP_ERR="$p is a symlink (private suppression paths must not be symlinks)"
    return 2
  fi
  if [[ "$GLP_ST_TYPE" != "$want" ]]; then
    if [[ "$want" == dir ]]; then
      GLP_ERR="$p is not a directory"
    else
      GLP_ERR="$p is not a regular file"
    fi
    return 2
  fi
  if [[ "$GLP_ST_UID" != "$GLP_UID" ]]; then
    GLP_ERR="$p is owned by uid $GLP_ST_UID, not $GLP_UID"
    return 2
  fi
  mode=$((8#$GLP_ST_MODE))
  if [[ $((mode & 022)) -ne 0 ]]; then
    GLP_ERR="$p is group/other writable (mode $GLP_ST_MODE); chmod go-w it"
    return 2
  fi
  if ! out="$(LC_ALL=C /bin/ls -led -- "$p" 2>/dev/null)" || [[ -z "$out" ]]; then
    GLP_ERR="cannot list the ACL of $p"
    return 2
  fi
  # A single line is the long listing alone: no ACL entries to parse.
  [[ "$out" == *$'\n'* ]] || return 0
  out="$(printf '%s\n' "$out" | glp_acl_parse "$GLP_USER")"
  if [[ "$out" != ok ]]; then
    GLP_ERR="$p: unsafe or unrecognized ACL (${out#error: }); inspect with: /bin/ls -led '$p'"
    return 2
  fi
  return 0
}

# glp_walk <from> <to>: validate the directory <from> and every directory
# component of <to> below it (<to> must be <from> or below it). 0 = all
# present and safe, 1 = some component absent, 2 = error.
glp_walk() {
  local cur="$1" rest comp rc
  glp_check_node "$cur" dir
  rc=$?
  [[ $rc -eq 0 ]] || return $rc
  rest="${2#"$1"}"
  while [[ -n "$rest" ]]; do
    rest="${rest#/}"
    comp="${rest%%/*}"
    if [[ "$rest" == */* ]]; then rest="${rest#*/}"; else rest=""; fi
    [[ -n "$comp" ]] || continue
    cur="$cur/$comp"
    glp_check_node "$cur" dir
    rc=$?
    [[ $rc -eq 0 ]] || return $rc
  done
  return 0
}

# glp_check_base: validate $HOME -> <base> (inclusive). When <base> is not
# under $HOME (GITLEAKS_SUPPRESS_DIR in tests) only <base> itself is checked.
# 0 = present and safe, 1 = absent, 2 = error.
glp_check_base() {
  local rc
  case "$GLP_BASE" in
    "${HOME-}"/*)
      glp_walk "${HOME-}" "$GLP_BASE"
      rc=$?
      # HOME itself must exist; only the store part may be absent.
      if [[ $rc -eq 1 && ! -d "${HOME-}" ]]; then
        GLP_ERR="HOME (${HOME-}) is not a directory"
        return 2
      fi
      return $rc
      ;;
    *)
      glp_check_node "$GLP_BASE" dir
      return $?
      ;;
  esac
}

# glp_store_present: 0 when the repos store or the protected manifest exists
# (or cannot be ruled out: a stat error counts as present, so the caller
# validates and fails closed); 1 when both are absent (feature off).
glp_store_present() {
  glp_lstat "$GLP_REPOS"
  [[ $? -eq 1 ]] || return 0
  glp_lstat "$GLP_PROTECTED"
  [[ $? -eq 1 ]] || return 0
  return 1
}

# check_re (awk): "" when <re> is fully anchored under a strict, fail-closed
# subset of Go RE2 syntax; else the reason. The lexer accepts only syntax
# whose structure it reads exactly as RE2 does:
#   - starts with ^ and ends with an unescaped $; no other unescaped ^ or $
#     outside a character class, and no quantifier (? * + {) right after the
#     leading ^ (a quantified anchor is optional, i.e. no anchor at all)
#   - the only optional prefix is exactly ^\n? (gitleaks' line target starts
#     with a newline, except for a fragment's first line); \n is allowed
#     nowhere else, and nothing may quantify the \n? again
#   - escapes: \ followed by one of  \ . - / [ ] ( ) { } | * + ? ^ $ " # space
#     (literals) or d w t (digit / word class, tab). Everything else is
#     rejected, notably \Q...\E (literal quoting can hide a |), \p \P \x
#     \b \B \A \z, back-references, the negated \D \S \W, and \s (it also
#     matches newlines; write [ \t]), inside classes too.
#   - no wildcards: an unescaped . outside a class and negated classes [^...]
#     are rejected (match literal text, escaped dots, and plain classes);
#     how narrow a class is stays a review responsibility
#   - groups: plain (...) and (?:...) only; no flags, names, or lookaround.
#   - character classes [...]: | ( ) . are literal inside (as in RE2); an
#     unescaped [ inside (POSIX [:alpha:], nesting) and an unescaped ] first
#     in the class are rejected; an unescaped ] outside a class is rejected
#     too (escape it as \]).
#   - no | at group depth 0 (it would defeat the anchors).
glp_check_re_awk='
function check_re(re,    n, i, c, d, esc, depth, incls, first) {
  esc = "\\.-/[](){}|*+?^$\"# dwt"
  n = length(re)
  if (n < 2 || substr(re, 1, 1) != "^") return "not anchored with a leading ^"
  if (substr(re, n, 1) != "$") return "not anchored with a trailing $"
  i = 2
  if (substr(re, 2, 3) == "\\n?") i = 5
  if (i < n && index("?*+{", substr(re, i, 1)) > 0) return "a quantifier right after the leading anchor (or its \\n? prefix) makes the anchor optional"
  depth = 0
  incls = 0
  for (; i < n; i++) {
    c = substr(re, i, 1)
    if (c == "\\") {
      if (i + 1 >= n) return "the trailing $ is escaped"
      d = substr(re, i + 1, 1)
      if (d == "n") return "\\n is allowed only as the exact ^\\n? prefix"
      if (index(esc, d) == 0) return "escape \\" d " is not allowed (allowed: \\ before one of \\.-/[](){}|*+?^$\"# or dwt; for whitespace write [ \\t])"
      i++
      first = 0
      continue
    }
    if (incls) {
      if (c == "[") return "unescaped [ inside a character class (POSIX classes and nesting are not allowed; use \\[)"
      if (c == "]") {
        if (first) return "unescaped ] first in a character class (use \\])"
        incls = 0
        continue
      }
      first = 0
      continue
    }
    if (c == "[") {
      if (substr(re, i + 1, 1) == "^") return "negated character classes [^...] are not allowed (too broad)"
      incls = 1
      first = 1
      continue
    }
    if (c == "]") return "unescaped ] outside a character class (use \\])"
    if (c == ".") return "unescaped . (a wildcard) is not allowed; escape it as \\. or use a class"
    if (c == "^" || c == "$") return "an unescaped " c " is allowed only as the leading/trailing anchor"
    if (c == "(") {
      if (substr(re, i + 1, 1) == "?") {
        if (substr(re, i + 2, 1) != ":") return "only plain (...) and (?:...) groups are allowed (no flags, names, or lookaround)"
        i += 2
      }
      depth++
      continue
    }
    if (c == ")") {
      depth--
      if (depth < 0) return "unbalanced )"
      continue
    }
    if (c == "|" && depth == 0) return "top-level | defeats the anchors (wrap alternatives in (?:...))"
  }
  if (incls) return "unterminated character class"
  if (depth != 0) return "unbalanced ("
  return ""
}'

# glp_check_re <regex>: prints "OK" (returns 0) or the reason (returns 1).
glp_check_re() {
  local out
  out="$(GLP_RE="$1" awk "$glp_check_re_awk"'
    BEGIN { r = check_re(ENVIRON["GLP_RE"]); if (r != "") { print r; exit 1 } print "OK" }' 2>/dev/null)"
  if [[ "$out" == OK ]]; then
    echo OK
    return 0
  fi
  echo "${out:-cannot check the regex}"
  return 1
}

# glp_check_toml <file>: strict whitelist grammar for a private gitleaks.toml.
# Prints "OK" (returns 0) or "line N: <reason>" (returns 1). Accepted:
#   blank lines and full-line # comments
#   [extend] exactly once, first, followed by exactly `useDefault = true`
#   [[allowlists]] blocks, each with exactly these keys (each at most once):
#     description = '<text>'                  (optional)
#     targetRules = ['<rule-id>']              exactly one rule, [a-z0-9-]+
#     condition   = "AND"
#     regexTarget = "line"
#     paths       = ['^...$', ...]             one line, literal strings,
#     regexes     = ['^...$', ...]             each fully anchored
# Everything else is rejected: other keys/tables, quoted or dotted keys,
# inline tables, basic ("...") strings in values, multi-line arrays or
# strings, trailing comments.
glp_check_toml() {
  local out
  if ! { : <"$1"; } 2>/dev/null; then
    echo "cannot read $1"
    return 1
  fi
  out="$(awk "$glp_check_re_awk"'
    function fail(msg) { if (err == "") err = "line " NR ": " msg }
    function close_block() {
      if (!inblock) return
      if (!("targetRules" in seen)) fail("[[allowlists]] block ending here has no targetRules (a global allowlist is not allowed)")
      else if (!("condition" in seen)) fail("[[allowlists]] block ending here has no condition = \"AND\"")
      else if (!("paths" in seen)) fail("[[allowlists]] block ending here has no paths")
      else if (!("regexTarget" in seen)) fail("[[allowlists]] block ending here has no regexTarget = \"line\"")
      else if (!("regexes" in seen)) fail("[[allowlists]] block ending here has no regexes")
      inblock = 0
    }
    function check_array(v, what,    s, j, el, cnt, r) {
      if (v !~ /^\[.*\]$/) return what " must be a one-line array"
      s = substr(v, 2, length(v) - 2)
      cnt = 0
      while (1) {
        sub(/^[ \t]+/, "", s)
        if (s == "") break
        if (substr(s, 1, 1) != "\047") return what " elements must be single-quoted literal strings"
        s = substr(s, 2)
        j = index(s, "\047")
        if (j == 0) return what " has an unterminated string"
        el = substr(s, 1, j - 1)
        s = substr(s, j + 1)
        cnt++
        r = check_re(el)
        if (r != "") return what " element " cnt ": " r
        sub(/^[ \t]+/, "", s)
        if (s == "") break
        if (substr(s, 1, 1) != ",") return what " elements must be separated by commas"
        s = substr(s, 2)
      }
      if (cnt == 0) return what " is empty"
      return ""
    }
    BEGIN { state = "top"; err = ""; extends = 0; inblock = 0 }
    err != "" { next }
    /^[ \t]*$/ { next }
    /^[ \t]*#/ { next }
    {
      line = $0
      sub(/[ \t]+$/, "", line)
      sub(/^[ \t]+/, "", line)
    }
    line == "[extend]" {
      if (extends) { fail("[extend] appears more than once"); next }
      if (state != "top") { fail("[extend] must come first"); next }
      extends = 1
      state = "extend"
      next
    }
    line == "[[allowlists]]" {
      if (state != "extend_done" && state != "allow") { fail("[[allowlists]] before [extend] useDefault = true"); next }
      close_block()
      delete seen
      inblock = 1
      state = "allow"
      next
    }
    /^\[/ { fail("unsupported table (only [extend] and [[allowlists]] are allowed)"); next }
    {
      if (line !~ /^[A-Za-z]+[ \t]*=/) { fail("unsupported syntax (bare keys only)"); next }
      key = line
      sub(/[ \t]*=.*$/, "", key)
      val = line
      sub(/^[A-Za-z]+[ \t]*=[ \t]*/, "", val)
      if (state == "extend") {
        if (key == "useDefault" && val == "true") { state = "extend_done"; next }
        fail("[extend] must contain exactly useDefault = true")
        next
      }
      if (state != "allow") { fail("key outside an [[allowlists]] block"); next }
      if (key in seen) { fail("duplicate key " key); next }
      seen[key] = 1
      if (key == "description") {
        if (val !~ /^\047[^\047]*\047$/) fail("description must be a single-quoted literal string")
      } else if (key == "targetRules") {
        if (val !~ /^\[[ \t]*\047[a-z0-9-]+\047[ \t]*\]$/) fail("targetRules must be exactly one rule id: [\047rule-id\047]")
      } else if (key == "condition") {
        if (val != "\"AND\"") fail("condition must be \"AND\"")
      } else if (key == "regexTarget") {
        if (val != "\"line\"") fail("regexTarget must be \"line\"")
      } else if (key == "paths" || key == "regexes") {
        r = check_array(val, key)
        if (r != "") fail(r)
      } else {
        fail("unsupported key " key)
      }
    }
    END {
      if (err == "") {
        if (!extends) fail("missing [extend] with useDefault = true")
        else if (state == "extend") fail("[extend] must contain useDefault = true")
        else close_block()
      }
      if (err != "") { print err; exit 1 }
      print "OK"
    }' <"$1" 2>/dev/null)"
  if [[ "$out" == OK ]]; then
    echo OK
    return 0
  fi
  echo "${out:-cannot parse $1}"
  return 1
}

# glp_check_ignore <file>: a private gitleaksignore may contain only blank
# lines, # comments, and FULL-SHA history fingerprints
#   <40 lowercase hex commit>:<file>:<rule-id>:<line>
# (a short SHA never matches, and three-field staged fingerprints are
# rejected: the private store suppresses staged findings only through its
# content-shaped allowlists). Prints "OK" or "line N: <reason>".
glp_check_ignore() {
  local line n=0 LC_ALL=C
  local re='^[0-9a-f]{40}:[^:]+:[a-z0-9-]+:[0-9]+$'
  if ! { : <"$1"; } 2>/dev/null; then
    echo "cannot read $1"
    return 1
  fi
  while IFS= read -r line || [[ -n "$line" ]]; do
    n=$((n + 1))
    [[ "$line" =~ ^[[:space:]]*$ || "$line" =~ ^[[:space:]]*# ]] && continue
    if [[ ! "$line" =~ $re ]]; then
      echo "line $n: not a full-SHA history fingerprint <40-hex-commit>:<file>:<rule>:<line>"
      return 1
    fi
  done <"$1"
  echo OK
  return 0
}

# glp_valid_rel <rel>: 0 when <rel> is a usable store repo path: non-empty,
# relative, every '/'-separated component non-empty and neither '.' nor '..',
# and no backslash or control character (glp_bad_rel). The protected
# manifest, the store export/import, and store enumeration share this rule.
glp_valid_rel() {
  local rel="$1" rest comp
  [[ -n "$rel" ]] || return 1
  glp_bad_rel "$rel" && return 1
  rest="$rel/"
  while [[ -n "$rest" ]]; do
    comp="${rest%%/*}"
    rest="${rest#*/}"
    case "$comp" in
      "" | . | ..) return 1 ;;
    esac
  done
  return 0
}

# glp_check_protected <file>: grammar of the protected manifest. Blank lines
# and # comments, otherwise exactly `<rel> <40-hex-commit>:<file>:<rule>:<line>`
# where <rel> passes glp_valid_rel. Prints "OK" (returns 0) or
# "line N: <reason>" (returns 1).
glp_check_protected() {
  local line n=0 re='^(.+) ([0-9a-f]{40}:[^: ]+:[a-z0-9-]+:[0-9]+)$'
  if ! { : <"$1"; } 2>/dev/null; then
    echo "cannot read $1"
    return 1
  fi
  while IFS= read -r line || [[ -n "$line" ]]; do
    n=$((n + 1))
    [[ "$line" =~ ^[[:space:]]*$ || "$line" =~ ^[[:space:]]*# ]] && continue
    if [[ "$line" =~ $re ]] && glp_bad_rel "${BASH_REMATCH[1]}"; then
      echo "line $n: the repo path contains a backslash or control character"
      return 1
    fi
    if [[ "$line" =~ $re ]] && glp_valid_rel "${BASH_REMATCH[1]}"; then
      continue
    fi
    echo "line $n: expected '<rel> <40-hex-commit>:<file>:<rule>:<line>'"
    return 1
  done <"$1"
  echo OK
  return 0
}

# glp_identity <dir>: the store identity of the repo containing <dir>. The
# git common dir decides: if it ends in /.git its parent is the main repo
# (so linked worktrees share the main repo's store); otherwise (submodules,
# separate git dirs) the work tree top level. Both that root and $HOME/code
# are canonicalized (cd -P), and the root must lie strictly below ~/code on a
# path-component boundary. Sets GLP_ROOT and GLP_REL. Returns 0 inside,
# 1 outside ~/code or unresolvable (callers then scan without a private
# store).
glp_identity() {
  local common root code
  GLP_REL=""
  GLP_ROOT=""
  common="$(git -C "$1" rev-parse --path-format=absolute --git-common-dir 2>/dev/null)" || return 1
  [[ -n "$common" ]] || return 1
  case "$common" in
    */.git) root="${common%/.git}" ;;
    *) root="$(git -C "$1" rev-parse --show-toplevel 2>/dev/null)" || return 1 ;;
  esac
  [[ -n "$root" ]] || return 1
  root="$(CDPATH='' cd -P -- "$root" 2>/dev/null && pwd -P)" || return 1
  code="$(CDPATH='' cd -P -- "${HOME-}/code" 2>/dev/null && pwd -P)" || return 1
  case "$root" in
    "$code"/?*) ;;
    *) return 1 ;;
  esac
  GLP_ROOT="$root"
  GLP_REL="${root#"$code"/}"
  return 0
}

# glp_resolve <rel>: validate and locate the private files for one repo.
# Sets GLP_STORE (the repo's store dir, if it exists), GLP_TOML and
# GLP_IGNORE (paths of validated files that exist; empty otherwise).
# Returns 0 = usable (possibly no files), 2 = error (GLP_ERR set).
glp_resolve() {
  local rel="$1" rc f out
  GLP_STORE=""
  GLP_TOML=""
  GLP_IGNORE=""
  GLP_ERR=""
  if glp_bad_rel "$rel"; then
    GLP_ERR="the repo path '$rel' contains a backslash or control character; rename the repo or exclude it"
    return 2
  fi
  glp_platform_check || return 2
  case "${OSTYPE:-}" in
    darwin*) ;;
    *) return 0 ;;
  esac
  # Fast path: no repos/ dir at all -> nothing to load (a stat error is not
  # "absent" and falls through to full validation).
  glp_lstat "$GLP_REPOS"
  [[ $? -eq 1 ]] && return 0
  glp_check_base
  rc=$?
  [[ $rc -eq 2 ]] && return 2
  [[ $rc -eq 1 ]] && return 0
  glp_walk "$GLP_REPOS" "$GLP_REPOS/$rel"
  rc=$?
  [[ $rc -eq 2 ]] && return 2
  [[ $rc -eq 1 ]] && return 0
  GLP_STORE="$GLP_REPOS/$rel"
  for f in gitleaks.toml gitleaksignore; do
    glp_check_node "$GLP_STORE/$f" file
    rc=$?
    [[ $rc -eq 1 ]] && continue
    [[ $rc -eq 2 ]] && return 2
    if [[ "$f" == gitleaks.toml ]]; then
      if ! out="$(glp_check_toml "$GLP_STORE/$f")"; then
        GLP_ERR="$GLP_STORE/$f: $out"
        return 2
      fi
      GLP_TOML="$GLP_STORE/$f"
    else
      if ! out="$(glp_check_ignore "$GLP_STORE/$f")"; then
        GLP_ERR="$GLP_STORE/$f: $out"
        return 2
      fi
      GLP_IGNORE="$GLP_STORE/$f"
    fi
  done
  return 0
}

# glp_files_digest: one line per validated private file (GLP_TOML,
# GLP_IGNORE): "<path> <md5>". Used to detect content drift between
# validation and use (md5 via macOS /sbin/md5: fast, and the threat model is
# accidental edits, not collisions). Returns 1 if a file cannot be hashed.
glp_files_digest() {
  local f h
  for f in "$GLP_TOML" "$GLP_IGNORE"; do
    [[ -n "$f" ]] || continue
    h="$("$GLP_MD5" -q -- "$f" 2>/dev/null)" || return 1
    [[ -n "$h" ]] || return 1
    printf '%s %s\n' "$f" "$h"
  done
  return 0
}

# glp_collision <toplevel>: a private gitleaks.toml replaces the repo's own
# .gitleaks.toml entirely (--config bypasses it), so a repo that has one -
# in the work tree (tracked or not) or in the index - is an error rather
# than a silently dropped config. Returns 0 = fine, 2 = collision.
glp_collision() {
  [[ -n "$GLP_TOML" ]] || return 0
  if [[ -e "$1/.gitleaks.toml" || -L "$1/.gitleaks.toml" ]] ||
    [[ -n "$(git -C "$1" ls-files -- .gitleaks.toml 2>/dev/null)" ]]; then
    GLP_ERR="the repo has its own .gitleaks.toml and a private $GLP_TOML exists; --config would silently replace the repo config (merge them or remove one)"
    return 2
  fi
  return 0
}

# glp_lookup <dir> <toplevel>: identity + resolve + collision for the repo
# containing <dir> whose scan runs from <toplevel>. Returns 0 = usable (GLP_REL
# empty when the repo is outside ~/code or no store exists at all; GLP_TOML/
# GLP_IGNORE set for validated files), 2 = error (GLP_ERR set).
glp_lookup() {
  GLP_REL=""
  GLP_TOML=""
  GLP_IGNORE=""
  GLP_STORE=""
  GLP_ERR=""
  case "${OSTYPE:-}" in
    darwin*)
      glp_lstat "$GLP_REPOS"
      [[ $? -eq 1 ]] && return 0
      ;;
    *) [[ -e "$GLP_REPOS" || -L "$GLP_REPOS" ]] || return 0 ;;
  esac
  glp_identity "$1" || return 0
  glp_platform_check || return 2
  glp_resolve "$GLP_REL" || return 2
  glp_collision "$2" || return 2
  return 0
}
