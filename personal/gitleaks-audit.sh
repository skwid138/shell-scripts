#!/usr/bin/env bash
# gitleaks-audit.sh — daily gitleaks history audit of the git repos under
# ~/code, with change detection, a known-findings baseline, and a launchd
# agent (--install) that runs `--run` every day at 11:00.
#
# Default mode is a dry run: it lists the repos it would scan and why, runs
# no scans, and writes nothing to disk. Secrets never leave the private temp
# dir: gitleaks runs with --redact=100, its stdout/stderr go to private temp
# files that are never read, and the JSON report is reduced to RuleID, File,
# Commit, StartLine, Fingerprint and then deleted.
#
# Designed for launchd's minimal environment and macOS /bin/bash 3.2: builds
# its own PATH, never prompts, never uses `set -e`.

set -uo pipefail

SCRIPT_DIR="$(cd "$(dirname "${BASH_SOURCE[0]}")" && pwd)"
SCRIPT_PATH="$SCRIPT_DIR/$(basename "${BASH_SOURCE[0]}")"
# shellcheck source=../lib/common.sh
source "$SCRIPT_DIR/../lib/common.sh"

usage() {
  cat <<'EOF'
Usage: gitleaks-audit [--run | --full | --report | --install | --uninstall | --status] [--no-notify]
       gitleaks-audit --prune-delivered [--dry-run]
       gitleaks-audit --set-export-passphrase
       gitleaks-audit --export-store <dest-dir> [--plain]
       gitleaks-audit --import-store <archive>

Daily gitleaks history audit of git repositories under ~/code.

Modes:
  (none)        Dry run: list every discovered repo with what a run would do
                and why (never scanned / HEAD moved / refs changed / gitleaks
                config changed / gitleaks version changed / weekly full scan
                due / unchanged / excluded / linked worktree). No scans, no
                state or log writes.
  --run         Scan repos whose inputs changed since their last complete
                scan (all repos when the last full pass is >= 7 days old).
  --full        Like --run, but scan every repo regardless of changes.
  --report      Print current findings (reduced fields only), grouped
                repo -> rule -> file:line (commit), plus rotation guidance.
                Also lists every repo with a private store (even with 0
                findings; "stale" when the store changed since its last
                scan, "unsettled" when findings, provenance and snapshot
                disagree), repos with a repo .gitleaksignore, every
                protected entry (present / MISSING), and the delivered
                pending announcements (repo, rule, file:line, with counts;
                those whose fingerprint is already in known are marked:
                the next --run drops them).
  --prune-delivered
                Remove every delivered pending announcement (new.delivered
                and baselined.delivered rows, whether or not the
                fingerprint is in known) under the audit lock. Undelivered
                rows (including legacy count rows) are kept byte-for-byte
                and are still announced by the next --run. Never notifies
                and never settles or rewrites anything else. Afterwards a
                pruned fingerprint that is already in its repo's known stays
                known (never re-announced); one that is not reappears as NEW
                if the repo has a known file, or is baselined if it has
                none. Exit 0 (also when
                there is nothing to prune), 75 when another run holds the
                lock, 1 on a read/write/chmod/rename/log/lock failure (the
                pending file is left byte-identical).
  --prune-delivered --dry-run
                Preview what --prune-delivered would remove: no lock, log,
                state, settlement, or notification writes.
  --install     Render the launchd template into
                ~/Library/LaunchAgents/com.skwid138.gitleaks-audit.plist and
                bootstrap it (runs --run daily at 11:00; not started now).
  --uninstall   Boot out the agent (absent = OK) and remove the plist.
  --status      Show whether the agent is loaded, the plist path, and the
                last run summary.
  -h, --help    Show this help.

Store backup and restore (the private suppression store: repos/,
protected, and config under ~/.config/gitleaks-audit):
  --set-export-passphrase
                Store the export passphrase in your keychain (needs a
                terminal: `security add-generic-password -U -s
                gitleaks-audit-export -a $USER -w`, so security prompts for
                it twice and it never appears in argv). A new item goes to
                your default keychain, the local file-based login keychain;
                with -U an existing matching item anywhere in the keychain
                search list is updated where it is. A `security` CLI generic
                password lives in that file-based login keychain, not in
                iCloud Keychain (which syncs through the Passwords app), so
                it does not sync to your other devices: keep a copy of the
                passphrase off this Mac (e.g. in a password manager) or the
                encrypted archives are unreadable after losing this Mac.
  --export-store <dest-dir> [--plain]
                Write a backup archive of the store into <dest-dir> (an
                existing real directory you own; not a symlink). The whole
                store is validated first, independent of repo discovery
                (only directories and repos/<rel>/gitleaks.toml|gitleaksignore
                under repos/, every file's grammar, and the owner/mode/ACL
                checks); anything unexpected, or a member name longer than
                100 bytes, is an error and nothing is written. The archive
                (ustar + gzip, with a MANIFEST of sha256 sums) is encrypted
                with `openssl enc -aes-256-cbc -pbkdf2 -iter 600000` using the
                keychain passphrase (looked up before the audit lock is taken;
                passed on a file descriptor, never in argv or the
                environment) and published atomically as
                <dest-dir>/gitleaks-store-<UTC stamp>.tar.gz.enc (-2 ... -99
                if taken), mode 600 with no ACL; the path and its sha256 are
                printed. --plain skips encryption (.tar.gz): it is a
                plaintext copy of sensitive metadata. Runs under the audit
                lock (75 when busy).
  --import-store <archive>
                Verify an archive and unpack it into
                ~/.config/gitleaks-audit/restore-<UTC stamp>/ for a manual
                install; the live repos/, protected, and config are never
                touched (no audit lock). Encrypted archives (.enc or a
                Salted__ header) use the keychain passphrase, else a terminal
                prompt (no terminal = error). Decrypted and decompressed sizes
                are capped at 6 MiB; every tar header is checked (ustar
                regular files and directories only, allowlisted names, no
                links, no '..', no duplicates, NUL padding) before anything
                is extracted; MANIFEST must match both ways; the restored
                tree is validated like a live store. The install commands are
                printed (fresh store, or move the live repos/ and protected
                aside first, then run --full).
  What the archive holds: repo names and paths, rules, and full
  fingerprints (commit:file:rule:line) of findings including unrotated
  secrets, but never secret values. Keep it as private as the store.
  iCloud: an encrypted archive may go to iCloud Drive (standard iCloud
  encrypts it in transit and at rest, but Apple holds those keys unless
  Advanced Data Protection is on); never put the live store itself in
  iCloud or any synced folder. How iCloud Drive's File Provider treats the
  export folder (e.g. evicting local copies) is verified when the backup is
  activated. Restore scope: the store only; audit state
  is not restored, so the first scan after a restore baselines (no NEW
  notifications) and pending announcements are not restored. While
  repos/ exists without protected the audit reports a run ERROR, and
  during the manual move the hook sees no store (a commit blocked only by a
  store error may pass in that window).

Options:
  --no-notify   With --run/--full, skip the macOS notification.
  --dry-run     Only with --prune-delivered (see above).
  --plain       Only with --export-store (see above).

What a scan runs (cwd = the repo; GITLEAKS_CONFIG/GITLEAKS_CONFIG_TOML unset,
so the effective config is the repo's .gitleaks.toml/.gitleaksignore or the
gitleaks default):
  gitleaks git --redact=100 --no-banner --exit-code=10 \
    --report-format=json --report-path=<private tmp> \
    [--config <store>/gitleaks.toml] [--gitleaks-ignore-path <store>/gitleaksignore] .
The bracketed flags are added only for private store files that exist and
pass validation (see Private suppressions).
Each scan runs in its own process group under a watchdog; on timeout or
interruption the whole group gets TERM, then KILL.

Change detection: before each scan the script snapshots every ref
(`git for-each-ref`, including refs/stash), HEAD, every worktree's HEAD
(`git worktree list --porcelain`), the sha256 of the worktree .gitleaks.toml
and .gitleaksignore (or "absent") and of each file in its [extend] path chain
(depth <= 5; relative paths resolve against the repo; "missing" recorded; a
path that is not a simple one-line string without backslashes is never
decoded: the repo is logged with a WARNING and rescanned every run),
the sha256, owner and mode of each private store file and the repo's
protected manifest entries (when present), and the gitleaks version. The snapshot is persisted only after a complete scan (rc 0 or 10,
report parsed and reduced, state written) whose refs did not move mid-scan.

Discovery: directories named .git up to 3 levels below ~/code (node_modules
skipped). Linked worktrees are skipped (their history is scanned through the
main repo); submodules are scanned as their own repos.

Excludes: ~/.config/gitleaks-audit/config — one repo path per line, relative
to ~/code (# comments and blank lines ignored). Absent = no excludes. Present
but unreadable = error (nothing scanned).

Private suppressions (this machine only; shared with gitleaks-hook.sh, never
committed to the scanned repos):
  ~/.config/gitleaks-audit/repos/<rel>/gitleaks.toml   -> --config
  ~/.config/gitleaks-audit/repos/<rel>/gitleaksignore  -> --gitleaks-ignore-path
  ~/.config/gitleaks-audit/protected                   rotate-first findings
<rel> is the repo's path under ~/code. Every run validates each repo's store
BEFORE deciding whether the repo is unchanged: every path from $HOME down to
each file must be a real (non-symlink) directory/file owned by you, not
group/other writable, with no ACL entry letting anyone else write (deny
entries are fine; unrecognized ACL lines fail closed; paths above $HOME are
not checked). gitleaks.toml must be `[extend] useDefault = true` plus
[[allowlists]] blocks that each target exactly one rule with condition "AND",
one-line arrays of fully anchored single-quoted paths and line regexes (a
strict RE2 subset: ^...$ with no quantified or mid-pattern anchor and only
the exact optional prefix ^\n?, whitelisted escapes only (no \Q..\E), no
unescaped . or negated [^...] classes, only (...) and (?:...) groups, no
top-level |; how narrow a pattern is stays a review responsibility), and
regexTarget "line"; gitleaksignore may hold only full-SHA history
fingerprints (<40-hex commit>:<file>:<rule>:<line>). A repo with its own
.gitleaks.toml cannot also have a private gitleaks.toml. Any violation is an
ERROR for that repo: it is not scanned, none of its state is written, other
repos continue, and the run exits 1 (daily, until fixed; it also keeps a
weekly full pass incomplete). A repaired store is rescanned without any ref
change. The repo's own .gitleaksignore and inline `gitleaks:allow` stay
trusted (--report flags repos with a repo .gitleaksignore).
The protected manifest lists `<rel> <full fingerprint>` per line (# comments
and blank lines ignored). It is required whenever repos/ exists (missing or
invalid = a run ERROR; scans still run) and is validated like the store.
Every run checks every entry: against the fresh results of a scanned repo,
or the accepted findings of an unchanged one. A protected fingerprint that
is missing (e.g. suppressed) is an ERROR and keeps that repo's snapshot from
advancing; an entry whose repo is excluded, missing, or not discovered is an
ERROR. Each scan publishes a provenance file (the findings hash, the hash of
the input snapshot it read, and the private file hashes it used) together
with its findings, before the snapshot. A repo counts as unchanged only when
findings, provenance and snapshot agree and no publication is open (each
publication is bracketed by a `publishing` marker); otherwise (an
interrupted publication, a held-back snapshot, or state from before
provenance existed) it is rescanned as "unsettled". Baselined/NEW
fingerprints are recorded in the pending announcement file before they are
merged into known, and NEW means "in neither known nor pending", so a
process crash or a failed state write never loses or repeats one. Limits:
a crash after a notification is shown but before the pending file is
rewritten re-announces it once; a failed pending-file write after a
notification has been shown may repeat that announcement once (the run
exits 1); state files are not fsync'ed, so a power loss can lose or repeat
an announcement. After each scan the store is
validated again:
if it no longer validates, nothing is published for that repo (ERROR); a
protected manifest edited during the scan keeps the snapshot from advancing.
Private suppressions require macOS (BSD stat and ACLs).

Baseline: the first complete scan of a repo records its findings as known and
the notification says "N existing findings in M repos baselined — run
`gitleaks-audit.sh --report`". Afterwards only NEW fingerprints and errors
notify; clean or known-only runs are silent. A baseline/NEW announcement
whose notification is not delivered (osascript missing or failing, or
--no-notify) is kept in the state dir and retried by every later --run until
delivered. The pending file (600, in the 700 state dir) holds one line per
fingerprint: kind, repo path, and the fingerprint (commit, file path, rule,
line; never a secret value). A delivered entry whose fingerprint did not
reach known (its publication failed) stays, marked delivered, so it is
neither announced again nor reported as NEW; it is dropped once that repo's
known has it. If it never does (the finding disappeared or was suppressed
before the repo recovered, or the repo was excluded or removed), it is kept
indefinitely on purpose, so a later reappearance is not reported as NEW
(--report lists them; --prune-delivered removes them). Dry runs read state (pending
announcement counts, the last full scan time, repo snapshots) to show what
--run would do, but never write, merge, or clear it, even when they fail.

Files:
  State:  ~/Library/Application Support/gitleaks-audit (700; files 600)
  Log:    ~/Library/Logs/gitleaks-audit.log (rc and counts only; rotated
          to .1 above 1 MiB)
  Lock:   ~/Library/Caches/gitleaks-audit.lock (mkdir lock + owner pid). A
          live owner pid is busy whatever its hostname or age (exit 75; a
          notification after a day); a dead one is reclaimed. Reclaiming is
          serialized by an flock on gitleaks-audit.lock.reclaim and
          revalidated against the lock's current contents.

Requires: git, gitleaks, jq (macOS ships /usr/bin/jq), /usr/bin/perl, shasum.

Exit codes:
  0   clean, or only known findings
  10  new findings (and no errors)
  1   any error (scan error/timeout, malformed report, state or log write
      failure, discovery or config failure, a private store or protected
      manifest error, a missing protected fingerprint, or a lock infrastructure
      failure: lock parent not a writable directory, a non-directory at the
      lock path, a lock path that cannot be classified (an lstat error other
      than ENOENT, e.g. EACCES/ENOTDIR/EIO, or its perl helper failing),
      reclaim mutex file unopenable or its perl helper or flock failing, or
      a stale lock that cannot be removed); new findings are still notified
      and recorded
  2   usage error
  75  another run holds the lock, or is reclaiming it (contention only)

Environment overrides (tests/advanced use):
  GITLEAKS_AUDIT_BASE_PATH   PATH to use instead of the built-in one
  GITLEAKS_AUDIT_TIMEOUT     per-scan watchdog seconds (default 1800)
  GITLEAKS_AUDIT_KILL_GRACE  seconds between TERM and KILL (default 5)
  GITLEAKS_AUDIT_NOW         epoch seconds to use as "now"
  GITLEAKS_AUDIT_PERL        perl for process groups, the lock-path lstat and
                             the reclaim mutex (default /usr/bin/perl)
  GITLEAKS_AUDIT_NOTIFIER    notification command (default osascript)
  GITLEAKS_AUDIT_LOCK_STALE_SECS  age after which a lock with no parseable
                             owner pid is reclaimed (default 21600 = 6h)
  GITLEAKS_AUDIT_RECLAIM_WAIT  seconds to wait for the reclaim mutex (default 10)
  GITLEAKS_AUDIT_TEST_HOOK   test-only: command run at lock decision points
                             and store-export publication seams
  GITLEAKS_AUDIT_SECURITY    keychain CLI (default /usr/bin/security)
  GITLEAKS_AUDIT_OPENSSL     openssl for the store archive (default
                             /usr/bin/openssl)
  GITLEAKS_AUDIT_SECURITY_TIMEOUT  keychain lookup watchdog seconds (default 30)
  GITLEAKS_SUPPRESS_DIR      tests only: private store base dir instead of
                             ~/.config/gitleaks-audit (not a security boundary)
EOF
}

MODE="dry-run"
NOTIFY=1
PRUNE_DRY=0
PLAIN=0
STORE_ARG=""
while [[ $# -gt 0 ]]; do
  case "$1" in
    -h | --help)
      usage
      exit 0
      ;;
    --run | --full | --report | --install | --uninstall | --status | --prune-delivered | --set-export-passphrase)
      [[ "$MODE" == "dry-run" ]] || die_usage "only one mode may be given (see --help)"
      MODE="${1#--}"
      shift
      ;;
    --export-store | --import-store)
      [[ "$MODE" == "dry-run" ]] || die_usage "only one mode may be given (see --help)"
      [[ $# -ge 2 && -n "$2" ]] || die_usage "$1 needs an argument (see --help)"
      MODE="${1#--}"
      STORE_ARG="$2"
      shift 2
      ;;
    --plain)
      PLAIN=1
      shift
      ;;
    --no-notify)
      NOTIFY=0
      shift
      ;;
    --dry-run)
      PRUNE_DRY=1
      shift
      ;;
    *) die_usage "unknown argument: $1 (see --help)" ;;
  esac
done
if [[ "$PRUNE_DRY" -eq 1 && "$MODE" != "prune-delivered" ]]; then
  die_usage "--dry-run is only valid with --prune-delivered (the default mode is already a dry run)"
fi
if [[ "$PLAIN" -eq 1 && "$MODE" != "export-store" ]]; then
  die_usage "--plain is only valid with --export-store"
fi

# --- environment -------------------------------------------------------------

[[ -n "${HOME:-}" && -d "$HOME" ]] || die "HOME is unset or not a directory"
umask 077

LABEL="com.skwid138.gitleaks-audit"
SYSTEM_PATH="/usr/bin:/bin:/usr/sbin:/sbin"
export PATH="${GITLEAKS_AUDIT_BASE_PATH:-/opt/homebrew/bin:/usr/local/bin:$SYSTEM_PATH}"
TIMEOUT="${GITLEAKS_AUDIT_TIMEOUT:-1800}"
GRACE="${GITLEAKS_AUDIT_KILL_GRACE:-5}"
NOTIFIER="${GITLEAKS_AUDIT_NOTIFIER:-osascript}"
PERL="${GITLEAKS_AUDIT_PERL:-/usr/bin/perl}"
[[ "$TIMEOUT" =~ ^[0-9]+$ && "$TIMEOUT" -gt 0 ]] || die_usage "GITLEAKS_AUDIT_TIMEOUT must be a positive integer"
[[ "$GRACE" =~ ^[0-9]+$ ]] || die_usage "GITLEAKS_AUDIT_KILL_GRACE must be a non-negative integer"
# shellcheck source=../lib/gitleaks-private.sh
source "$SCRIPT_DIR/../lib/gitleaks-private.sh"

ROOT="$HOME/code"
MAX_DEPTH=3
CONFIG_FILE="$HOME/.config/gitleaks-audit/config"
STATE_DIR="$HOME/Library/Application Support/gitleaks-audit"
REPOS_DIR="$STATE_DIR/repos"
META_FILE="$STATE_DIR/meta"
LAST_RUN_FILE="$STATE_DIR/last-run"
PENDING_FILE="$STATE_DIR/pending-announce"
LOG_FILE="$HOME/Library/Logs/gitleaks-audit.log"
LOG_MAX_BYTES=1048576
LOCK_DIR="$HOME/Library/Caches/gitleaks-audit.lock"
FULL_INTERVAL=$((7 * 86400))

# Deterministic inputs: no inherited repo selection or gitleaks config.
unset GIT_DIR GIT_WORK_TREE GIT_INDEX_FILE GIT_OBJECT_DIRECTORY \
  GIT_ALTERNATE_OBJECT_DIRECTORIES GIT_COMMON_DIR GIT_NAMESPACE \
  GITLEAKS_CONFIG GITLEAKS_CONFIG_TOML
export GIT_TERMINAL_PROMPT=0 GIT_OPTIONAL_LOCKS=0

if [[ "$(id -u)" == "0" ]]; then
  die "refusing to run as root; gitleaks-audit manages per-user state and a gui/<uid> LaunchAgent"
fi

if [[ -n "${GITLEAKS_AUDIT_NOW:-}" ]]; then
  NOW="$GITLEAKS_AUDIT_NOW"
else
  NOW="$(/bin/date -u +%s)"
fi

# --- work dir, cleanup, signals ----------------------------------------------

WORK=""
LOCK_HELD=0
CUR_PGID=""
WD_PID=""
# Store export/import artifacts this run created (removed on failure only).
EXPORT_TMPFILE=""
EXPORT_SUBDIR=""
RESTORE_DIR=""

# reap_group <pgid>: TERM the whole process group, give it GRACE seconds to
# empty, then KILL it. Returns immediately if the group no longer exists.
reap_group() {
  local pg="$1" i=0 limit
  [[ -n "$pg" ]] || return 0
  kill -TERM -- "-$pg" 2>/dev/null || return 0
  limit=$((GRACE * 10))
  while kill -0 -- "-$pg" 2>/dev/null; do
    if [[ $i -ge $limit ]]; then
      kill -KILL -- "-$pg" 2>/dev/null
      i=0
      while kill -0 -- "-$pg" 2>/dev/null && [[ $i -lt 30 ]]; do
        sleep 0.1
        i=$((i + 1))
      done
      return 0
    fi
    sleep 0.1
    i=$((i + 1))
  done
  return 0
}

stop_watchdog() {
  if [[ -n "$WD_PID" ]]; then
    kill -TERM "$WD_PID" 2>/dev/null
    wait "$WD_PID" 2>/dev/null
    WD_PID=""
  fi
}

# shellcheck disable=SC2329  # invoked via trap
cleanup() {
  stop_watchdog
  if [[ -n "$CUR_PGID" ]]; then
    reap_group "$CUR_PGID"
    CUR_PGID=""
  fi
  if [[ "$LOCK_HELD" -eq 1 ]]; then
    local owner_pid=""
    owner_pid="$(sed -n 's/^pid=//p' "$LOCK_DIR/owner" 2>/dev/null)"
    if [[ "$owner_pid" == "$$" ]]; then
      rm -f "$LOCK_DIR/owner" "$LOCK_DIR/owner.tmp.$$"
      rmdir "$LOCK_DIR" 2>/dev/null
    fi
    LOCK_HELD=0
  fi
  # Only what this run created: the unique publication subdir and the file
  # it made inside it, or a restore dir it made but did not finish.
  [[ -n "$EXPORT_TMPFILE" ]] && rm -f "$EXPORT_TMPFILE"
  [[ -n "$EXPORT_SUBDIR" ]] && rmdir "$EXPORT_SUBDIR" 2>/dev/null
  [[ -n "$RESTORE_DIR" ]] && rm -rf "$RESTORE_DIR"
  [[ -n "$WORK" && -d "$WORK" ]] && rm -rf "$WORK"
}
trap cleanup EXIT
trap 'exit 130' INT
trap 'exit 143' TERM

make_work() {
  local base="${TMPDIR:-/tmp}"
  WORK="$(mktemp -d "${base%/}/gitleaks-audit.XXXXXX")" || die "cannot create private work dir"
  chmod 700 "$WORK" || die "cannot chmod work dir"
}

# --- logging -----------------------------------------------------------------

LOG_OK=0
LOG_WRITE_FAILED=0
open_log() {
  mkdir -p "$(dirname "$LOG_FILE")" 2>/dev/null
  if [[ -f "$LOG_FILE" ]]; then
    local size
    size="$(/usr/bin/stat -f %z "$LOG_FILE" 2>/dev/null || echo 0)"
    if [[ "$size" =~ ^[0-9]+$ && "$size" -gt "$LOG_MAX_BYTES" ]]; then
      mv -f "$LOG_FILE" "$LOG_FILE.1" 2>/dev/null
    fi
  fi
  if { : >>"$LOG_FILE"; } 2>/dev/null && chmod 600 "$LOG_FILE" 2>/dev/null; then
    LOG_OK=1
  else
    LOG_OK=0
    LOG_WRITE_FAILED=1
    warn "cannot write log file $LOG_FILE"
  fi
}

# log: stdout, plus the log file once open_log has run (scan modes only).
log() {
  printf '%s\n' "$*"
  [[ "$LOG_OK" -eq 1 ]] || return 0
  if ! { printf '[%s] %s\n' "$(/bin/date '+%Y-%m-%dT%H:%M:%S%z')" "$*" >>"$LOG_FILE"; } 2>/dev/null; then
    LOG_OK=0
    LOG_WRITE_FAILED=1
    warn "log write failed ($LOG_FILE)"
  fi
}

# --- lock ----------------------------------------------------------------------

LOCK_BUSY_EXIT=75
# A lock whose owner pid is alive is busy whatever its hostname or age; a
# dead owner pid is reclaimed at once. A lock with no parseable owner pid is
# reclaimed once its dir has been untouched this long: a healthy run
# publishes its owner within milliseconds of mkdir, so 6h is conservative.
# Reclamation is serialized and revalidated (see reclaim_lock).
LOCK_STALE_SECS="${GITLEAKS_AUDIT_LOCK_STALE_SECS:-21600}"
# A live holder older than this is reported by notification (hung run or a
# recycled pid), so a stuck lock never silently stops the daily audit.
LOCK_NOTIFY_SECS=86400
THIS_HOST="$(/bin/hostname 2>/dev/null || echo unknown)"
LOCK_ERR=""
LOCK_BUSY_NOTE=""
RECLAIM_FILE="$LOCK_DIR.reclaim"
RECLAIM_WAIT="${GITLEAKS_AUDIT_RECLAIM_WAIT:-10}"
TEST_HOOK="${GITLEAKS_AUDIT_TEST_HOOK:-}"
LK_STATE=""
LK_WHY=""
LK_PID=""
LK_AGE=""

# write_lock_owner: publish owner metadata atomically (tmp + rename). On
# failure the tmp file is removed and 1 is returned.
write_lock_owner() {
  local tmp="$LOCK_DIR/owner.tmp.$$"
  if { printf 'pid=%s\nhost=%s\nstarted=%s\n' "$$" "$THIS_HOST" "$(/bin/date -u +%s)" >"$tmp" &&
    mv -f "$tmp" "$LOCK_DIR/owner"; } 2>/dev/null; then
    return 0
  fi
  rm -f "$tmp" 2>/dev/null
  return 1
}

# lock_path_type: classify LOCK_DIR from ONE filesystem observation that
# does not follow symlinks: a single lstat(2) in a perl helper (errno is
# read from the call itself, never inferred). Prints one line:
#   absent          lstat failed with ENOENT (and only then)
#   dir             a directory
#   other           anything else (regular file, symlink - dangling or not -,
#                   fifo, ...)
#   error <diag>    lstat failed with any other errno (EACCES, ENOTDIR, EIO,
#                   ...), or the helper failed to run or printed anything
#                   unexpected; never treated as absent
# It runs in a command substitution, so it cannot set LOCK_ERR: the
# diagnosis travels in the output. Callers use the printed type and never
# stat the path again: a holder can release its dir between two separate
# tests (-e then -d), which would make a normal release look like a
# non-directory in the way.
lock_path_type() {
  local out rc
  # shellcheck disable=SC2016 # perl code: $!/$ARGV are perl variables
  out="$(LC_ALL=C "$PERL" -e 'use Errno; my @s = lstat($ARGV[0]); unless (@s) { if ($!{ENOENT}) { print "absent\n" } else { printf "error %s (errno %d)\n", $!, $! + 0 } exit 0 } print((-d _) ? "dir\n" : "other\n"); exit 0' "$LOCK_DIR" 2>/dev/null)"
  rc=$?
  if [[ $rc -ne 0 ]]; then
    echo "error lstat helper $PERL failed (exit $rc)"
    return
  fi
  case "$out" in
    *$'\n'*) echo "error lstat helper $PERL gave unexpected output" ;;
    absent | dir | other | "error "?*) echo "$out" ;;
    *) echo "error lstat helper $PERL gave unexpected output" ;;
  esac
}

# lock_path_blocked: set LOCK_ERR and return 0 when a failed mkdir of the
# lock dir is an infrastructure failure, judged only from conditions that
# contention cannot produce: the parent is not a writable, searchable
# directory, a non-directory (file, symlink) sits at the lock path, or the
# lock path cannot be classified (lstat error other than ENOENT, or helper
# failure). Runs only ever create and remove the lock as a plain directory,
# so none of these states is a holder's. Sets LOCK_PATH_TYPE (lock_path_type's
# single observation: absent|dir|other|error) for the caller; the
# lock-classify test hook runs right after that observation.
LOCK_PATH_TYPE=""
lock_path_blocked() {
  local parent cls
  LOCK_PATH_TYPE=""
  parent="$(dirname "$LOCK_DIR")"
  if [[ ! -d "$parent" || ! -w "$parent" || ! -x "$parent" ]]; then
    LOCK_ERR="lock: cannot create $LOCK_DIR: $parent is not a writable directory (fix its permissions or remove what is in the way)"
    return 0
  fi
  cls="$(lock_path_type)"
  LOCK_PATH_TYPE="${cls%% *}"
  test_hook lock-classify
  case "$LOCK_PATH_TYPE" in
    other)
      LOCK_ERR="lock: cannot create $LOCK_DIR: a non-directory is in the way (remove it)"
      return 0
      ;;
    error)
      LOCK_ERR="lock: cannot classify $LOCK_DIR: ${cls#error } (an lstat error is never taken as an absent lock; inspect the path and its parent)"
      return 0
      ;;
  esac
  return 1
}

# take_lock: 0 = held; 1 = busy; 2 = error (LOCK_ERR set). A failed mkdir is
# an error only when lock_path_blocked says so; otherwise it is contention
# (the lock exists, or a holder released it between our mkdir and any later
# look), retried up to LOCK_MKDIR_TRIES times and then reported busy. The
# errno of a failed mkdir is never inferred from the path being absent
# afterwards. 2 also means the dir was created but the owner could not be
# published, so the lock was released again. Everything inside a dir we
# just created is ours to remove.
LOCK_MKDIR_TRIES=3
take_lock() {
  local try=0
  while :; do
    test_hook lock-mkdir
    mkdir "$LOCK_DIR" 2>/dev/null && break
    test_hook lock-mkdir-failed
    lock_path_blocked && return 2
    [[ "$LOCK_PATH_TYPE" == dir ]] && return 1
    try=$((try + 1))
    [[ $try -lt $LOCK_MKDIR_TRIES ]] || return 1
  done
  if write_lock_owner; then
    LOCK_HELD=1
    return 0
  fi
  rm -f "$LOCK_DIR/owner" "$LOCK_DIR"/owner.tmp.* 2>/dev/null
  rmdir "$LOCK_DIR" 2>/dev/null
  LOCK_ERR="lock: could not write owner metadata in $LOCK_DIR; lock released"
  return 2
}

# seconds_since <epoch>: real-clock age (never GITLEAKS_AUDIT_NOW); empty if
# the argument is not an epoch.
seconds_since() {
  [[ "$1" =~ ^[0-9]+$ ]] || return 0
  echo $(($(/bin/date -u +%s) - $1))
}

# inspect_lock: classify the CURRENT lock contents into LK_STATE:
#   absent  no lock dir
#   live    owner pid parses (any hostname: macOS hostnames change with
#           networks, and the lock lives on this machine's disk) and is alive;
#           a recycled pid also reads as live, which is the conservative side
#   stale   owner pid parses and is dead, or there is no parseable owner pid
#           and the lock dir is untouched for >= LOCK_STALE_SECS
#   fresh   no parseable owner pid, but the lock dir is younger than that
#           (a run publishes its owner within milliseconds of mkdir)
# LK_WHY describes the decision; LK_PID/LK_AGE are set for live locks.
inspect_lock() {
  local line pid="" host="" started="" age
  LK_STATE=""
  LK_WHY=""
  LK_PID=""
  LK_AGE=""
  if [[ ! -d "$LOCK_DIR" ]]; then
    LK_STATE=absent
    return
  fi
  if [[ -f "$LOCK_DIR/owner" ]]; then
    {
      while IFS= read -r line || [[ -n "$line" ]]; do
        case "$line" in
          pid=*) pid="${line#pid=}" ;;
          host=*) host="${line#host=}" ;;
          started=*) started="${line#started=}" ;;
        esac
      done <"$LOCK_DIR/owner"
    } 2>/dev/null
  fi
  if [[ "$pid" =~ ^[1-9][0-9]*$ ]]; then
    if kill -0 "$pid" 2>/dev/null || ps -p "$pid" >/dev/null 2>&1; then
      age="$(seconds_since "$started")"
      [[ -n "$age" ]] || age="$(seconds_since "$(/usr/bin/stat -f %m "$LOCK_DIR" 2>/dev/null)")"
      LK_STATE=live
      LK_PID="$pid"
      LK_AGE="$age"
      LK_WHY="held by live pid $pid (host '$host') for ${age:-?}s"
      return
    fi
    LK_STATE=stale
    LK_WHY="dead pid $pid (host '$host')"
    return
  fi
  age="$(seconds_since "$(/usr/bin/stat -f %m "$LOCK_DIR" 2>/dev/null)")"
  if [[ "$age" =~ ^[0-9]+$ && "$age" -ge "$LOCK_STALE_SECS" ]]; then
    LK_STATE=stale
    LK_WHY="no parseable owner pid (pid='${pid}' host='${host}'), untouched for ${age}s >= ${LOCK_STALE_SECS}s"
    return
  fi
  LK_STATE=fresh
  LK_WHY="no parseable owner pid (pid='${pid}' host='${host}'), untouched ${age:-?}s < ${LOCK_STALE_SECS}s"
}

# Reclaim mutex: an exclusive flock on RECLAIM_FILE held through fd 9 of this
# shell (perl takes it on the inherited descriptor and exits; the lock lives
# as long as fd 9 is open). The kernel drops it when this process dies, so a
# crashed reclaimer never wedges later runs and no stale timeout is needed.
# RECLAIM_FILE is never deleted (unlinking a flocked file breaks exclusion).
# Returns 0 = held; 1 = another reclaimer held it for RECLAIM_WAIT seconds
# (contention: the helper's exit 3); 2 = infrastructure failure (LOCK_ERR
# set): the file cannot be opened, flock fails with an errno other than
# EWOULDBLOCK, or the helper is missing or fails.
reclaim_mutex_take() {
  local rc
  if ! { exec 9>>"$RECLAIM_FILE"; } 2>/dev/null; then
    LOCK_ERR="lock: cannot open reclaim mutex file $RECLAIM_FILE; stale lock $LOCK_DIR left in place"
    return 2
  fi
  # Helper exits: 0 held; 3 still EWOULDBLOCK at the deadline (contention);
  # 4 flock failed with any other errno; 2 fd 9 unusable.
  # shellcheck disable=SC2016 # perl code: $f/$!/$ARGV are perl variables
  "$PERL" -e 'use Fcntl qw(:flock); use Errno; open(my $f, ">&=", 9) or exit 2; my $end = time + $ARGV[0]; until (flock($f, LOCK_EX | LOCK_NB)) { unless ($!{EWOULDBLOCK} || $!{EAGAIN}) { print STDERR "flock: $!\n"; exit 4 } exit 3 if time >= $end; select(undef, undef, undef, 0.05) } exit 0' "$RECLAIM_WAIT"
  rc=$?
  [[ $rc -eq 0 ]] && return 0
  exec 9>&-
  [[ $rc -eq 3 ]] && return 1
  if [[ $rc -eq 4 ]]; then
    LOCK_ERR="lock: reclaim mutex flock on $RECLAIM_FILE failed (exit 4: an error other than EWOULDBLOCK); stale lock $LOCK_DIR left in place"
  else
    LOCK_ERR="lock: reclaim mutex helper $PERL failed (exit $rc); stale lock $LOCK_DIR left in place"
  fi
  return 2
}

reclaim_mutex_release() { exec 9>&-; }

# test_hook <phase> [path]: test-only seam to pause at a decision point
# (runs with fd 9 closed so a paused hook never holds the reclaim mutex
# itself). Store publication seams pass the path they are about.
test_hook() {
  [[ -n "$TEST_HOOK" ]] || return 0
  "$TEST_HOOK" "$@" </dev/null >/dev/null 2>&1 9>&-
  return 0
}

# reclaim_lock: serialized reclamation. Under the reclaim mutex, re-inspect
# the CURRENT lock and remove it only if it is still stale (a contender may
# have reclaimed and re-taken it since our first look). Release the mutex,
# then take the lock by plain mkdir: whoever loses that is busy.
# Return codes as take_lock (0 held, 1 busy, 2 error with LOCK_ERR set).
reclaim_lock() {
  reclaim_mutex_take
  case $? in
    0) ;;
    1)
      log "lock: another run is reclaiming $LOCK_DIR; skipping run"
      return 1
      ;;
    *) return 2 ;;
  esac
  test_hook reclaim-locked
  inspect_lock
  case "$LK_STATE" in
    stale)
      log "lock: reclaiming stale lock $LOCK_DIR ($LK_WHY)"
      rm -f "$LOCK_DIR/owner" "$LOCK_DIR"/owner.tmp.* 2>/dev/null
      # Under the mutex nobody else may touch a stale lock (its owner is
      # dead and contenders only mkdir), so a failed rmdir of a lock that is
      # still there is an infrastructure problem, not contention.
      if ! rmdir "$LOCK_DIR" 2>/dev/null && [[ "$(lock_path_type)" != absent ]]; then
        reclaim_mutex_release
        LOCK_ERR="lock: cannot remove stale lock $LOCK_DIR ($LK_WHY): rmdir failed (unexpected contents or permissions; inspect and remove it by hand)"
        return 2
      fi
      ;;
    absent) ;;
    *)
      reclaim_mutex_release
      log "lock: $LOCK_DIR is no longer stale ($LK_WHY); skipping run"
      return 1
      ;;
  esac
  reclaim_mutex_release
  take_lock
  case $? in
    0) return 0 ;;
    1)
      log "lock: a concurrent run took $LOCK_DIR first; skipping run"
      return 1
      ;;
    *) return 2 ;;
  esac
}

# acquire_lock: 0 = held; 1 = busy (exit 75; LOCK_BUSY_NOTE set when a live
# holder is older than LOCK_NOTIFY_SECS); 2 = lock infrastructure error
# (exit 1; LOCK_ERR set): lock parent not a writable directory, a
# non-directory at the lock path, owner publish failed, the reclaim mutex
# file/helper/flock failed, or a stale lock could not be removed.
acquire_lock() {
  local rc
  mkdir -p "$(dirname "$LOCK_DIR")" 2>/dev/null
  lock_path_blocked && return 2
  take_lock
  rc=$?
  [[ $rc -eq 1 ]] || return $rc
  inspect_lock
  case "$LK_STATE" in
    absent)
      # Released between our mkdir and the inspection: one more plain try.
      take_lock
      rc=$?
      [[ $rc -eq 1 ]] && log "lock: $LOCK_DIR was re-taken by a concurrent run; skipping run"
      return $rc
      ;;
    live)
      log "lock: $LK_WHY; skipping run"
      if [[ "$LK_AGE" =~ ^[0-9]+$ && "$LK_AGE" -ge "$LOCK_NOTIFY_SECS" ]]; then
        LOCK_BUSY_NOTE="lock held by pid $LK_PID for $((LK_AGE / 3600))h; audit not running - see ~/Library/Logs/gitleaks-audit.log"
      fi
      return 1
      ;;
    stale)
      test_hook reclaim-decided
      reclaim_lock
      return $?
      ;;
    *)
      log "lock: $LOCK_DIR exists with $LK_WHY; skipping run"
      return 1
      ;;
  esac
}

# --- process-group runner ----------------------------------------------------

# run_group <dir> <stdout-file> <stderr-file> <cmd...>: run cmd with cwd=dir
# in a NEW process group (perl setpgrp + exec; bash 3.2 has no setsid and
# there is no TTY for job control) under a watchdog. Returns cmd's rc, or 124
# if the watchdog fired. Afterwards the whole group is reaped (TERM, then
# KILL), so descendants cannot outlive the scan even if the leader exited.
run_group() {
  local dir="$1" out="$2" err="$3" pid rc marker
  shift 3
  marker="$WORK/timeout.$RANDOM$RANDOM"
  (
    cd "$dir" || exit 126
    # shellcheck disable=SC2016 # perl code: $!/$ARGV are perl variables
    exec "$PERL" -e 'setpgrp(0, 0) or die "setpgrp: $!\n"; exec { $ARGV[0] } @ARGV or die "exec $ARGV[0]: $!\n";' "$@"
  ) >"$out" 2>"$err" </dev/null &
  pid=$!
  CUR_PGID="$pid"
  (
    sp=""
    trap 'kill "$sp" 2>/dev/null; exit 0' TERM
    sleep "$TIMEOUT" &
    sp=$!
    wait "$sp"
    : >"$marker"
    kill -TERM -- "-$pid" 2>/dev/null
    sleep "$GRACE" &
    sp=$!
    wait "$sp"
    kill -KILL -- "-$pid" 2>/dev/null
  ) >/dev/null 2>&1 </dev/null &
  WD_PID=$!
  wait "$pid" 2>/dev/null
  rc=$?
  stop_watchdog
  reap_group "$pid"
  CUR_PGID=""
  if [[ -e "$marker" ]]; then
    rm -f "$marker"
    return 124
  fi
  return "$rc"
}

# --- helpers -------------------------------------------------------------------

sha256_file() { shasum -a 256 <"$1" 2>/dev/null | awk '{print $1}'; }
repo_id() { printf '%s' "$1" | shasum -a 256 | cut -c1-16; }

# --- excludes ------------------------------------------------------------------

EXCLUDES_FILE=""
CONFIG_ERR=""
# load_excludes: normalized excludes -> $WORK/excludes. 1 = config present
# but unreadable (fatal: never scan with a silently-dropped exclude list).
load_excludes() {
  EXCLUDES_FILE="$WORK/excludes"
  : >"$EXCLUDES_FILE" || return 1
  if [[ ! -e "$CONFIG_FILE" && ! -L "$CONFIG_FILE" ]]; then
    return 0
  fi
  if [[ ! -f "$CONFIG_FILE" || ! -r "$CONFIG_FILE" ]]; then
    CONFIG_ERR="exclude config $CONFIG_FILE exists but is not a readable regular file"
    return 1
  fi
  local line
  if ! cat "$CONFIG_FILE" >"$WORK/config.raw" 2>/dev/null; then
    CONFIG_ERR="exclude config $CONFIG_FILE could not be read"
    return 1
  fi
  while IFS= read -r line || [[ -n "$line" ]]; do
    line="${line%%#*}"
    line="$(printf '%s' "$line" | sed -e 's/^[[:space:]]*//' -e 's/[[:space:]]*$//')"
    [[ -n "$line" ]] || continue
    [[ "$line" == "$ROOT/"* ]] && line="${line#"$ROOT"/}"
    while [[ "$line" == ./* ]]; do line="${line#./}"; done
    while [[ "$line" == */ ]]; do line="${line%/}"; done
    [[ -n "$line" ]] && printf '%s\n' "$line" >>"$EXCLUDES_FILE"
  done <"$WORK/config.raw"
  return 0
}

is_excluded() { grep -qxF -- "$1" "$EXCLUDES_FILE" 2>/dev/null; }

# --- discovery -----------------------------------------------------------------

DISCOVERY_ERR=""
# discover: candidate repo dirs (relative to ROOT, sorted) -> $WORK/candidates.
# Returns 1 only when nothing usable was found (fatal). A partial find error
# sets DISCOVERY_ERR and still returns 0 (the run is marked as an error).
discover() {
  local rc p
  if [[ ! -d "$ROOT" ]]; then
    DISCOVERY_ERR="$ROOT is not a directory"
    return 1
  fi
  find "$ROOT" -mindepth 1 -maxdepth $((MAX_DEPTH + 1)) \
    \( -name node_modules -prune \) -o \( -name .git -print -prune \) \
    >"$WORK/gitpaths" 2>"$WORK/find.err"
  rc=$?
  if [[ $rc -ne 0 ]]; then
    DISCOVERY_ERR="find exited $rc: $(head -n1 "$WORK/find.err" | cut -c1-200)"
  fi
  : >"$WORK/candidates.unsorted"
  while IFS= read -r p; do
    [[ -n "$p" ]] || continue
    p="${p%/.git}"
    printf '%s\n' "${p#"$ROOT"/}" >>"$WORK/candidates.unsorted"
  done <"$WORK/gitpaths"
  LC_ALL=C sort -u "$WORK/candidates.unsorted" >"$WORK/candidates"
  if [[ ! -s "$WORK/candidates" ]]; then
    DISCOVERY_ERR="${DISCOVERY_ERR:+$DISCOVERY_ERR; }no git repositories found under $ROOT (depth <= $MAX_DEPTH)"
    return 1
  fi
  return 0
}

# classify <abs>: prints "repo", "worktree <common-dir>", or "error <reason>".
classify() {
  local abs="$1" gd cd
  gd="$(git -C "$abs" rev-parse --path-format=absolute --git-dir 2>/dev/null)" || {
    echo "error not a usable git repository"
    return
  }
  cd="$(git -C "$abs" rev-parse --path-format=absolute --git-common-dir 2>/dev/null)" || {
    echo "error not a usable git repository"
    return
  }
  if [[ "$gd" != "$cd" ]]; then
    echo "worktree $cd"
  else
    echo "repo"
  fi
}

# --- snapshot ------------------------------------------------------------------

GITLEAKS_VERSION=""
EXTEND_MAX_DEPTH=5
# Fixed for the whole run (pre- and post-scan snapshots agree), different
# for every run.
RUN_NONCE="$NOW.$$.$RANDOM"

# toml_extend_path <file>: the [extend] path (or top-level dotted extend.path)
# of a gitleaks TOML config. Prints "path<TAB><value>" for a simple one-line
# basic ("...") or literal ('...') string without backslashes, "unparseable"
# when the key is present but its value is anything else (escapes,
# multi-line strings, bare values, no closing quote): those are never
# guessed at. Prints nothing if there is no extend path.
toml_extend_path() {
  awk '
    /^[[:space:]]*#/ { next }
    /^[[:space:]]*\[/ { sect = $0; sub(/#.*/, "", sect); gsub(/[[:space:]]/, "", sect); next }
    {
      line = $0
      if (sect == "[extend]" && line ~ /^[[:space:]]*path[[:space:]]*=/) ok = 1
      else if (sect == "" && line ~ /^[[:space:]]*extend[[:space:]]*\.[[:space:]]*path[[:space:]]*=/) ok = 1
      else next
      sub(/^[^=]*=[[:space:]]*/, "", line)
      q = substr(line, 1, 1)
      if ((q != "\"" && q != "\047") || substr(line, 1, 3) == q q q) { print "unparseable"; exit }
      line = substr(line, 2)
      i = index(line, q)
      v = substr(line, 1, i - 1)
      if (i == 0 || index(v, "\\") > 0) { print "unparseable"; exit }
      print "path\t" v
      exit
    }' "$1" 2>/dev/null
}

# snapshot_extends <abs> <config>: one line per [extend] hop (depth, sha256 or
# "missing", resolved path). Relative paths resolve against the repo, which is
# gitleaks' cwd for the scan. Bounded by EXTEND_MAX_DEPTH (cycles included).
snapshot_extends() {
  local abs="$1" cur="$2" depth=1 p resolved h
  while [[ $depth -le $EXTEND_MAX_DEPTH ]]; do
    [[ -f "$cur" ]] || return 0
    p="$(toml_extend_path "$cur")"
    [[ -n "$p" ]] || return 0
    if [[ "$p" != path$'\t'* ]]; then
      # Not decoded on purpose: a per-run nonce makes the fingerprint differ
      # every run, so this repo is always rescanned and no change is missed.
      printf 'extend %s unparseable rescan-every-run %s\n' "$depth" "$RUN_NONCE"
      return 0
    fi
    p="${p#path$'\t'}"
    case "$p" in
      /*) resolved="$p" ;;
      *) resolved="$abs/$p" ;;
    esac
    if [[ ! -f "$resolved" ]]; then
      printf 'extend %s missing %s\n' "$depth" "$resolved"
      return 0
    fi
    h="$(sha256_file "$resolved")"
    [[ -n "$h" ]] || return 1
    printf 'extend %s %s %s\n' "$depth" "$h" "$resolved"
    cur="$resolved"
    depth=$((depth + 1))
  done
  printf 'extend %s depth-limit\n' "$depth"
}

# snapshot <abs> <out>: the complete set of scan inputs for one repo.
snapshot() {
  local abs="$1" out="$2" f h head
  {
    printf 'gitleaks-version %s\n' "$GITLEAKS_VERSION"
    for f in .gitleaks.toml .gitleaksignore; do
      if [[ -f "$abs/$f" ]]; then
        h="$(sha256_file "$abs/$f")"
        [[ -n "$h" ]] || return 1
        printf 'config %s %s\n' "$f" "$h"
      elif [[ -e "$abs/$f" ]]; then
        printf 'config %s not-a-file\n' "$f"
      else
        printf 'config %s absent\n' "$f"
      fi
    done
    snapshot_extends "$abs" "$abs/.gitleaks.toml" || return 1
    snapshot_private || return 1
    if head="$(git -C "$abs" rev-parse --verify -q HEAD 2>/dev/null)"; then
      printf 'head %s\n' "$head"
    else
      printf 'head %s\n' "$(git -C "$abs" symbolic-ref -q HEAD 2>/dev/null || echo detached-or-unborn) unborn"
    fi
    git -C "$abs" for-each-ref --format='ref %(refname) %(objectname)' 2>/dev/null || return 1
    # Every linked worktree's HEAD (gitleaks' `git log --all` scans them, and
    # a detached commit there moves no ref). The first porcelain record is
    # the main worktree, already covered by the head line above.
    git -C "$abs" worktree list --porcelain 2>/dev/null |
      awk '/^worktree /{ n++; w = substr($0, 10) } /^HEAD / && n > 1 { print "worktree " $2 " " w }' || return 1
  } >"$out"
}

# snapshot_private: the private store inputs of the current repo (CUR_PRIV
# is its store dir, empty when the feature is off): sha256, owner and mode of
# each private file that exists, and the hash of the repo's protected
# manifest entries. Nothing is printed when there is neither, so snapshots of
# repos without a store keep their pre-store form.
snapshot_private() {
  local f h rc
  if [[ -n "$CUR_PRIV" ]]; then
    for f in gitleaks.toml gitleaksignore; do
      glp_lstat "$CUR_PRIV/$f"
      rc=$?
      [[ $rc -eq 1 ]] && continue
      [[ $rc -eq 0 ]] || return 1
      h="$(sha256_file "$CUR_PRIV/$f")"
      [[ -n "$h" ]] || return 1
      printf 'private %s %s uid=%s mode=%s\n' "$f" "$h" "$GLP_ST_UID" "$GLP_ST_MODE"
    done
  fi
  [[ -n "$CUR_PROT_HASH" ]] && printf 'protected %s\n' "$CUR_PROT_HASH"
  return 0
}

# change_reason <old> <new>: comma list of what changed; empty = unchanged.
change_reason() {
  local old="$1" new="$2" r=""
  if [[ ! -f "$old" ]]; then
    echo "never scanned"
    return
  fi
  cmp -s "$old" "$new" && return 0
  [[ "$(grep '^gitleaks-version ' "$old")" == "$(grep '^gitleaks-version ' "$new")" ]] || r="$r, gitleaks version changed"
  [[ "$(grep -E '^(config|extend) ' "$old")" == "$(grep -E '^(config|extend) ' "$new")" ]] || r="$r, gitleaks config changed"
  [[ "$(grep '^head ' "$old")" == "$(grep '^head ' "$new")" ]] || r="$r, HEAD moved"
  [[ "$(grep '^ref ' "$old")" == "$(grep '^ref ' "$new")" ]] || r="$r, refs changed"
  [[ "$(grep '^worktree ' "$old")" == "$(grep '^worktree ' "$new")" ]] || r="$r, worktree HEADs changed"
  [[ "$(grep -E '^(private|protected) ' "$old")" == "$(grep -E '^(private|protected) ' "$new")" ]] || r="$r, private suppressions changed"
  [[ -n "$r" ]] || r=", inputs changed"
  echo "${r#, }"
}

# --- report reduction ----------------------------------------------------------

# Keep only the five non-secret fields; reject anything that is not an array
# of findings carrying all of them with the expected types.
JQ_REDUCE='if type != "array" then error("report is not a JSON array") else .[] | if ((.RuleID|type) == "string" and (.File|type) == "string" and (.Commit|type) == "string" and (.StartLine|type) == "number" and (.Fingerprint|type) == "string") then [.RuleID, .File, .Commit, (.StartLine|tostring), .Fingerprint] | @tsv else error("finding is missing a required field") end end'

# --- state ---------------------------------------------------------------------

STATE_OK=1
ensure_state_dir() {
  mkdir -p "$REPOS_DIR" 2>/dev/null &&
    chmod 700 "$STATE_DIR" "$REPOS_DIR" 2>/dev/null
}

meta_get() { sed -n "s/^$1=//p" "$META_FILE" 2>/dev/null | tail -n1; }

# meta_set <key> <value>: atomic rewrite of the meta file.
meta_set() {
  local tmp="$META_FILE.tmp.$$"
  {
    grep -v "^$1=" "$META_FILE" 2>/dev/null
    printf '%s=%s\n' "$1" "$2"
  } >"$tmp" 2>/dev/null && mv -f "$tmp" "$META_FILE" 2>/dev/null
}

# --- private suppressions -------------------------------------------------------

PRIV_ON=0    # 1 when the private store or the protected manifest exists
PROT_OK=0    # 1 when the protected manifest was validated and loaded
PROT_FILE="" # "<rel>\t<fingerprint>" lines (sorted, unique)
PROT_SEEN="" # rels evaluated this run (scanned, skipped, or errored)
PRIV_INIT_ERR=""
CUR_PRIV="" # the current repo's store dir ($GLP_REPOS/<rel>) when PRIV_ON
CUR_TOML="" # validated private files of the current repo (or empty)
CUR_IGNORE=""
CUR_PROT_HASH="" # hash of the current repo's protected entries (or empty)

# priv_init: detect the feature and load the protected manifest. Both the
# store (repos/) and the manifest absent = feature off. Returns 1 (with
# PRIV_INIT_ERR) when repos/ exists without a manifest, or the manifest fails
# validation; protected checks are then skipped for this run (a run error).
priv_init() {
  local rc line n=0 re
  PROT_FILE="$WORK/protected"
  PROT_SEEN="$WORK/prot-seen"
  : >"$PROT_FILE"
  : >"$PROT_SEEN"
  PRIV_ON=0
  PROT_OK=0
  glp_store_present || return 0
  PRIV_ON=1
  glp_lstat "$GLP_PROTECTED"
  if [[ $? -eq 1 ]]; then
    PRIV_INIT_ERR="protected manifest $GLP_PROTECTED is missing (required whenever $GLP_REPOS exists; it may hold only comments)"
    return 1
  fi
  glp_check_base
  rc=$?
  [[ $rc -eq 0 ]] && {
    glp_check_node "$GLP_PROTECTED" file
    rc=$?
  }
  if [[ $rc -ne 0 ]]; then
    PRIV_INIT_ERR="protected manifest: ${GLP_ERR:-$GLP_PROTECTED is missing}"
    return 1
  fi
  if ! { : <"$GLP_PROTECTED"; } 2>/dev/null; then
    PRIV_INIT_ERR="protected manifest $GLP_PROTECTED is not readable"
    return 1
  fi
  # Grammar shared with the store export/import (glp_check_protected).
  local out
  if ! out="$(glp_check_protected "$GLP_PROTECTED")"; then
    PRIV_INIT_ERR="protected manifest $GLP_PROTECTED $out"
    return 1
  fi
  re='^(.+) ([0-9a-f]{40}:[^: ]+:[a-z0-9-]+:[0-9]+)$'
  : >"$WORK/protected.raw"
  while IFS= read -r line || [[ -n "$line" ]]; do
    n=$((n + 1))
    [[ "$line" =~ ^[[:space:]]*$ || "$line" =~ ^[[:space:]]*# ]] && continue
    if [[ "$line" =~ $re ]]; then
      printf '%s\t%s\n' "${BASH_REMATCH[1]}" "${BASH_REMATCH[2]}" >>"$WORK/protected.raw"
    else
      PRIV_INIT_ERR="protected manifest $GLP_PROTECTED line $n: expected '<rel> <40-hex-commit>:<file>:<rule>:<line>'"
      return 1
    fi
  done <"$GLP_PROTECTED"
  LC_ALL=C sort -u "$WORK/protected.raw" >"$PROT_FILE" || return 1
  PROT_MANIFEST_SHA="$(manifest_sha)"
  PROT_OK=1
  return 0
}

# manifest_sha: the protected manifest's current content hash ("absent").
PROT_MANIFEST_SHA=""
manifest_sha() {
  local h
  if [[ -f "$GLP_PROTECTED" ]]; then
    h="$(sha256_file "$GLP_PROTECTED")"
    printf '%s' "${h:-unreadable}"
  else
    printf 'absent'
  fi
}

# protected_fps <rel>: the repo's protected fingerprints. The rel is passed
# through the environment (awk -v would decode backslash escapes).
protected_fps() {
  GLP_PROT_REL="$1" awk -F'\t' '$1 == ENVIRON["GLP_PROT_REL"] { print $2 }' "$PROT_FILE" 2>/dev/null
}

protected_hash() {
  local fps
  fps="$(protected_fps "$1")"
  [[ -n "$fps" ]] || return 0
  printf '%s\n' "$fps" | shasum -a 256 | awk '{print $1}'
}

# priv_repo <abs> <rel>: validate the repo's private store (identity, chain,
# files, grammar, collision with a repo .gitleaks.toml) and set CUR_*.
# Returns 1 with GLP_ERR on any problem. Runs BEFORE the unchanged check.
priv_repo() {
  local abs="$1" rel="$2"
  CUR_PRIV=""
  CUR_TOML=""
  CUR_IGNORE=""
  CUR_PROT_HASH=""
  [[ "$PRIV_ON" -eq 1 ]] || return 0
  if ! glp_identity "$abs"; then
    GLP_ERR="cannot resolve the repo identity under $ROOT"
    return 1
  fi
  if [[ "$GLP_REL" != "$rel" ]]; then
    GLP_ERR="store identity '$GLP_REL' differs from the discovered path '$rel'"
    return 1
  fi
  glp_resolve "$rel" || return 1
  glp_collision "$abs" || return 1
  CUR_PRIV="$GLP_REPOS/$rel"
  CUR_TOML="$GLP_TOML"
  CUR_IGNORE="$GLP_IGNORE"
  [[ "$PROT_OK" -eq 1 ]] && CUR_PROT_HASH="$(protected_hash "$rel")"
  return 0
}

# protected_check <rel> <sorted-fps-file> <what>: an ERROR for each of the
# repo's protected fingerprints missing from the file. 1 if any is missing.
protected_check() {
  local rel="$1" fps="$2" what="$3" f missing=0
  [[ "$PROT_OK" -eq 1 ]] || return 0
  protected_fps "$rel" >"$WORK/prot.want"
  while IFS= read -r f; do
    [[ -n "$f" ]] || continue
    if ! grep -qxF -- "$f" "$fps" 2>/dev/null; then
      record_error "$rel" "protected fingerprint $f is missing from the $what (rotate first; never suppress a protected finding)"
      missing=1
    fi
  done <"$WORK/prot.want"
  return $missing
}

# protected_check_accepted <rel>: an unchanged repo is checked against the
# findings accepted by its last complete scan.
protected_check_accepted() {
  local d
  d="$REPOS_DIR/$(repo_id "$1")"
  cut -f5 "$d/findings.tsv" 2>/dev/null | LC_ALL=C sort -u >"$WORK/accepted.fps"
  protected_check "$1" "$WORK/accepted.fps" "accepted findings of its last complete scan"
}

# protected_unseen: every manifest entry must belong to a repo this run
# evaluated; excluded, missing, or undiscovered repos are errors.
protected_unseen() {
  local rel
  [[ "$PROT_OK" -eq 1 ]] || return 0
  cut -f1 "$PROT_FILE" | LC_ALL=C sort -u >"$WORK/prot.rels"
  while IFS= read -r rel; do
    [[ -n "$rel" ]] || continue
    grep -qxF -- "$rel" "$PROT_SEEN" 2>/dev/null && continue
    record_error "$rel" "protected manifest lists $rel, but that repo is excluded, missing, or not discovered under $ROOT (its protected findings cannot be checked)"
  done <"$WORK/prot.rels"
}

# provenance_body <reduced> <pre-snapshot>: the findings hash, the identity
# (sha256) of the complete input snapshot this scan read, and the hash of
# each private file it used ("absent" when there was none).
provenance_body() {
  local h s f v
  h="$(sha256_file "$1")"
  s="$(sha256_file "$2")"
  [[ -n "$h" && -n "$s" ]] || return 1
  printf 'findings %s\n' "$h"
  printf 'snapshot %s\n' "$s"
  for f in gitleaks.toml gitleaksignore; do
    v="$(awk -v f="$f" '$1 == "private" && $2 == f { print $3; exit }' "$2")"
    printf 'private %s %s\n' "$f" "${v:-absent}"
  done
}

# state_settled <state-dir>: 0 only when no publication is open (no
# `publishing` marker) and the published artifacts agree: provenance names
# the hash of findings.tsv AND of the stored snapshot. A
# crash or failure between replacing them (or a scan whose snapshot was held
# back) leaves them disagreeing, and such a repo is rescanned rather than
# trusted as unchanged. State without provenance (written before provenance
# existed) is unsettled too: one rescan settles it.
state_settled() {
  local d="$1" ph sh
  [[ ! -e "$d/publishing" ]] || return 1
  [[ -f "$d/provenance" && -f "$d/findings.tsv" && -f "$d/snapshot" ]] || return 1
  ph="$(sed -n 's/^findings //p' "$d/provenance")"
  sh="$(sed -n 's/^snapshot //p' "$d/provenance")"
  [[ -n "$ph" && "$ph" == "$(sha256_file "$d/findings.tsv")" ]] || return 1
  [[ -n "$sh" && "$sh" == "$(sha256_file "$d/snapshot")" ]] || return 1
  return 0
}

# --- scanning ------------------------------------------------------------------

N_SCANNED=0
N_SKIPPED=0
N_EXCLUDED=0
N_WORKTREES=0
N_ERRORS=0
N_NEW=0
N_NEW_REPOS=0
N_BASELINED=0
N_BASELINED_REPOS=0
ERRORS_FILE=""
RULES_FILE=""

record_error() {
  N_ERRORS=$((N_ERRORS + 1))
  printf '%s: %s\n' "$1" "$2" >>"$ERRORS_FILE"
  log "  ERROR $1: $2"
}

# scan_repo <abs> <rel> <pre-snapshot>
scan_repo() {
  local abs="$1" rel="$2" pre="$3" id dir report out err rc reduced n started post settled=1
  local fps newfps n_new known_existed=0 prot_missing=0
  local -a priv=()
  [[ -n "$CUR_TOML" ]] && priv+=(--config "$CUR_TOML")
  [[ -n "$CUR_IGNORE" ]] && priv+=(--gitleaks-ignore-path "$CUR_IGNORE")
  id="$(repo_id "$rel")"
  dir="$REPOS_DIR/$id"
  report="$WORK/report.json"
  out="$WORK/scan.out"
  err="$WORK/scan.err"
  reduced="$WORK/reduced.tsv"
  rm -f "$report" "$reduced"
  started=$SECONDS
  run_group "$abs" "$out" "$err" \
    gitleaks git --redact=100 --no-banner --exit-code=10 \
    --report-format=json --report-path="$report" ${priv[@]+"${priv[@]}"} .
  rc=$?
  # Raw gitleaks output may contain secret material: never read, just drop.
  rm -f "$out" "$err"
  N_SCANNED=$((N_SCANNED + 1))
  case "$rc" in
    0 | 10) ;;
    124)
      rm -f "$report"
      record_error "$rel" "timeout after ${TIMEOUT}s (process group killed)"
      return
      ;;
    *)
      rm -f "$report"
      record_error "$rel" "gitleaks scan error rc=$rc"
      return
      ;;
  esac
  if [[ ! -s "$report" ]]; then
    record_error "$rel" "gitleaks rc=$rc but no JSON report was written"
    return
  fi
  if ! jq -r "$JQ_REDUCE" "$report" >"$reduced" 2>/dev/null; then
    rm -f "$report" "$reduced"
    record_error "$rel" "malformed gitleaks JSON report (rc=$rc)"
    return
  fi
  rm -f "$report"
  n="$(grep -c . "$reduced")"
  if [[ "$rc" -eq 0 && "$n" -ne 0 ]] || [[ "$rc" -eq 10 && "$n" -eq 0 ]]; then
    record_error "$rel" "inconsistent gitleaks result (rc=$rc, $n findings in report)"
    return
  fi

  # Re-validate the private store: if it no longer validates, the scan may
  # have read files we would refuse, so nothing is published.
  if [[ "$PRIV_ON" -eq 1 ]] && ! priv_repo "$abs" "$rel"; then
    rm -f "$reduced"
    record_error "$rel" "private suppression store changed during the scan and no longer validates: $GLP_ERR (nothing published)"
    return
  fi

  # Did any input move while gitleaks was reading history?
  post="$WORK/post.snap"
  if ! snapshot "$abs" "$post" || ! cmp -s "$pre" "$post"; then
    settled=0
  fi
  local manifest_moved=0
  if [[ "$PROT_OK" -eq 1 && "$(manifest_sha)" != "$PROT_MANIFEST_SHA" ]]; then
    settled=0
    manifest_moved=1
  fi

  fps="$WORK/fps"
  cut -f5 "$reduced" | LC_ALL=C sort -u >"$fps"
  # Observed = known + pending (announced or about to be): a fingerprint is
  # announced once even when an earlier publication recorded it as pending
  # but failed or crashed before merging it into known.
  newfps="$WORK/newfps"
  local pend="$WORK/pend.rel" basefps="$WORK/basefps" n_base=0
  pending_fps "$rel" >"$pend"
  : >"$basefps"
  if [[ -f "$dir/known" ]]; then
    known_existed=1
    LC_ALL=C comm -23 "$fps" "$dir/known" | LC_ALL=C comm -23 - "$pend" >"$newfps"
  else
    : >"$newfps"
    LC_ALL=C comm -23 "$fps" "$pend" >"$basefps"
  fi
  n_new="$(grep -c . "$newfps")"
  n_base="$(grep -c . "$basefps")"
  protected_check "$rel" "$fps" "scan results" || prot_missing=1

  # Publication. A `publishing` marker opens it and is removed only as the
  # very last step, so a crash or failure anywhere in between leaves the
  # repo unsettled (state_settled) and it is rescanned. Order:
  #   1. marker
  #   2. announcements (baselined / NEW fingerprints) recorded durably in the
  #      pending file, per fingerprint and deduplicated, BEFORE known is
  #      merged: after a crash either the rescan still sees them as new (and
  #      re-records the same entries) or they are already pending
  #   3. known (cumulative union)
  #   4. findings.tsv, then provenance (findings hash + snapshot identity)
  #   5. snapshot (only when the inputs held still and no protected
  #      fingerprint is missing)
  #   6. marker removed
  local ok=1
  # New dirs are 700 via umask 077. Existing dirs are never chmod'ed here: a
  # write failure must surface as an error, not be papered over.
  mkdir -p "$dir" 2>/dev/null || ok=0
  if [[ $ok -eq 1 ]]; then
    { : >"$dir/publishing"; } 2>/dev/null || ok=0
  fi
  [[ $ok -eq 1 ]] && test_hook publish-start
  if [[ $ok -eq 1 ]]; then
    { printf '%s\n' "$rel" >"$dir/path.tmp" && mv -f "$dir/path.tmp" "$dir/path"; } 2>/dev/null || ok=0
  fi
  if [[ $ok -eq 1 && "$n_base" -gt 0 ]]; then
    announce_record baselined "$rel" "$basefps" || ok=0
  fi
  if [[ $ok -eq 1 && "$n_new" -gt 0 ]]; then
    announce_record new "$rel" "$newfps" || ok=0
  fi
  [[ $ok -eq 1 ]] && test_hook publish-pending
  if [[ $ok -eq 1 ]]; then
    if [[ -f "$dir/known" ]]; then
      LC_ALL=C sort -u "$fps" "$dir/known" >"$dir/known.tmp" 2>/dev/null || ok=0
    else
      LC_ALL=C sort -u "$fps" >"$dir/known.tmp" 2>/dev/null || ok=0
    fi
    [[ $ok -eq 1 ]] && { mv -f "$dir/known.tmp" "$dir/known" 2>/dev/null || ok=0; }
  fi
  [[ $ok -eq 1 ]] && test_hook publish-known
  if [[ $ok -eq 1 ]]; then
    { cp "$reduced" "$dir/findings.tsv.tmp" && provenance_body "$reduced" "$pre" >"$dir/provenance.tmp"; } 2>/dev/null || ok=0
  fi
  if [[ $ok -eq 1 ]]; then
    mv -f "$dir/findings.tsv.tmp" "$dir/findings.tsv" 2>/dev/null || ok=0
    if [[ $ok -eq 1 ]]; then
      test_hook publish-findings
      mv -f "$dir/provenance.tmp" "$dir/provenance" 2>/dev/null || ok=0
      [[ $ok -eq 1 ]] && test_hook publish-provenance
    fi
  fi
  if [[ $ok -eq 1 && $settled -eq 1 && $prot_missing -eq 0 ]]; then
    { cp "$pre" "$dir/snapshot.tmp" && mv -f "$dir/snapshot.tmp" "$dir/snapshot"; } 2>/dev/null || ok=0
  fi
  [[ $ok -eq 1 ]] && test_hook publish-snapshot
  if [[ $ok -eq 1 ]]; then
    rm -f "$dir/publishing" 2>/dev/null || ok=0
  fi
  rm -f "$dir/path.tmp" "$dir/findings.tsv.tmp" "$dir/provenance.tmp" "$dir/known.tmp" "$dir/snapshot.tmp" 2>/dev/null

  local tag=""
  if [[ "$n_base" -gt 0 ]]; then
    N_BASELINED=$((N_BASELINED + n_base))
    N_BASELINED_REPOS=$((N_BASELINED_REPOS + 1))
    tag=" (baselined)"
  fi
  if [[ "$n_new" -gt 0 ]]; then
    N_NEW=$((N_NEW + n_new))
    N_NEW_REPOS=$((N_NEW_REPOS + 1))
    tag=" (NEW)"
  fi
  log "  scanned $rel: rc=$rc findings=$n new=$n_new$tag $((SECONDS - started))s"
  if [[ "$n" -gt 0 ]]; then
    printf '%s: %s\n' "$rel" "$(cut -f1 "$reduced" | LC_ALL=C sort | uniq -c | awk '{printf "%s%s=%s", sep, $2, $1; sep = " "}')" >>"$RULES_FILE"
  fi
  if [[ $manifest_moved -eq 1 ]]; then
    log "  note $rel: the protected manifest changed during the scan; snapshot not advanced (rescans next run)"
  elif [[ $settled -ne 1 ]]; then
    log "  note $rel: refs/HEAD/config changed during the scan; snapshot not advanced (rescans next run)"
  fi
  [[ $prot_missing -eq 0 ]] || log "  note $rel: a protected fingerprint is missing; snapshot not advanced (rescans next run)"
  if [[ $ok -ne 1 ]]; then
    STATE_OK=0
    record_error "$rel" "state write failed in $dir (publication incomplete; rescanned next run)"
  fi
}

# --- notification ----------------------------------------------------------------

# send_notify <msg>: 0 only when delivered (notifications enabled, osascript
# present, and it exited 0).
send_notify() {
  [[ "$NOTIFY" -eq 1 ]] || return 1
  command -v "$NOTIFIER" >/dev/null 2>&1 || return 1
  run_group "$HOME" "$WORK/notify.out" "$WORK/notify.err" \
    "$NOTIFIER" -e "display notification \"$1\" with title \"gitleaks-audit\""
}

# announce_record <kind> <rel> <fps-file>: durably add one pending entry
# "<kind>\t<rel>\t<fingerprint>" per fingerprint (sorted, unique, so
# recording the same announcement twice after a crash is a no-op). Also
# kept in $WORK/announce for this run. 1 if the pending file can't be written.
announce_record() {
  [[ -s "$3" ]] || return 0
  GLA_KIND="$1" GLA_REL="$2" awk '{ print ENVIRON["GLA_KIND"] "\t" ENVIRON["GLA_REL"] "\t" $0 }' "$3" \
    >"$WORK/announce.add" 2>/dev/null || return 1
  if [[ -f "$PENDING_FILE" ]]; then
    LC_ALL=C sort -u "$WORK/announce.add" "$PENDING_FILE" >"$PENDING_FILE.tmp" 2>/dev/null || return 1
  else
    LC_ALL=C sort -u "$WORK/announce.add" >"$PENDING_FILE.tmp" 2>/dev/null || return 1
  fi
  mv -f "$PENDING_FILE.tmp" "$PENDING_FILE" 2>/dev/null || {
    rm -f "$PENDING_FILE.tmp" 2>/dev/null
    return 1
  }
  # Only a durably recorded announcement is announced by this run.
  cat "$WORK/announce.add" >>"$WORK/announce"
}

# Pending entry forms (tab-separated):
#   <kind> <rel> <fp>            recorded, not yet delivered (kind: new|baselined)
#   <kind>.delivered <rel> <fp>  delivered, but <fp> was not yet in that repo's
#                                known (its publication failed): never counted
#                                again, still "observed" for NEW classification
#   <kind> <count> <rel>         legacy (older versions), counted, then dropped
PENDING_LEGACY_AWK='function legacy() { return ($2 ~ /^[0-9]+$/ && $3 !~ /^[0-9a-f]+:.*:[0-9]+$/) }'

# pending_fps <rel>: every fingerprint pending for <rel> (delivered or not).
pending_fps() {
  [[ -s "$PENDING_FILE" ]] || return 0
  GLA_REL="$1" awk -F'\t' "$PENDING_LEGACY_AWK"' !legacy() && $2 == ENVIRON["GLA_REL"] { print $3 }' \
    "$PENDING_FILE" 2>/dev/null | LC_ALL=C sort -u
}

# pending_settle <delivered>: rewrite the pending file. An entry whose
# fingerprint is in its repo's known is dropped once delivered (now, with
# delivered=1, or earlier: <kind>.delivered). With delivered=1 every other
# entry becomes <kind>.delivered, and legacy entries are dropped. Returns 1
# when the file cannot be rewritten.
pending_settle() {
  local rel k
  [[ -s "$PENDING_FILE" ]] || return 0
  printf '\001\t\001\n' >"$WORK/knownset"
  awk -F'\t' "$PENDING_LEGACY_AWK"' !legacy() { print $2 }' "$PENDING_FILE" 2>/dev/null | LC_ALL=C sort -u >"$WORK/pend.rels"
  while IFS= read -r rel; do
    k="$REPOS_DIR/$(repo_id "$rel")/known"
    [[ -f "$k" ]] || continue
    GLA_REL="$rel" awk '{ print ENVIRON["GLA_REL"] "\t" $0 }' "$k" >>"$WORK/knownset" 2>/dev/null || return 1
  done <"$WORK/pend.rels"
  GLA_MARK="$1" awk -F'\t' -v OFS='\t' "$PENDING_LEGACY_AWK"'
    FNR == NR { k[$1 "\t" $2] = 1; next }
    {
      mark = (ENVIRON["GLA_MARK"] == "1")
      if (legacy()) { if (!mark) print; next }
      done = ($1 ~ /\.delivered$/)
      if (($2 "\t" $3) in k) { if (!done && !mark) print; next }
      if (mark && !done) $1 = $1 ".delivered"
      print
    }' "$WORK/knownset" "$PENDING_FILE" 2>/dev/null | LC_ALL=C sort -u >"$PENDING_FILE.tmp" || {
    rm -f "$PENDING_FILE.tmp" 2>/dev/null
    return 1
  }
  if [[ -s "$PENDING_FILE.tmp" ]]; then
    mv -f "$PENDING_FILE.tmp" "$PENDING_FILE" 2>/dev/null || return 1
  else
    rm -f "$PENDING_FILE.tmp" "$PENDING_FILE" 2>/dev/null || return 1
  fi
}

# announce_counts <kind> <file>: "<distinct findings> <distinct repos>" for
# that kind. Entries are "<kind>\t<rel>\t<fingerprint>"; the older
# "<kind>\t<count>\t<rel>" form (pending files from before) still counts.
announce_counts() {
  LC_ALL=C sort -u "$2" 2>/dev/null | awk -F'\t' -v k="$1" '
    $1 != k { next }
    {
      if ($2 ~ /^[0-9]+$/ && $3 !~ /^[0-9a-f]+:.*:[0-9]+$/) { n += $2; rel = $3 }
      else { n++; rel = $2 }
      if (!(rel in r)) { r[rel] = 1; c++ }
    }
    END { print n + 0, c + 0 }'
}

# notify: one notification for this run's announcements (baselined / NEW
# findings) merged with any still-pending ones from earlier runs, plus the
# error count. Announcements are persisted to PENDING_FILE (counts and repo
# names only) until a notification is actually delivered, so a failed or
# suppressed notification never loses a baseline or NEW announcement.
# Errors are not persisted: they are re-detected by the next run.
notify() {
  local all="$WORK/announce.all" msg="" part nn rn nb rb persist=0
  # Pending announcements are read, merged, rewritten, or cleared only by a
  # --run/--full that holds the lock. Dry runs (including their fatal paths)
  # and runs that never got the lock never touch state.
  [[ "$LOCK_HELD" -eq 1 ]] && persist=1
  # Drop delivered entries whose fingerprints have reached known since.
  if [[ $persist -eq 1 ]] && ! pending_settle 0; then
    log "  ERROR: could not update $PENDING_FILE"
    RUN_ERRORS=$((RUN_ERRORS + 1))
  fi
  : >"$all"
  [[ $persist -eq 1 && -s "$PENDING_FILE" ]] && cat "$PENDING_FILE" >>"$all" 2>/dev/null
  [[ -s "$WORK/announce" ]] && cat "$WORK/announce" >>"$all"
  read -r nn rn <<<"$(announce_counts new "$all")"
  read -r nb rb <<<"$(announce_counts baselined "$all")"
  if [[ "$nn" -gt 0 ]]; then
    msg="$nn NEW finding(s) in $rn repo(s) - run gitleaks-audit.sh --report"
  fi
  if [[ "$nb" -gt 0 ]]; then
    part="$nb existing findings in $rb repos baselined — run \`gitleaks-audit.sh --report\`"
    msg="${msg:+$msg · }$part"
  fi
  if [[ "$RUN_ERRORS" -gt 0 ]]; then
    part="$RUN_ERRORS error(s) - see ~/Library/Logs/gitleaks-audit.log"
    msg="${msg:+$msg · }$part"
  fi
  [[ -n "$msg" ]] || return 0
  if send_notify "$msg"; then
    # Delivered: settled entries are dropped; entries whose fingerprint is
    # not in known yet stay as <kind>.delivered (never announced again). If
    # this rewrite fails nothing can record the delivery, so the next run
    # repeats the announcement once (a documented exception to
    # exactly-once); the failed write is an ERROR and the run exits 1.
    if [[ $persist -eq 1 ]] && ! pending_settle 1; then
      RUN_ERRORS=$((RUN_ERRORS + 1))
      log "  ERROR: notification delivered but $PENDING_FILE could not be updated (the announcement may repeat once next run)"
    fi
    return 0
  fi
  [[ $persist -eq 1 && -s "$all" ]] || return 0
  if [[ -d "$STATE_DIR" ]] && { LC_ALL=C sort -u "$all" >"$PENDING_FILE.tmp" && mv -f "$PENDING_FILE.tmp" "$PENDING_FILE"; } 2>/dev/null; then
    log "  notification not delivered; announcement pending, retried next run ($nn new in $rn repos, $nb baselined in $rb repos)"
  else
    rm -f "$PENDING_FILE.tmp" 2>/dev/null
    RUN_ERRORS=$((RUN_ERRORS + 1))
    log "  ERROR: notification not delivered and the announcement could not be saved to $PENDING_FILE"
  fi
}

# --- modes -----------------------------------------------------------------------

require_tools() {
  local t missing=""
  for t in git gitleaks jq shasum; do
    command -v "$t" >/dev/null 2>&1 || missing="$missing $t"
  done
  [[ -x "$PERL" ]] || missing="$missing $PERL"
  [[ -z "$missing" ]] || {
    printf '%s' "${missing# }"
    return 1
  }
}

RUN_ERRORS=0
EXIT_CODE=0

# fatal_run <reason>: an error that stops the run before any scanning.
fatal_run() {
  log "ERROR: $1"
  RUN_ERRORS=1
  notify
  EXIT_CODE=1
}

do_scan_mode() { # dry-run | run | full
  local mode="$1" missing rel abs kind cls pre old reason forced="" last_full
  make_work
  ERRORS_FILE="$WORK/errors"
  RULES_FILE="$WORK/rules"
  : >"$ERRORS_FILE"
  : >"$RULES_FILE"
  if [[ "$mode" != "dry-run" ]]; then
    open_log
    acquire_lock
    case $? in
      0) ;;
      2)
        fatal_run "$LOCK_ERR"
        return
        ;;
      *)
        EXIT_CODE=$LOCK_BUSY_EXIT
        [[ -n "$LOCK_BUSY_NOTE" ]] && { send_notify "$LOCK_BUSY_NOTE" || true; }
        return
        ;;
    esac
    log "gitleaks-audit $mode starting (pid $$, bash $BASH_VERSION)"
  fi
  if ! missing="$(require_tools)"; then
    fatal_run "missing required tool(s): $missing"
    return
  fi
  GITLEAKS_VERSION="$(gitleaks version 2>/dev/null | head -n1)"
  if [[ -z "$GITLEAKS_VERSION" ]]; then
    fatal_run "gitleaks version failed"
    return
  fi
  [[ "$mode" == "dry-run" ]] || log "gitleaks $GITLEAKS_VERSION, $(git --version 2>/dev/null)"
  if [[ -s "$PENDING_FILE" ]]; then
    local pn pr pb prb
    read -r pn pr <<<"$(announce_counts new "$PENDING_FILE")"
    read -r pb prb <<<"$(announce_counts baselined "$PENDING_FILE")"
    if [[ "$mode" == "dry-run" ]]; then
      log "announcement pending from an earlier run ($pn new in $pr repos, $pb baselined in $prb repos); --run retries the notification"
    else
      log "announcement pending from an earlier run ($pn new in $pr repos, $pb baselined in $prb repos); retrying the notification at the end of this run"
    fi
  fi
  if ! load_excludes; then
    fatal_run "$CONFIG_ERR; nothing scanned"
    return
  fi
  if ! discover; then
    fatal_run "discovery failed: $DISCOVERY_ERR"
    return
  fi
  if [[ -n "$DISCOVERY_ERR" ]]; then
    log "ERROR: discovery incomplete: $DISCOVERY_ERR"
    RUN_ERRORS=$((RUN_ERRORS + 1))
  fi

  last_full="$(meta_get last_full)"
  if [[ "$mode" == "full" ]]; then
    forced="full scan requested"
  elif [[ ! "$last_full" =~ ^[0-9]+$ ]]; then
    forced="weekly full scan due (never completed)"
  elif [[ $((NOW - last_full)) -ge $FULL_INTERVAL ]]; then
    forced="weekly full scan due (last full $(((NOW - last_full) / 86400))d ago)"
  fi
  [[ -n "$forced" ]] && log "$forced: every repo will be scanned"

  if [[ "$mode" != "dry-run" ]]; then
    if ! ensure_state_dir; then
      fatal_run "cannot create state dir $STATE_DIR"
      return
    fi
  fi
  if ! priv_init; then
    log "ERROR: $PRIV_INIT_ERR"
    [[ "$mode" == "dry-run" ]] || RUN_ERRORS=$((RUN_ERRORS + 1))
  fi

  pre="$WORK/pre.snap"
  while IFS= read -r rel; do
    [[ -n "$rel" ]] || continue
    abs="$ROOT/$rel"
    if is_excluded "$rel"; then
      N_EXCLUDED=$((N_EXCLUDED + 1))
      log "$(printf '  %-9s %s' excluded "$rel")"
      continue
    fi
    cls="$(classify "$abs")"
    kind="${cls%% *}"
    case "$kind" in
      worktree)
        N_WORKTREES=$((N_WORKTREES + 1))
        log "$(printf '  %-9s %s  (linked worktree; history scanned via %s)' skip "$rel" "${cls#worktree }")"
        continue
        ;;
      error)
        if [[ "$mode" == "dry-run" ]]; then
          log "$(printf '  %-9s %s  (%s)' error "$rel" "${cls#error }")"
        else
          record_error "$rel" "${cls#error }"
        fi
        continue
        ;;
    esac
    printf '%s\n' "$rel" >>"$PROT_SEEN"
    # Private store validation comes BEFORE the unchanged check, so a store
    # that became unsafe is an error even when nothing else changed.
    if ! priv_repo "$abs" "$rel"; then
      if [[ "$mode" == "dry-run" ]]; then
        log "$(printf '  %-9s %s  (private suppression store: %s)' error "$rel" "$GLP_ERR")"
      else
        record_error "$rel" "private suppression store: $GLP_ERR"
      fi
      continue
    fi
    if ! snapshot "$abs" "$pre"; then
      if [[ "$mode" == "dry-run" ]]; then
        log "$(printf '  %-9s %s  (cannot read refs)' error "$rel")"
      else
        record_error "$rel" "cannot snapshot refs/HEAD/config"
      fi
      continue
    fi
    if grep -q '^extend [0-9]* unparseable ' "$pre"; then
      log "  WARNING $rel: .gitleaks.toml [extend] path is not a simple one-line string (escapes, multi-line, or bare value); the extended config cannot be fingerprinted, so this repo is rescanned every run"
    fi
    old="$REPOS_DIR/$(repo_id "$rel")/snapshot"
    reason="$(change_reason "$old" "$pre")"
    # Unchanged inputs are trusted only when the published state is settled.
    if [[ -z "$reason" ]] && ! state_settled "$REPOS_DIR/$(repo_id "$rel")"; then
      reason="unsettled: findings, provenance and snapshot disagree"
    fi
    if [[ -z "$reason" && -z "$forced" ]]; then
      N_SKIPPED=$((N_SKIPPED + 1))
      log "$(printf '  %-9s %s  (unchanged)' skip "$rel")"
      [[ "$mode" == "dry-run" ]] || protected_check_accepted "$rel"
      continue
    fi
    [[ -n "$reason" ]] || reason="unchanged"
    [[ -n "$forced" ]] && reason="$reason; $forced"
    if [[ "$mode" == "dry-run" ]]; then
      log "$(printf '  %-9s %s  (%s)' scan "$rel" "$reason")"
      continue
    fi
    log "$(printf '  %-9s %s  (%s)' scan "$rel" "$reason")"
    scan_repo "$abs" "$rel" "$pre"
  done <"$WORK/candidates"

  [[ "$mode" == "dry-run" ]] && return
  protected_unseen
  RUN_ERRORS=$((RUN_ERRORS + N_ERRORS))
  summarize "$forced"
}

summarize() {
  local forced="$1" total=0 nrepos=0 d
  for d in "$REPOS_DIR"/*/; do
    [[ -f "$d/findings.tsv" ]] || continue
    local c
    c="$(grep -c . "$d/findings.tsv")"
    if [[ "$c" -gt 0 ]]; then
      total=$((total + c))
      nrepos=$((nrepos + 1))
    fi
  done
  log ""
  log "== Summary =="
  log "  repos: scanned $N_SCANNED, skipped (unchanged) $N_SKIPPED, excluded $N_EXCLUDED, worktrees $N_WORKTREES, errors $RUN_ERRORS"
  log "  findings: $total known in $nrepos repos; new this run $N_NEW; baselined this run $N_BASELINED"
  if [[ -s "$RULES_FILE" ]]; then
    log "  rule counts (scanned repos with findings):"
    while IFS= read -r d; do log "    $d"; done <"$RULES_FILE"
  fi
  if [[ -s "$ERRORS_FILE" ]]; then
    log "  errors:"
    while IFS= read -r d; do log "    $d"; done <"$ERRORS_FILE"
  fi

  if [[ -n "$forced" ]]; then
    if [[ "$RUN_ERRORS" -eq 0 ]]; then
      if meta_set last_full "$NOW"; then
        log "  full pass complete; last_full advanced"
      else
        STATE_OK=0
        RUN_ERRORS=$((RUN_ERRORS + 1))
        log "  ERROR: could not write $META_FILE"
      fi
    else
      log "  full pass incomplete; last_full NOT advanced (forced again next run)"
    fi
  fi
  [[ "$LOG_WRITE_FAILED" -eq 1 ]] && RUN_ERRORS=$((RUN_ERRORS + 1))
  notify

  if [[ "$RUN_ERRORS" -gt 0 ]]; then
    EXIT_CODE=1
  elif [[ "$N_NEW" -gt 0 ]]; then
    EXIT_CODE=10
  else
    EXIT_CODE=0
  fi
  if ! printf 'finished=%s exit=%s scanned=%s skipped=%s errors=%s new=%s baselined=%s known_total=%s\n' \
    "$NOW" "$EXIT_CODE" "$N_SCANNED" "$N_SKIPPED" "$RUN_ERRORS" "$N_NEW" "$N_BASELINED" "$total" \
    >"$LAST_RUN_FILE" 2>/dev/null; then
    EXIT_CODE=1
    RUN_ERRORS=$((RUN_ERRORS + 1))
    log "  ERROR: could not write $LAST_RUN_FILE"
  fi
  log "gitleaks-audit finished: exit $EXIT_CODE"
}

# private_hashes <store-dir>: "<name> <sha256|absent>" for both private files
# as they are now (informational: --report does not trust or use them).
private_hashes() {
  local f h
  for f in gitleaks.toml gitleaksignore; do
    if [[ -n "$1" && (-e "$1/$f" || -L "$1/$f") ]]; then
      h="$(sha256_file "$1/$f")"
      printf '%s %s\n' "$f" "${h:-unreadable}"
    else
      printf '%s absent\n' "$f"
    fi
  done
}

# recorded_hashes <file> <prefix-fields>: "<name> <sha256|absent>" for both
# private files from a snapshot or provenance file (missing lines = absent).
recorded_hashes() {
  local f v
  for f in gitleaks.toml gitleaksignore; do
    v="$(awk -v f="$f" '$1 == "private" && $2 == f { print $3; exit }' "$1" 2>/dev/null)"
    printf '%s %s\n' "$f" "${v:-absent}"
  done
}

# report_flags <rel> <state-dir>: the bracketed annotations of a repo header.
# "stale": the private files now differ from the ones the last published scan
# used (per provenance; no provenance = none used). "unsettled": findings,
# provenance and snapshot disagree (state_settled), so the next run rescans.
report_flags() {
  local rel="$1" d="$2" store="$GLP_REPOS/$1" files="" flags="" cur prov
  [[ -e "$store/gitleaks.toml" || -L "$store/gitleaks.toml" ]] && files="gitleaks.toml"
  [[ -e "$store/gitleaksignore" || -L "$store/gitleaksignore" ]] && files="${files:+$files, }gitleaksignore"
  if [[ -n "$files" ]]; then
    flags=" [private: $files]"
    if ! glp_resolve "$rel" >/dev/null 2>&1; then
      flags="$flags [store ERROR: $GLP_ERR]"
    fi
  elif [[ -d "$store" ]]; then
    flags=" [private store dir: no files]"
  fi
  if [[ -f "$d/findings.tsv" || -f "$d/snapshot" || -f "$d/provenance" ]]; then
    cur="$(private_hashes "$store")"
    prov="$(recorded_hashes "$d/provenance")"
    [[ "$cur" == "$prov" ]] || flags="$flags [stale: the private store differs from what the last published scan used]"
    if ! state_settled "$d"; then
      if [[ -f "$d/provenance" ]]; then
        flags="$flags [unsettled: findings, provenance and snapshot disagree; rescanned next run]"
      else
        flags="$flags [unsettled: no provenance (scanned by an older version or interrupted); rescanned next run]"
      fi
    fi
  fi
  [[ -e "$ROOT/$rel/.gitleaksignore" ]] && flags="$flags [repo .gitleaksignore: trusted, not private]"
  printf '%s' "$flags"
}

do_report() {
  local d any=0 rel n fp c rest line rule file status flags
  make_work
  : >"$WORK/rels"
  if [[ -d "$REPOS_DIR" ]]; then
    for d in "$REPOS_DIR"/*/; do
      [[ -f "$d/path" ]] || continue
      head -n1 "$d/path" >>"$WORK/rels"
    done
  fi
  if [[ -d "$GLP_REPOS" ]]; then
    # Every repo store dir: dirs holding a private file, and leaf dirs (a
    # store dir with no files at all is listed too).
    {
      find "$GLP_REPOS" -mindepth 2 \( -name gitleaks.toml -o -name gitleaksignore \) 2>/dev/null |
        while IFS= read -r line; do printf '%s\n' "${line%/*}"; done
      find "$GLP_REPOS" -mindepth 1 -type d 2>/dev/null | while IFS= read -r line; do
        [[ -z "$(find "$line" -mindepth 1 -maxdepth 1 -type d 2>/dev/null)" ]] && printf '%s\n' "$line"
      done
    } | while IFS= read -r line; do
      printf '%s\n' "${line#"$GLP_REPOS"/}"
    done >>"$WORK/rels"
  fi
  LC_ALL=C sort -u "$WORK/rels" | while IFS= read -r rel; do
    [[ -n "$rel" ]] || continue
    d="$REPOS_DIR/$(repo_id "$rel")"
    flags="$(report_flags "$rel" "$d")"
    if [[ ! -f "$d/findings.tsv" ]]; then
      # Never published (no audit run yet, or never scanned): list it only
      # when it has a private store.
      [[ -n "$flags" ]] || continue
      printf '== %s (not scanned yet)%s\n\n' "$rel" "$flags"
      continue
    fi
    n=0
    [[ -s "$d/findings.tsv" ]] && n="$(grep -c . "$d/findings.tsv")"
    # Flags first: a repo with 0 findings is still listed when it has a
    # store, a repo .gitleaksignore, or stale/unsettled state.
    [[ "$n" -gt 0 || -n "$flags" ]] || continue
    printf '== %s (%s findings)%s\n' "$rel" "$n" "$flags"
    if [[ "$n" -gt 0 ]]; then
      LC_ALL=C sort -t$'\t' -k1,1 -k2,2 -k4,4n "$d/findings.tsv" | awk -F'\t' '
        { rule[NR] = $1; loc[NR] = $2 ":" $4 " (" substr($3, 1, 8) ")"; cnt[$1]++ }
        END {
          for (i = 1; i <= NR; i++) {
            if (rule[i] != prev) { printf "  %s (%d)\n", rule[i], cnt[rule[i]]; prev = rule[i] }
            printf "    %s\n", loc[i]
          }
        }'
    fi
    echo
  done >"$WORK/report"
  [[ -s "$WORK/report" ]] && any=1
  cat "$WORK/report"
  if [[ -f "$GLP_PROTECTED" ]] && grep -qv '^[[:space:]]*\(#\|$\)' "$GLP_PROTECTED" 2>/dev/null; then
    any=1
    echo "Protected (rotate first; never suppress) from $GLP_PROTECTED:"
    while IFS= read -r line || [[ -n "$line" ]]; do
      [[ "$line" =~ ^[[:space:]]*$ || "$line" =~ ^[[:space:]]*# ]] && continue
      rel="${line% *}"
      fp="${line##* }"
      c="${fp%%:*}"
      rest="${fp#*:}"
      n="${rest##*:}"
      rest="${rest%:*}"
      rule="${rest##*:}"
      file="${rest%:*}"
      d="$REPOS_DIR/$(repo_id "$rel")"
      if [[ ! -f "$d/findings.tsv" ]]; then
        status="not scanned yet"
      elif cut -f5 "$d/findings.tsv" | grep -qxF -- "$fp"; then
        status="present"
      else
        status="MISSING"
      fi
      printf '  %s  %s:%s %s (%s) %s\n' "$rel" "$file" "$n" "$rule" "${c:0:8}" "$status"
    done <"$GLP_PROTECTED"
    echo
  fi
  report_delivered && any=1
  if [[ "$any" -eq 0 ]]; then
    if [[ -d "$REPOS_DIR" ]]; then
      echo "no findings recorded in $STATE_DIR"
    else
      echo "no audit state yet ($STATE_DIR); run: gitleaks-audit.sh --run"
    fi
    return 0
  fi
  [[ -d "$REPOS_DIR" ]] || echo "no audit state yet ($STATE_DIR); run: gitleaks-audit.sh --run"
  cat <<'EOF'
Rotation guidance:
  1. Treat every real secret above as exposed: rotate/revoke it at the
     provider FIRST, and confirm the old value no longer works.
  2. Then clean up: remove it from the code; rewriting history is optional
     hygiene, not remediation (clones, forks, and caches keep old commits).
  3. Only for verified false positives: add the finding's fingerprint
     (<commit>:<file>:<rule>:<line>) to the repo's .gitleaksignore, or mark
     the line `gitleaks:allow`; or, privately (this machine only), add the
     full fingerprint to ~/.config/gitleaks-audit/repos/<rel>/gitleaksignore.
     Never suppress an entry of the protected manifest.
  Details for one repo (redacted): cd <repo> && gitleaks git --redact=100 -v
    [--config <store>/gitleaks.toml] [--gitleaks-ignore-path <store>/gitleaksignore] .
  (<store> = ~/.config/gitleaks-audit/repos/<rel>; pass the flags only for
  files that exist)
EOF
}

# delivered_rows <pending-file> <out>: the delivered rows of the pending file,
# one per line: "<rel>\t<kind>\t<fp>\t<in-known 0|1>". Legacy count rows are
# never delivered rows. The known sets are read per repo (as in
# pending_settle). Returns 1 when a known file cannot be read.
delivered_rows() {
  local pf="$1" out="$2" rel k
  printf '\001\t\001\n' >"$WORK/dknown"
  awk -F'\t' '$1 == "new.delivered" || $1 == "baselined.delivered" { print $2 }' "$pf" 2>/dev/null |
    LC_ALL=C sort -u >"$WORK/drels" || return 1
  while IFS= read -r rel; do
    k="$REPOS_DIR/$(repo_id "$rel")/known"
    [[ -f "$k" ]] || continue
    GLA_REL="$rel" awk '{ print ENVIRON["GLA_REL"] "\t" $0 }' "$k" >>"$WORK/dknown" 2>/dev/null || return 1
  done <"$WORK/drels"
  awk -F'\t' -v OFS='\t' '
    FNR == NR { k[$1 "\t" $2] = 1; next }
    $1 == "new.delivered" || $1 == "baselined.delivered" {
      kind = $1
      sub(/\.delivered$/, "", kind)
      print $2, kind, $3, ((($2 "\t" $3) in k) ? 1 : 0)
    }' "$WORK/dknown" "$pf" >"$out" 2>/dev/null
}

# delivered_summary <rows>: "<n> (new <a>, baselined <b>; <k> already in known)".
# delivered_list <rows>: one line per delivered row
# ("  <rel>  <rule>  <file>:<line> (<commit8>) <kind>[ note]"), sorted by
# repo, rule, file, line.
delivered_summary() {
  awk -F'\t' '{ n++; if ($2 == "new") a++; else b++; if ($4 == 1) k++ }
    END { printf "%d (new %d, baselined %d; %d already in known)", n, a, b, k }' "$1"
}
delivered_list() {
  awk -F'\t' '{
      fp = $3
      m = split(fp, p, ":")
      if (m < 4) { file = fp; rule = "?"; line = "?"; c = "?" }
      else {
        c = substr(p[1], 1, 8); line = p[m]; rule = p[m - 1]; file = p[2]
        for (i = 3; i <= m - 2; i++) file = file ":" p[i]
      }
      note = ($4 == 1) ? " [already in known: dropped by the next --run]" : ""
      printf "%s\t%s\t%s\t%012d\t  %s  %s  %s:%s (%s) %s%s\n", $1, rule, file, line + 0, $1, rule, file, line, c, $2, note
    }' "$1" | LC_ALL=C sort -t$'\t' -k1,1 -k2,2 -k3,3 -k4,4 | cut -f5-
}

# report_delivered: the --report section for delivered pending entries.
report_delivered() {
  [[ -s "$PENDING_FILE" ]] || return 1
  delivered_rows "$PENDING_FILE" "$WORK/delivered" || {
    echo "Delivered pending announcements: cannot read $PENDING_FILE or a known file"
    echo
    return 0
  }
  [[ -s "$WORK/delivered" ]] || return 1
  echo "Delivered pending announcements: $(delivered_summary "$WORK/delivered")"
  echo "  (already notified; kept so a reappearance is not reported as NEW. Remove"
  echo "   them with gitleaks-audit.sh --prune-delivered; preview with --dry-run)"
  delivered_list "$WORK/delivered"
  echo
  return 0
}

# prune_fail <message>: the --prune-delivered error path. Logs (best effort)
# and exits 1. It never notifies, settles, or touches the pending file, and
# removes nothing but the invocation-unique temp file this run created while
# holding the lock (PRUNE_TMP): never the shared pending-announce.tmp of a
# concurrent --run, and nothing at all from a preview.
PRUNE_TMP=""
prune_fail() {
  log "ERROR: $1"
  if [[ -n "$PRUNE_TMP" && "$LOCK_HELD" -eq 1 ]]; then
    rm -f "$PRUNE_TMP" 2>/dev/null
  fi
  PRUNE_TMP=""
  EXIT_CODE=1
}

# do_prune_delivered: remove every delivered pending row (both kinds,
# regardless of known), keeping every other row byte-for-byte in its
# original order. --dry-run only reads. The real run holds the audit lock,
# writes the log only before replacing the pending file, and replaces it
# atomically (tmp + chmod 600 + rename; removed when nothing is kept).
do_prune_delivered() {
  local n_rm n_keep tmp
  make_work
  if [[ "$PRUNE_DRY" -eq 0 ]]; then
    open_log
    if [[ "$LOG_OK" -ne 1 ]]; then
      prune_fail "prune-delivered: cannot write the log $LOG_FILE; nothing changed"
      return
    fi
    acquire_lock
    case $? in
      0) ;;
      2)
        prune_fail "$LOCK_ERR"
        return
        ;;
      *)
        EXIT_CODE=$LOCK_BUSY_EXIT
        return
        ;;
    esac
    log "gitleaks-audit prune-delivered starting (pid $$)"
  fi
  if [[ ! -e "$PENDING_FILE" && ! -L "$PENDING_FILE" ]]; then
    log "prune-delivered: no pending announcements ($PENDING_FILE absent); nothing to prune"
    [[ "$LOG_WRITE_FAILED" -eq 0 ]] || EXIT_CODE=1
    return
  fi
  if ! cat "$PENDING_FILE" >"$WORK/pending.orig" 2>/dev/null; then
    prune_fail "prune-delivered: cannot read $PENDING_FILE; nothing changed"
    return
  fi
  if ! delivered_rows "$WORK/pending.orig" "$WORK/delivered" ||
    ! "$PERL" -ne 'print unless /^(?:new|baselined)\.delivered\t/' "$WORK/pending.orig" >"$WORK/pending.keep" 2>/dev/null; then
    prune_fail "prune-delivered: cannot process $PENDING_FILE; nothing changed"
    return
  fi
  n_rm="$(grep -c . "$WORK/delivered")"
  n_keep="$(grep -c . "$WORK/pending.keep")"
  if [[ "$n_rm" -eq 0 ]]; then
    log "prune-delivered: no delivered entries in $PENDING_FILE; nothing to prune"
    [[ "$LOG_WRITE_FAILED" -eq 0 ]] || EXIT_CODE=1
    return
  fi
  if [[ "$PRUNE_DRY" -eq 1 ]]; then
    echo "prune-delivered --dry-run: would remove $n_rm delivered entries ($(delivered_summary "$WORK/delivered" | sed 's/^[0-9]* (//; s/)$//')); keep $n_keep"
    delivered_list "$WORK/delivered"
    return
  fi
  # Kept rows go through an invocation-unique temp file, created exclusively
  # (noclobber) while holding the lock, then renamed over the pending file.
  # The filter above (perl -n) keeps every kept row byte-for-byte, including
  # an unterminated final row.
  tmp="$PENDING_FILE.prune.$$"
  if [[ "$n_keep" -gt 0 ]]; then
    if [[ -e "$tmp" || -L "$tmp" ]]; then
      prune_fail "prune-delivered: $tmp already exists (not this run's); nothing changed"
      return
    fi
    if ! (set -C && cat "$WORK/pending.keep" >"$tmp") 2>/dev/null; then
      [[ -e "$tmp" ]] && PRUNE_TMP="$tmp"
      prune_fail "prune-delivered: cannot write $tmp; nothing changed"
      return
    fi
    PRUNE_TMP="$tmp"
    if ! chmod 600 "$tmp" 2>/dev/null; then
      prune_fail "prune-delivered: cannot chmod $tmp; nothing changed"
      return
    fi
  fi
  log "prune-delivered: removing $n_rm delivered entries ($(delivered_summary "$WORK/delivered" | sed 's/^[0-9]* (//; s/)$//')); keeping $n_keep"
  if [[ "$LOG_WRITE_FAILED" -ne 0 ]]; then
    prune_fail "prune-delivered: log write failed; nothing changed"
    return
  fi
  if [[ "$n_keep" -gt 0 ]]; then
    if ! mv -f "$tmp" "$PENDING_FILE" 2>/dev/null; then
      prune_fail "prune-delivered: cannot replace $PENDING_FILE; nothing changed"
      return
    fi
    PRUNE_TMP=""
  elif ! rm -f "$PENDING_FILE" 2>/dev/null; then
    prune_fail "prune-delivered: cannot remove $PENDING_FILE; nothing changed"
    return
  fi
  printf 'prune-delivered: removed %s delivered entries (%s); kept %s\n' "$n_rm" \
    "$(delivered_summary "$WORK/delivered" | sed 's/^[0-9]* (//; s/;.*$//')" "$n_keep"
}

# --- store backup / restore --------------------------------------------------------

SECURITY="${GITLEAKS_AUDIT_SECURITY:-/usr/bin/security}"
OPENSSL="${GITLEAKS_AUDIT_OPENSSL:-/usr/bin/openssl}"
SECURITY_TIMEOUT="${GITLEAKS_AUDIT_SECURITY_TIMEOUT:-30}"
EXPORT_SERVICE="gitleaks-audit-export"
STORE_MAX_BYTES=6291456 # decrypted and decompressed archive cap (6 MiB)
STORE_MAX_MEMBERS=2000
STORE_NAME_MAX=100 # ustar name field; the prefix field is never used
ACCT=""
EXPORT_PASS=""
STORE_ERR=""
SV_REPOS=0
SV_PROTECTED=0
SV_CONFIG=0

# store_fail <message>: report a store export/import error (stderr) and set
# the exit code. Callers return right after.
store_fail() {
  printf 'gitleaks-audit: ERROR: %s\n' "$*" >&2
  EXIT_CODE=1
}

# shq <string>: shell-quoted, for printed copy-paste commands.
shq() { printf '%q' "$1"; }

# have_tty: an interactive terminal is attached (stdin is a TTY and
# /dev/tty opens). launchd and pipelines have none.
have_tty() { [[ -t 0 ]] && { : <>/dev/tty; } 2>/dev/null; }

# utc_stamp: the run's UTC timestamp for artifact names.
utc_stamp() { /bin/date -u -r "$NOW" +%Y%m%dT%H%M%SZ; }

# ls_led_ok <path> <mode-string>: exactly one `ls -led` line (no ACL
# entries), starting with the given mode string and no ACL marker.
ls_led_ok() {
  local out
  out="$(LC_ALL=C /bin/ls -led -- "$1" 2>/dev/null)" || return 1
  [[ -n "$out" && "$out" != *$'\n'* && "${out:0:10}" == "$2" && "${out:10:1}" != "+" ]]
}

# keychain_lookup: print the export passphrase from the keychain (stdout,
# meant for a command substitution: it is never written to disk, argv, or
# the environment). security runs in its own process group under a
# SECURITY_TIMEOUT watchdog that kills the whole group. Returns security's
# exit status, or 124 on timeout.
keychain_lookup() {
  local pid wd rc
  rm -f "$WORK/keychain.timeout"
  # shellcheck disable=SC2016 # perl code: $!/$ARGV are perl variables
  "$PERL" -e 'setpgrp(0, 0) or die "setpgrp: $!\n"; exec { $ARGV[0] } @ARGV or die "exec $ARGV[0]: $!\n";' \
    "$SECURITY" find-generic-password -s "$EXPORT_SERVICE" -a "$ACCT" -w 2>"$WORK/keychain.err" </dev/null &
  pid=$!
  (
    sp=""
    trap 'kill "$sp" 2>/dev/null; exit 0' TERM
    sleep "$SECURITY_TIMEOUT" &
    sp=$!
    wait "$sp"
    : >"$WORK/keychain.timeout"
    kill -TERM -- "-$pid" 2>/dev/null
    sleep 1 &
    sp=$!
    wait "$sp"
    kill -KILL -- "-$pid" 2>/dev/null
  ) >/dev/null 2>&1 </dev/null &
  wd=$!
  wait "$pid"
  rc=$?
  kill -TERM "$wd" 2>/dev/null
  wait "$wd" 2>/dev/null
  kill -KILL -- "-$pid" 2>/dev/null
  [[ -e "$WORK/keychain.timeout" ]] && return 124
  return "$rc"
}

# get_export_passphrase <prompt-ok 0|1> <archive>: set EXPORT_PASS from the
# keychain. Exit 44 is "not found (or search failure)": with prompt-ok and
# a terminal, ask for it there (read -s, never echoed); otherwise an error.
# Any other failure or a timeout is a hard error. 0 = set; 1 = error
# (reported).
get_export_passphrase() {
  local prompt_ok="$1" archive="${2-}" rc
  if [[ ! "$SECURITY_TIMEOUT" =~ ^[0-9]+$ || "$SECURITY_TIMEOUT" -eq 0 ]]; then
    store_fail "GITLEAKS_AUDIT_SECURITY_TIMEOUT must be a positive integer"
    return 1
  fi
  [[ -n "$ACCT" ]] || ACCT="${USER:-$(id -un 2>/dev/null)}"
  EXPORT_PASS="$(keychain_lookup)"
  rc=$?
  case "$rc" in
    0)
      [[ -n "$EXPORT_PASS" ]] && return 0
      store_fail "the keychain item '$EXPORT_SERVICE' (account '$ACCT') holds an empty passphrase; set it with: gitleaks-audit.sh --set-export-passphrase"
      return 1
      ;;
    44)
      if [[ "$prompt_ok" -eq 1 ]] && have_tty; then
        printf 'export passphrase not found in the keychain; Passphrase for %s: ' "$archive" >/dev/tty
        IFS= read -r -s EXPORT_PASS </dev/tty
        printf '\n' >/dev/tty
        [[ -n "$EXPORT_PASS" ]] && return 0
        store_fail "no passphrase entered"
        return 1
      fi
      if [[ "$prompt_ok" -eq 1 ]]; then
        store_fail "export passphrase not found (or search failure; the CLI loses specificity) in the keychain (service '$EXPORT_SERVICE', account '$ACCT'), and there is no terminal to prompt for it; run this in Terminal, or set it with: gitleaks-audit.sh --set-export-passphrase"
      else
        store_fail "export passphrase not found (or search failure; the CLI loses specificity) in the keychain (service '$EXPORT_SERVICE', account '$ACCT'); set it with: gitleaks-audit.sh --set-export-passphrase"
      fi
      return 1
      ;;
    124)
      store_fail "keychain lookup timed out after ${SECURITY_TIMEOUT}s (a keychain dialog waiting for an answer?); nothing done"
      return 1
      ;;
    *)
      store_fail "keychain lookup failed (security exit $rc): $(head -n1 "$WORK/keychain.err" 2>/dev/null | cut -c1-200)"
      return 1
      ;;
  esac
}

do_set_export_passphrase() {
  [[ -n "$ACCT" ]] || ACCT="${USER:-$(id -un 2>/dev/null)}"
  if ! have_tty; then
    die "--set-export-passphrase needs an interactive terminal (security prompts for the passphrase twice itself); nothing changed"
  fi
  echo "Storing the store-export passphrase in your default (login) keychain: service '$EXPORT_SERVICE', account '$ACCT'."
  echo "security prompts for it twice; it is never passed in argv."
  # -w must stay the LAST argument, with no value: security then prompts.
  if ! "$SECURITY" add-generic-password -U -s "$EXPORT_SERVICE" -a "$ACCT" -w; then
    die "security add-generic-password failed; nothing stored"
  fi
  cat <<'EOF'
Stored in the file-based login keychain. A security CLI generic password
is not an iCloud Keychain item (iCloud Keychain syncs through the Passwords
app), so it does not sync to your other devices. Keep a copy of the
passphrase off this Mac (e.g. in a password manager), or encrypted store
archives cannot be opened after losing this Mac.
EOF
}

# store_validate <base> <live|tree>: validate a whole store independent of
# repo discovery. live: the chain from $HOME to <base> (glp_check_base);
# tree: <base> itself (a private temp tree). Then repos/ (every node: only
# directories, and regular files named gitleaks.toml or gitleaksignore at
# repos/<rel>/, every rel passing glp_valid_rel), protected and config:
# owner/mode/ACL checks on every node and the grammar of every file.
# Writes $WORK/sv.dirs (repo dir rels) and $WORK/sv.files (repos/... file
# paths), sorted, and sets SV_REPOS/SV_PROTECTED/SV_CONFIG. Returns 1 with
# STORE_ERR on the first problem.
store_validate() {
  local base="$1" kind="$2" rc p rel name parent out f
  STORE_ERR=""
  SV_REPOS=0
  SV_PROTECTED=0
  SV_CONFIG=0
  : >"$WORK/sv.dirs"
  : >"$WORK/sv.files"
  glp_ids
  if [[ "$kind" == live ]]; then
    if ! glp_platform_check; then
      STORE_ERR="$GLP_ERR"
      return 1
    fi
    glp_check_base
    rc=$?
    if [[ $rc -eq 1 ]]; then
      STORE_ERR="no private store at $base (nothing to export)"
      return 1
    fi
  else
    glp_check_node "$base" dir
    rc=$?
  fi
  if [[ $rc -ne 0 ]]; then
    STORE_ERR="${GLP_ERR:-$base is missing}"
    return 1
  fi
  glp_check_node "$base/repos" dir
  rc=$?
  case $rc in
    0) SV_REPOS=1 ;;
    1) ;;
    *)
      STORE_ERR="$GLP_ERR"
      return 1
      ;;
  esac
  for f in protected config; do
    glp_check_node "$base/$f" file
    rc=$?
    case $rc in
      0) [[ "$f" == protected ]] && SV_PROTECTED=1 || SV_CONFIG=1 ;;
      1) ;;
      *)
        STORE_ERR="$GLP_ERR"
        return 1
        ;;
    esac
  done
  if [[ $SV_REPOS -eq 0 && $SV_PROTECTED -eq 0 ]]; then
    STORE_ERR="neither repos/ nor protected exists under $base: no store"
    return 1
  fi
  if [[ $SV_PROTECTED -eq 1 ]] && ! out="$(glp_check_protected "$base/protected")"; then
    STORE_ERR="$base/protected: $out"
    return 1
  fi
  if [[ $SV_CONFIG -eq 1 ]] && ! { : <"$base/config"; } 2>/dev/null; then
    STORE_ERR="$base/config is not readable"
    return 1
  fi
  [[ $SV_REPOS -eq 1 ]] || return 0
  if ! find "$base/repos" -mindepth 1 -print0 >"$WORK/sv.find" 2>"$WORK/sv.find.err"; then
    STORE_ERR="cannot list $base/repos: $(head -n1 "$WORK/sv.find.err" | cut -c1-200)"
    return 1
  fi
  while IFS= read -r -d '' p; do
    rel="${p#"$base"/repos/}"
    glp_lstat "$p"
    rc=$?
    if [[ $rc -ne 0 ]]; then
      STORE_ERR="${GLP_ERR:-$p disappeared while validating}"
      return 1
    fi
    case "$GLP_ST_TYPE" in
      dir)
        if ! glp_valid_rel "$rel"; then
          STORE_ERR="repos/$rel is not a valid repo path (empty, '.' or '..' component, backslash, or control character)"
          return 1
        fi
        if ! glp_check_node "$p" dir; then
          STORE_ERR="$GLP_ERR"
          return 1
        fi
        printf '%s\n' "$rel" >>"$WORK/sv.dirs"
        ;;
      file)
        name="${rel##*/}"
        parent="${rel%/*}"
        if [[ "$rel" != */* || ("$name" != gitleaks.toml && "$name" != gitleaksignore) ]]; then
          STORE_ERR="unexpected file repos/$rel (a store holds only repos/<rel>/gitleaks.toml and repos/<rel>/gitleaksignore)"
          return 1
        fi
        if ! glp_valid_rel "$parent"; then
          STORE_ERR="repos/$rel: not under a valid repo path"
          return 1
        fi
        if ! glp_check_node "$p" file; then
          STORE_ERR="$GLP_ERR"
          return 1
        fi
        if [[ "$name" == gitleaks.toml ]]; then
          out="$(glp_check_toml "$p")"
        else
          out="$(glp_check_ignore "$p")"
        fi
        if [[ "$out" != OK ]]; then
          STORE_ERR="repos/$rel: $out"
          return 1
        fi
        printf 'repos/%s\n' "$rel" >>"$WORK/sv.files"
        ;;
      *)
        STORE_ERR="unexpected $GLP_ST_TYPE at repos/$rel (a store holds only directories and regular files; no symlinks)"
        return 1
        ;;
    esac
  done <"$WORK/sv.find"
  LC_ALL=C sort -o "$WORK/sv.dirs" "$WORK/sv.dirs" && LC_ALL=C sort -o "$WORK/sv.files" "$WORK/sv.files"
}

# store_members <out>: the archive member names for the validated store
# (store_validate's lists), in archive order: repos/ entries (directories
# with a trailing slash, sorted), protected, config, MANIFEST.
store_members() {
  {
    if [[ $SV_REPOS -eq 1 ]]; then
      {
        echo "repos/"
        awk '{ print "repos/" $0 "/" }' "$WORK/sv.dirs"
        cat "$WORK/sv.files"
      } | LC_ALL=C sort
    fi
    [[ $SV_PROTECTED -eq 1 ]] && echo protected
    [[ $SV_CONFIG -eq 1 ]] && echo config
    echo MANIFEST
  } >"$1"
}

# USTAR_READER: perl validator for an uncompressed archive, run BEFORE any
# extraction. Every 512-byte header must be strict ustar ("ustar\0", "00",
# a valid unsigned checksum, octal-only numeric fields, no base-256, empty
# linkname and prefix, the name ending at its first NUL with only NULs
# after it) of typeflag '0'/'\0' (regular) or '5' (directory, size 0, name
# ending in /); payload padding must be NUL; the archive must end with two
# NUL blocks followed only by NULs. Names: no absolute paths, '..' or empty
# components, no duplicates (also case- and normalization-insensitive, as
# on APFS), only allowlisted members (MANIFEST, config, protected, repos/,
# repos/<rel>/, repos/<rel>/gitleaks.toml|gitleaksignore), at most
# <max> members. Prints "f <name>" / "d <name>" per member and exits 0, or
# prints "<rule>: <detail>" and exits 1.
# shellcheck disable=SC2016 # perl code
USTAR_READER='use strict; use warnings; use feature "fc"; use Unicode::Normalize;
my ($file, $max) = @ARGV;
open(my $fh, "<", $file) or do { print "read: cannot open the archive: $!\n"; exit 2 };
binmode $fh;
my $data = do { local $/; <$fh> };
close $fh;
$data = "" unless defined $data;
my ($len, $pos, $n) = (length($data), 0, 0);
my (%seen, %folded, @out);
sub rej { print "$_[0]\n"; exit 1 }
sub shown { my $s = shift; $s =~ s/([^\x20-\x7e])/sprintf("\\x%02x", ord($1))/ge; return $s }
sub rel_ok {
  my $r = shift;
  return 0 if $r eq "" || $r =~ /[\\\x00-\x1f\x7f]/;
  for my $c (split m{/}, $r, -1) { return 0 if $c eq "" || $c eq "." || $c eq ".." }
  return 1;
}
sub num {
  my ($f, $what) = @_;
  rej("header: base-256 (binary) numeric field $what is not allowed") if ord(substr($f, 0, 1)) & 0x80;
  rej("header: malformed octal numeric field $what") unless $f =~ /\A[0-7]+[ \0]*\z/;
  my ($d) = $f =~ /\A([0-7]+)/;
  return oct($d);
}
while (1) {
  rej("truncated: the archive ends without its two end-of-archive blocks") if $pos + 512 > $len;
  my $h = substr($data, $pos, 512);
  if ($h eq ("\0" x 512)) {
    rej("truncated: the second end-of-archive block is missing") if $pos + 1024 > $len;
    rej("trailing data after the end of archive (second end block not NUL)") if substr($data, $pos + 512, 512) ne ("\0" x 512);
    rej("trailing data after the end of archive") if substr($data, $pos + 1024) =~ /[^\0]/;
    last;
  }
  my $ck = substr($h, 148, 8);
  rej("header: base-256 (binary) checksum field") if ord($ck) & 0x80;
  rej("header: malformed checksum field") unless $ck =~ /\A[0-7]+[ \0]*\z/;
  my ($ckd) = $ck =~ /\A([0-7]+)/;
  my $t = $h;
  substr($t, 148, 8) = " " x 8;
  rej("header: checksum mismatch") unless oct($ckd) == unpack("%32C*", $t);
  rej("header: magic is not \"ustar\\0\"") unless substr($h, 257, 6) eq "ustar\0";
  rej("header: version is not \"00\"") unless substr($h, 263, 2) eq "00";
  my $type = substr($h, 156, 1);
  rej("typeflag \x27" . shown($type) . "\x27 is not allowed (only regular files and directories)")
    unless $type eq "0" || $type eq "\0" || $type eq "5";
  num(substr($h, 100, 8), "mode");
  num(substr($h, 108, 8), "uid");
  num(substr($h, 116, 8), "gid");
  my $size = num(substr($h, 124, 12), "size");
  num(substr($h, 136, 12), "mtime");
  my $nf = substr($h, 0, 100);
  my $name = $nf;
  $name =~ s/\0.*\z//s;
  rej("name: bytes after the first NUL are not all NUL (hidden suffix after " . shown($name) . ")")
    if substr($nf, length($name)) =~ /[^\0]/;
  rej("name: empty") if $name eq "";
  rej("linkname is not empty: " . shown($name)) if substr($h, 157, 100) =~ /[^\0]/;
  rej("prefix is not empty (long names are not allowed): " . shown($name)) if substr($h, 345, 155) =~ /[^\0]/;
  my $isdir = $type eq "5";
  if ($isdir) {
    rej("directory entry with nonzero size: " . shown($name)) if $size != 0;
    rej("directory entry whose name does not end in /: " . shown($name)) unless $name =~ m{/\z};
  } else {
    rej("regular entry whose name ends in /: " . shown($name)) if $name =~ m{/\z};
  }
  rej("absolute path: " . shown($name)) if $name =~ m{\A/};
  my $p = $isdir ? substr($name, 0, -1) : $name;
  my @c = split m{/}, $p, -1;
  rej("\x27..\x27 path component: " . shown($name)) if grep { $_ eq ".." } @c;
  rej("empty path component: " . shown($name)) if grep { $_ eq "" } @c;
  my $ok = 0;
  if (!$isdir && ($name eq "MANIFEST" || $name eq "config" || $name eq "protected")) { $ok = 1 }
  elsif ($isdir && $name eq "repos/") { $ok = 1 }
  elsif ($isdir && $name =~ m{\Arepos/(.+)/\z}s) { $ok = rel_ok($1) }
  elsif (!$isdir && $name =~ m{\Arepos/(.+)/(?:gitleaks\.toml|gitleaksignore)\z}s) { $ok = rel_ok($1) }
  rej("member not in the allowlist: " . shown($name)) unless $ok;
  rej("duplicate member: " . shown($name)) if $seen{$name}++;
  my $u = $name;
  my $key = utf8::decode($u) ? fc(NFD($u)) : lc($name);
  rej("case-insensitive duplicate member: " . shown($name)) if $folded{$key}++;
  $n++;
  rej("too many members (more than $max)") if $n > $max;
  my $padded = $size + ((512 - $size % 512) % 512);
  rej("truncated payload: " . shown($name)) if $pos + 512 + $padded > $len;
  rej("payload padding is not all NUL: " . shown($name)) if substr($data, $pos + 512 + $size, $padded - $size) =~ /[^\0]/;
  push @out, ($isdir ? "d " : "f ") . $name;
  $pos += 512 + $padded;
}
rej("the archive has no members") unless @out;
print "$_\n" for @out;
exit 0;'

# ustar_check <raw.tar> <out-members>: run USTAR_READER. 0 = valid (members
# written); 1 = rejected (STORE_ERR names the rule); 2 = could not run.
ustar_check() {
  local rc
  "$PERL" -e "$USTAR_READER" "$1" "$STORE_MAX_MEMBERS" >"$2" 2>"$WORK/reader.err"
  rc=$?
  case $rc in
    0) return 0 ;;
    1)
      STORE_ERR="$(head -n1 "$2")"
      return 1
      ;;
    *)
      STORE_ERR="archive reader failed (exit $rc): $(head -n1 "$WORK/reader.err" 2>/dev/null | cut -c1-200)"
      return 2
      ;;
  esac
}

# Publication helpers (perl, one syscall per decision; see do_export_store).
# shellcheck disable=SC2016 # perl code
PUBLISH_MKDIR='use strict; use warnings; use Errno;
umask 077;
my ($dir, $pid) = @ARGV;
for (1 .. 50) {
  my $p = sprintf("%s/.gitleaks-export.%s.%06d", $dir, $pid, int(rand(1000000)));
  if (mkdir($p, 0700)) { print "$p\n"; exit 0 }
  die "mkdir $p: $!\n" unless $!{EEXIST};
}
die "no free staging name in $dir\n";'

# PUBLISH_WRITER <src> <dst> <hook>: create <dst> with O_CREAT|O_EXCL 0600,
# check it carries no ACL (one `ls -led` line, -rw-------) BEFORE writing,
# then write <src> into it (the file-created and mid-write test seams run
# in between), fsync and close.
# shellcheck disable=SC2016 # perl code
PUBLISH_WRITER='use strict; use warnings; use Fcntl; use IO::Handle;
my ($src, $dst, $hook) = @ARGV;
umask 077;
sub seam {
  my ($phase) = @_;
  return unless defined($hook) && length($hook);
  my $pid = fork();
  die "fork: $!\n" unless defined $pid;
  if (!$pid) {
    open(STDIN, "<", "/dev/null"); open(STDOUT, ">", "/dev/null"); open(STDERR, ">", "/dev/null");
    exec { $hook } $hook, $phase, $dst;
    exit 127;
  }
  waitpid($pid, 0);
}
sysopen(my $out, $dst, O_CREAT | O_EXCL | O_WRONLY | O_NOFOLLOW, 0600) or die "create $dst: $!\n";
open(my $ls, "-|", "/bin/ls", "-led", "--", $dst) or die "ls $dst: $!\n";
my @l = <$ls>;
close($ls);
die "$dst carries an ACL or an unexpected mode right after creation\n" unless @l == 1 && $l[0] =~ /\A-rw------- /;
seam("file-created");
open(my $in, "<", $src) or die "read $src: $!\n";
binmode $in;
my $data = do { local $/; <$in> };
close($in);
sub put {
  my ($buf) = @_;
  my $off = 0;
  while ($off < length($buf)) {
    my $w = syswrite($out, $buf, length($buf) - $off, $off);
    die "write $dst: $!\n" unless defined $w;
    $off += $w;
  }
}
my $half = int(length($data) / 2);
put(substr($data, 0, $half));
seam("mid-write");
put(substr($data, $half));
$out->sync or die "fsync $dst: $!\n";
close($out) or die "close $dst: $!\n";
exit 0;'

# PUBLISH_LINK <src> <dir> <base> <ext>: link(2) <src> to <dir>/<base><ext>,
# else <base>-2<ext> ... <base>-99<ext> on EEXIST only (link never follows
# or writes through an existing name, symlink, or directory); any other
# errno is a hard error. Prints the published path.
# shellcheck disable=SC2016 # perl code
PUBLISH_LINK='use strict; use warnings; use Errno;
my ($src, $dir, $base, $ext) = @ARGV;
for my $i (1 .. 99) {
  my $p = $dir . "/" . $base . ($i == 1 ? "" : "-$i") . $ext;
  if (link($src, $p)) { print "$p\n"; exit 0 }
  next if $!{EEXIST};
  die "link $p: $!\n";
}
die "no free name for $base$ext in $dir (tried -2 ... -99)\n";'

# export_dest_ok <dir>: an existing real directory (not a symlink, not
# dangling) owned by the current user. Sets EXPORT_DEST (absolute, no
# trailing slash) or STORE_ERR.
EXPORT_DEST=""
export_dest_ok() {
  local d="$1" rc
  while [[ "$d" == */ && "$d" != / ]]; do d="${d%/}"; done
  [[ "$d" == /* ]] || d="$PWD/$d"
  glp_ids
  glp_lstat "$d"
  rc=$?
  if [[ $rc -eq 1 ]]; then
    STORE_ERR="destination $d does not exist (create it first)"
    return 1
  elif [[ $rc -ne 0 ]]; then
    STORE_ERR="$GLP_ERR"
    return 1
  fi
  case "$GLP_ST_TYPE" in
    dir) ;;
    link)
      STORE_ERR="destination $d is a symlink (dangling or not); give the real directory"
      return 1
      ;;
    *)
      STORE_ERR="destination $d is not a directory"
      return 1
      ;;
  esac
  if [[ "$GLP_ST_UID" != "$GLP_UID" ]]; then
    STORE_ERR="destination $d is owned by uid $GLP_ST_UID, not you ($GLP_UID)"
    return 1
  fi
  EXPORT_DEST="$d"
}

# publish_artifact <file> <ext>: publish atomically into EXPORT_DEST:
#   1. a unique private subdir (perl mkdir 0700, umask 077)
#   2. chmod -N on it, verified ACL-free and 700 BEFORE anything is created
#      inside it (an inherited ACL would otherwise reach the new file)
#   3. the file inside it (O_EXCL 0600, verified ACL-free, written, fsync)
#   4. link(2) to the final name (-2 ... -99 on EEXIST)
#   5. unlink the staging file, rmdir the subdir (the EXIT trap removes
#      both on any failure)
# Prints the published path and its sha256.
publish_artifact() {
  local src="$1" ext="$2" ts sub final h
  if ! export_dest_ok "$EXPORT_DEST"; then
    store_fail "$STORE_ERR; nothing published"
    return 1
  fi
  ts="$(utc_stamp)"
  if ! sub="$("$PERL" -e "$PUBLISH_MKDIR" "$EXPORT_DEST" "$$" 2>"$WORK/publish.err")" || [[ -z "$sub" ]]; then
    store_fail "cannot create a private staging dir in $EXPORT_DEST: $(head -n1 "$WORK/publish.err"); nothing published"
    return 1
  fi
  EXPORT_SUBDIR="$sub"
  test_hook subdir-created "$sub"
  if ! chmod -N "$sub" 2>/dev/null || ! ls_led_ok "$sub" drwx------; then
    store_fail "cannot strip ACLs from the staging dir $sub (chmod -N), or it is not a private 700 dir; nothing published"
    return 1
  fi
  test_hook after-strip "$sub"
  EXPORT_TMPFILE="$sub/gitleaks-store-$ts$ext"
  if ! "$PERL" -e "$PUBLISH_WRITER" "$src" "$EXPORT_TMPFILE" "$TEST_HOOK" 2>"$WORK/publish.err"; then
    store_fail "cannot write the archive in $sub: $(head -n1 "$WORK/publish.err"); nothing published"
    return 1
  fi
  if ! final="$("$PERL" -e "$PUBLISH_LINK" "$EXPORT_TMPFILE" "$EXPORT_DEST" "gitleaks-store-$ts" "$ext" 2>"$WORK/publish.err")" || [[ -z "$final" ]]; then
    store_fail "cannot publish into $EXPORT_DEST: $(head -n1 "$WORK/publish.err"); nothing published"
    return 1
  fi
  h="$(sha256_file "$final")"
  if ! rm -f "$EXPORT_TMPFILE" 2>/dev/null; then
    store_fail "published $final, but could not remove the staging file $EXPORT_TMPFILE"
    return 1
  fi
  EXPORT_TMPFILE=""
  if ! rmdir "$sub" 2>/dev/null; then
    store_fail "published $final, but could not remove the staging dir $sub"
    return 1
  fi
  EXPORT_SUBDIR=""
  echo "published: $final"
  echo "sha256: ${h:-unknown}"
}

# openssl_enc <in> <out> [-d]: AES-256-CBC with PBKDF2 (600000 iterations,
# salted). The passphrase reaches openssl only on fd 3 (a pipe from a shell
# builtin), never argv or the environment.
openssl_enc() {
  local in="$1" out="$2" dir="${3-}"
  # shellcheck disable=SC2086 # $dir is empty or -d
  printf '%s\n' "$EXPORT_PASS" | "$OPENSSL" enc $dir -aes-256-cbc -pbkdf2 -iter 600000 -salt \
    -in "$in" -out "$out" -pass fd:3 3<&0 0</dev/null 2>>"$WORK/openssl.err"
}

do_export_store() {
  local m ext=".tar.gz" artifact
  local -a members=()
  make_work
  if ! export_dest_ok "$STORE_ARG"; then
    store_fail "$STORE_ERR; nothing exported"
    return
  fi
  # 1. The passphrase first: a missing keychain item must not cost a lock.
  if [[ "$PLAIN" -eq 0 ]]; then
    get_export_passphrase 0 || return
  fi
  # 2. The audit lock (a running audit never sees a half-read store).
  acquire_lock
  case $? in
    0) ;;
    2)
      store_fail "$LOCK_ERR"
      return
      ;;
    *)
      EXIT_CODE=$LOCK_BUSY_EXIT
      return
      ;;
  esac
  # 3. The whole live store, independent of repo discovery.
  if ! store_validate "$GLP_BASE" live; then
    store_fail "store validation: $STORE_ERR; nothing exported"
    return
  fi
  [[ $SV_REPOS -eq 1 && $SV_PROTECTED -eq 0 ]] &&
    warn "$GLP_BASE has repos/ but no protected manifest (the audit reports a run ERROR); exporting what is there"
  # 4. Member names: the ustar name field only (100 bytes, no prefix).
  store_members "$WORK/members"
  while IFS= read -r m; do
    if [[ "$(printf '%s' "$m" | LC_ALL=C wc -c | tr -d ' ')" -gt "$STORE_NAME_MAX" ]]; then
      store_fail "archive member name longer than $STORE_NAME_MAX bytes: $m (shorten the repo path); nothing exported"
      return
    fi
    members+=("$m")
  done <"$WORK/members"
  # 5. A private, ACL-free staging tree with copies and a MANIFEST.
  local stage
  if ! stage="$(mktemp -d "$WORK/stage.XXXXXX")" || ! chmod 700 "$stage" || ! chmod -N "$stage" ||
    ! ls_led_ok "$stage" drwx------; then
    store_fail "cannot create a private ACL-free staging dir under ${TMPDIR:-/tmp}; nothing exported"
    return
  fi
  : >"$WORK/manifest"
  for m in "${members[@]}"; do
    case "$m" in
      MANIFEST) ;;
      */)
        if ! mkdir -p "$stage/$m" || ! chmod 700 "$stage/$m"; then
          store_fail "cannot stage $m; nothing exported"
          return
        fi
        ;;
      *)
        if ! { cat "$GLP_BASE/$m" >"$stage/$m" && chmod 600 "$stage/$m"; } 2>/dev/null; then
          store_fail "cannot stage $m; nothing exported"
          return
        fi
        printf '%s  %s\n' "$(sha256_file "$stage/$m")" "$m" >>"$WORK/manifest"
        ;;
    esac
  done
  if grep -q '^  ' "$WORK/manifest" || ! { cp "$WORK/manifest" "$stage/MANIFEST" && chmod 600 "$stage/MANIFEST"; } 2>/dev/null; then
    store_fail "cannot write the MANIFEST; nothing exported"
    return
  fi
  # The staged copies are what gets archived: validate them too (and that
  # the store did not change shape while it was copied).
  if ! store_validate "$stage" tree; then
    store_fail "staged copy: $STORE_ERR; nothing exported"
    return
  fi
  store_members "$WORK/members.staged"
  if ! cmp -s "$WORK/members" "$WORK/members.staged"; then
    store_fail "the store changed while it was being exported; nothing exported (retry)"
    return
  fi
  # 6. ustar + gzip, explicit member order, no extended metadata.
  if ! (cd "$stage" && COPYFILE_DISABLE=1 /usr/bin/tar --format ustar --no-mac-metadata --no-xattrs \
    --no-acls --no-fflags -c -z -n -f "$WORK/store.tar.gz" "${members[@]}") 2>"$WORK/tar.err"; then
    store_fail "tar failed: $(head -n1 "$WORK/tar.err"); nothing exported"
    return
  fi
  # Self-check: the import's reader must accept exactly these members.
  if ! /usr/bin/gzip -dc "$WORK/store.tar.gz" >"$WORK/check.tar" 2>/dev/null ||
    ! ustar_check "$WORK/check.tar" "$WORK/check.members" ||
    [[ "$(cut -c3- "$WORK/check.members")" != "$(cat "$WORK/members")" ]]; then
    store_fail "the archive does not pass the import checks (${STORE_ERR:-member list differs}); nothing exported"
    return
  fi
  artifact="$WORK/store.tar.gz"
  # 7. Encrypt (default), and prove the passphrase opens it again.
  if [[ "$PLAIN" -eq 0 ]]; then
    if ! openssl_enc "$WORK/store.tar.gz" "$WORK/store.tar.gz.enc" ||
      ! openssl_enc "$WORK/store.tar.gz.enc" "$WORK/verify.tar.gz" -d ||
      ! cmp -s "$WORK/store.tar.gz" "$WORK/verify.tar.gz"; then
      store_fail "encryption failed: $(head -n1 "$WORK/openssl.err" 2>/dev/null); nothing exported"
      return
    fi
    artifact="$WORK/store.tar.gz.enc"
    ext=".tar.gz.enc"
  else
    warn "WARNING: --plain writes an UNENCRYPTED archive. It holds sensitive metadata (repo names and paths, fingerprints of unrotated secrets; no secret values): keep it private and out of synced folders."
  fi
  EXPORT_PASS=""
  # 8. Publish.
  publish_artifact "$artifact" "$ext" || return
}

# manifest_verify <tree> <members>: MANIFEST must list every regular member
# except itself, exactly once, with a matching sha256, and nothing else.
manifest_verify() {
  local root="$1" mlist="$2" line n=0 h p kind
  if ! grep -qxF "f MANIFEST" "$mlist"; then
    STORE_ERR="MANIFEST: missing from the archive"
    return 1
  fi
  : >"$WORK/manifest.listed"
  while IFS= read -r line || [[ -n "$line" ]]; do
    n=$((n + 1))
    if [[ ! "$line" =~ ^([0-9a-f]{64})\ \ (.+)$ ]]; then
      STORE_ERR="MANIFEST: line $n is not '<sha256>  <path>'"
      return 1
    fi
    h="${BASH_REMATCH[1]}"
    p="${BASH_REMATCH[2]}"
    if [[ "$p" == MANIFEST ]]; then
      STORE_ERR="MANIFEST: lists itself"
      return 1
    fi
    if grep -qxF -- "$p" "$WORK/manifest.listed"; then
      STORE_ERR="MANIFEST: $p is listed twice"
      return 1
    fi
    printf '%s\n' "$p" >>"$WORK/manifest.listed"
    if ! grep -qxF -- "f $p" "$mlist"; then
      STORE_ERR="MANIFEST: $p is listed in MANIFEST but not in the archive"
      return 1
    fi
    if [[ "$(sha256_file "$root/$p")" != "$h" ]]; then
      STORE_ERR="MANIFEST: sha256 mismatch for $p"
      return 1
    fi
  done <"$root/MANIFEST"
  while read -r kind p; do
    [[ "$kind" == f && "$p" != MANIFEST ]] || continue
    if ! grep -qxF -- "$p" "$WORK/manifest.listed"; then
      STORE_ERR="MANIFEST: $p is in the archive but not listed in MANIFEST"
      return 1
    fi
  done <"$mlist"
  return 0
}

# tree_nodes <root>: "d <rel>/" or "f <rel>" per node (sorted); 1 when a
# node is neither a directory nor a regular file.
tree_nodes() {
  local root="$1" p rel
  find "$root" -mindepth 1 -print0 2>/dev/null | while IFS= read -r -d '' p; do
    rel="${p#"$root"/}"
    if [[ -L "$p" ]]; then
      echo "x $rel"
    elif [[ -d "$p" ]]; then
      echo "d $rel/"
    elif [[ -f "$p" ]]; then
      echo "f $rel"
    else
      echo "x $rel"
    fi
  done | LC_ALL=C sort
}

do_import_store() {
  local a="$STORE_ARG" enc=0 gz size ts d i top live=0
  local -a ps=()
  make_work
  if [[ ! -f "$a" || ! -r "$a" ]]; then
    store_fail "archive $a is not a readable regular file"
    return
  fi
  case "$a" in *.enc) enc=1 ;; esac
  [[ "$(LC_ALL=C head -c 8 "$a" 2>/dev/null)" == "Salted__" ]] && enc=1
  gz="$a"
  # 1. Decrypt (capped): the passphrase only on fd 3.
  if [[ $enc -eq 1 ]]; then
    get_export_passphrase 1 "$a" || return
    printf '%s\n' "$EXPORT_PASS" | "$OPENSSL" enc -d -aes-256-cbc -pbkdf2 -iter 600000 -in "$a" \
      -pass fd:3 3<&0 0</dev/null 2>"$WORK/openssl.err" | head -c "$STORE_MAX_BYTES" >"$WORK/decrypted.gz"
    ps=("${PIPESTATUS[@]}")
    EXPORT_PASS=""
    size="$(wc -c <"$WORK/decrypted.gz" | tr -d ' ')"
    if [[ "$size" -ge "$STORE_MAX_BYTES" ]]; then
      store_fail "import rejected: size: the decrypted archive exceeds limit ($STORE_MAX_BYTES bytes); nothing restored"
      return
    fi
    if [[ "${ps[1]}" -ne 0 ]]; then
      store_fail "import rejected: decrypt error: wrong passphrase or damaged archive; nothing restored"
      return
    fi
    if [[ "${ps[0]}" -ne 0 || "${ps[2]}" -ne 0 ]]; then
      store_fail "import: cannot write the decrypted archive; nothing restored"
      return
    fi
    gz="$WORK/decrypted.gz"
  fi
  # 2. Decompress (capped one byte past the limit to tell "at" from "over").
  /usr/bin/gzip -dc <"$gz" 2>"$WORK/gzip.err" | head -c "$((STORE_MAX_BYTES + 1))" >"$WORK/raw.tar"
  ps=("${PIPESTATUS[@]}")
  size="$(wc -c <"$WORK/raw.tar" | tr -d ' ')"
  if [[ "$size" -gt "$STORE_MAX_BYTES" ]]; then
    store_fail "import rejected: size: the decompressed archive exceeds limit ($STORE_MAX_BYTES bytes); nothing restored"
    return
  fi
  if [[ "${ps[0]}" -ne 0 ]]; then
    if [[ $enc -eq 1 ]]; then
      store_fail "import rejected: decrypt/decompress error: wrong passphrase or damaged archive ($(head -n1 "$WORK/gzip.err" | cut -c1-160)); nothing restored"
    else
      store_fail "import rejected: decompress error: damaged archive ($(head -n1 "$WORK/gzip.err" | cut -c1-160)); nothing restored"
    fi
    return
  fi
  if [[ "${ps[1]}" -ne 0 ]]; then
    store_fail "import: cannot write the decompressed archive; nothing restored"
    return
  fi
  # 3. Every header, before anything is extracted.
  if ! ustar_check "$WORK/raw.tar" "$WORK/members"; then
    store_fail "import rejected: $STORE_ERR; nothing restored"
    return
  fi
  LC_ALL=C sort -o "$WORK/members.sorted" "$WORK/members"
  # 4. Extract into a private ACL-free temp dir; normalize to 700/600.
  local x
  if ! x="$(mktemp -d "$WORK/extract.XXXXXX")" || ! chmod 700 "$x" || ! chmod -N "$x" ||
    ! ls_led_ok "$x" drwx------; then
    store_fail "import: cannot create a private ACL-free extraction dir; nothing restored"
    return
  fi
  if ! (cd "$x" && COPYFILE_DISABLE=1 /usr/bin/tar -x --no-mac-metadata --no-xattrs --no-acls --no-fflags \
    -f "$WORK/raw.tar") 2>"$WORK/tar.err"; then
    store_fail "import: extraction failed: $(head -n1 "$WORK/tar.err"); nothing restored"
    return
  fi
  if ! find "$x" -type d -exec chmod 700 {} + 2>/dev/null || ! find "$x" -type f -exec chmod 600 {} + 2>/dev/null ||
    ! chmod -RN "$x" 2>/dev/null; then
    store_fail "import: cannot normalize the extracted modes/ACLs; nothing restored"
    return
  fi
  tree_nodes "$x" >"$WORK/nodes"
  if ! cmp -s "$WORK/nodes" "$WORK/members.sorted"; then
    store_fail "import rejected: the extracted tree does not match the archive members exactly; nothing restored"
    return
  fi
  # 5. MANIFEST, both ways.
  if ! manifest_verify "$x" "$WORK/members"; then
    store_fail "import rejected: $STORE_ERR; nothing restored"
    return
  fi
  # 6. The restored tree must be a valid store.
  if ! store_validate "$x" tree; then
    store_fail "import rejected: restored store: $STORE_ERR; nothing restored"
    return
  fi
  # 7. Move it to a new restore-<UTC> dir; nothing live is touched.
  if [[ ! -d "$GLP_BASE" ]] && ! mkdir -p "$GLP_BASE" 2>/dev/null; then
    store_fail "import: cannot create $GLP_BASE; nothing restored"
    return
  fi
  ts="$(utc_stamp)"
  d=""
  for i in $(seq 1 99); do
    if [[ $i -eq 1 ]]; then d="$GLP_BASE/restore-$ts"; else d="$GLP_BASE/restore-$ts-$i"; fi
    if mkdir "$d" 2>/dev/null; then
      RESTORE_DIR="$d"
      break
    fi
    d=""
  done
  if [[ -z "$d" ]]; then
    store_fail "import: no free restore-$ts name under $GLP_BASE; nothing restored"
    return
  fi
  for top in repos protected config MANIFEST; do
    [[ -e "$x/$top" ]] || continue
    if ! mv "$x/$top" "$d/" 2>/dev/null; then
      store_fail "import: cannot move $top into $d; nothing restored"
      return
    fi
  done
  if ! chmod 700 "$d" 2>/dev/null; then
    store_fail "import: cannot chmod $d; nothing restored"
    return
  fi
  RESTORE_DIR=""
  [[ -e "$GLP_REPOS" || -L "$GLP_REPOS" || -e "$GLP_PROTECTED" || -L "$GLP_PROTECTED" ]] && live=1
  echo "restored into $d (verified; NOT installed: the live store was not touched)"
  echo
  if [[ $live -eq 1 ]]; then
    echo "An existing store is live at $GLP_BASE. To install the restored one, move the live one aside first:"
    echo "  mkdir $(shq "$GLP_BASE/backup-$ts")"
    [[ -e "$GLP_REPOS" || -L "$GLP_REPOS" ]] && echo "  mv $(shq "$GLP_REPOS") $(shq "$GLP_BASE/backup-$ts/")"
    [[ -e "$GLP_PROTECTED" || -L "$GLP_PROTECTED" ]] && echo "  mv $(shq "$GLP_PROTECTED") $(shq "$GLP_BASE/backup-$ts/")"
  else
    echo "No live store at $GLP_BASE (fresh install):"
  fi
  [[ -e "$d/repos" ]] && echo "  mv $(shq "$d/repos") $(shq "$GLP_REPOS")"
  [[ -e "$d/protected" ]] && echo "  mv $(shq "$d/protected") $(shq "$GLP_PROTECTED")"
  [[ -e "$d/config" ]] && echo "  [ -e $(shq "$GLP_BASE/config") ] || mv $(shq "$d/config") $(shq "$GLP_BASE/config")"
  echo "  gitleaks-audit.sh --full"
  cat <<'EOF'

Consequences:
  - While repos/ exists without protected, the audit reports a run ERROR:
    move protected in together with repos/.
  - During the move the commit hook sees no store at all: that only adds
    blocking for valid stores, but a commit blocked only by a store error
    can pass in that window.
  - The audit state is not restored: the first scan after the install
    baselines its findings (no NEW notifications), and pending
    announcements from before are not restored.
EOF
}

do_status() {
  local uid service
  uid="$(id -u)"
  service="gui/$uid/$LABEL"
  if launchctl print "$service" >/dev/null 2>&1; then
    echo "agent: loaded ($service)"
  else
    echo "agent: not loaded ($service)"
  fi
  if [[ -f "$AGENT_PLIST" ]]; then
    echo "plist: $AGENT_PLIST (present)"
  else
    echo "plist: $AGENT_PLIST (absent)"
  fi
  echo "log:   $LOG_FILE"
  echo "state: $STATE_DIR"
  local lf
  lf="$(meta_get last_full)"
  if [[ "$lf" =~ ^[0-9]+$ ]]; then
    echo "last full pass: $(/bin/date -r "$lf" '+%Y-%m-%d %H:%M:%S %z')"
  else
    echo "last full pass: never"
  fi
  if [[ -f "$LAST_RUN_FILE" ]]; then
    echo "last run: $(cat "$LAST_RUN_FILE")"
  else
    echo "last run: none"
  fi
  return 0
}

# --- launchd install / uninstall ---------------------------------------------

TEMPLATE="$SCRIPT_DIR/launchd/$LABEL.plist"
AGENT_PLIST="$HOME/Library/LaunchAgents/$LABEL.plist"
AGENT_PATH="/opt/homebrew/bin:/usr/local/bin:$SYSTEM_PATH"
AGENT_LOG="$HOME/Library/Logs/gitleaks-audit.launchd.log"

xml_escape() {
  local v="$1"
  v="${v//&/&amp;}"
  v="${v//</&lt;}"
  v="${v//>/&gt;}"
  v="${v//\"/&quot;}"
  v="${v//\'/&apos;}"
  printf '%s' "$v"
}

render_plist() {
  local out="$1" line sp hp pp op
  sp="$(xml_escape "$SCRIPT_PATH")"
  hp="$(xml_escape "$HOME")"
  pp="$(xml_escape "$AGENT_PATH")"
  op="$(xml_escape "$AGENT_LOG")"
  : >"$out" || return 1
  while IFS= read -r line || [[ -n "$line" ]]; do
    line="${line//__SCRIPT_PATH__/$sp}"
    line="${line//__HOME__/$hp}"
    line="${line//__PATH__/$pp}"
    line="${line//__STDOUT_PATH__/$op}"
    line="${line//__STDERR_PATH__/$op}"
    printf '%s\n' "$line" >>"$out" || return 1
  done <"$TEMPLATE"
}

do_install() {
  local uid domain service tmp
  uid="$(id -u)"
  domain="gui/$uid"
  service="$domain/$LABEL"
  [[ -f "$TEMPLATE" ]] || die "launchd template not found: $TEMPLATE"
  make_work
  tmp="$WORK/$LABEL.plist"
  render_plist "$tmp" || die "failed to render $TEMPLATE"
  if grep -q '__[A-Z_]*__' "$tmp"; then
    die "rendered plist still contains placeholders"
  fi
  plutil -lint "$tmp" >/dev/null || die "rendered plist failed plutil -lint"
  mkdir -p "$(dirname "$AGENT_PLIST")" "$(dirname "$AGENT_LOG")" || die "cannot create LaunchAgents/Logs directories"
  if launchctl print "$service" >/dev/null 2>&1; then
    info "$LABEL already loaded; booting it out first"
    launchctl bootout "$service" || die "launchctl bootout $service failed"
  fi
  if ! cp "$tmp" "$AGENT_PLIST" || ! chmod 644 "$AGENT_PLIST"; then
    die "cannot write $AGENT_PLIST"
  fi
  launchctl enable "$service" || warn "launchctl enable $service failed (continuing)"
  if ! launchctl bootstrap "$domain" "$AGENT_PLIST"; then
    rm -f "$AGENT_PLIST"
    die "launchctl bootstrap $domain $AGENT_PLIST failed; removed the rendered plist"
  fi
  info "installed $AGENT_PLIST (runs --run daily at 11:00; not started now)"
}

do_uninstall() {
  local uid service
  uid="$(id -u)"
  service="gui/$uid/$LABEL"
  if launchctl print "$service" >/dev/null 2>&1; then
    launchctl bootout "$service" || die "launchctl bootout $service failed; plist left in place"
    info "booted out $service"
  else
    info "$service not loaded"
  fi
  if [[ -e "$AGENT_PLIST" ]]; then
    rm -f "$AGENT_PLIST" || die "cannot remove $AGENT_PLIST"
    info "removed $AGENT_PLIST"
  fi
}

case "$MODE" in
  dry-run)
    NOTIFY=0
    echo "gitleaks-audit dry run: no scans, no state or log writes"
    do_scan_mode dry-run
    exit "$EXIT_CODE"
    ;;
  run | full)
    do_scan_mode "$MODE"
    exit "$EXIT_CODE"
    ;;
  report) do_report ;;
  prune-delivered)
    do_prune_delivered
    exit "$EXIT_CODE"
    ;;
  set-export-passphrase) do_set_export_passphrase ;;
  export-store)
    do_export_store
    exit "$EXIT_CODE"
    ;;
  import-store)
    do_import_store
    exit "$EXIT_CODE"
    ;;
  status) do_status ;;
  install) do_install ;;
  uninstall) do_uninstall ;;
esac
exit 0
