#!/usr/bin/env bash
# gh-secret-scanning-rollout.sh — enable GitHub secret scanning and push
# protection on an owner's PUBLIC repositories where either is disabled.
#
# Dry-run by default (GET requests only, nothing written anywhere). --apply
# PATCHes only the fields that are "disabled", one repo at a time, refreshing
# the repo state right before each write and verifying it right after. Every
# decision is journalled (before and after states) so a run can be resumed or
# rolled back by hand.
#
# bash 3.2 compatible; no `set -e`.

set -uo pipefail

SCRIPT_DIR="$(cd "$(dirname "${BASH_SOURCE[0]}")" && pwd)"
# shellcheck source=../lib/common.sh
source "$SCRIPT_DIR/../lib/common.sh"

usage() {
  cat <<'EOF'
Usage: gh-secret-scanning-rollout [--apply] [--only a,b] [--resume JOURNAL]
                                  [--owner LOGIN]

Enable secret scanning and secret scanning push protection on every PUBLIC,
non-archived repo owned by LOGIN where either setting is "disabled".
Default is a dry-run: the inventory and the plan are printed, nothing is
written (no PATCH, no journal, no state dir).

Options:
  --apply           Write. PATCH repos/<owner>/<repo> with only the disabled
                    fields ({"security_and_analysis": {"secret_scanning":
                    {"status": "enabled"}, "secret_scanning_push_protection":
                    {"status": "enabled"}}}; secret_scanning first, since push
                    protection requires it). An already-enabled field is never
                    sent; no other setting is ever sent.
  --dry-run         The default; accepted for explicitness.
  --only a,b        Limit the run to these repo names (comma-separated).
  --resume JOURNAL  With --apply: append to an earlier journal instead of a
                    new one. Repos whose last journal row is verified,
                    already-enabled or done-in-journal are left alone (even if
                    they were disabled again since, e.g. by a manual rollback;
                    the done-in-journal row a resume appends keeps them
                    completed on every later resume). A repo whose last row is
                    pending or failed and that is now enabled on both fields is
                    reconciled: a verified row ("reconciled on resume"), no
                    PATCH. Every other target is re-inventoried and processed
                    again.
  --owner LOGIN     Repo owner (default: the authenticated `gh api user`).
  -h, --help        Show this help.

Inventory:
  GET user/repos?affiliation=owner (every page, following Link rel="next"),
  filtered to owner.login == LOGIN and deduplicated by id; private repos are
  never requested further. Then GET repos/<owner>/<repo> per public repo (the
  list endpoint omits security_and_analysis). A missing / null / unknown
  secret_scanning or push-protection status is an ERROR row, never treated as
  disabled. The inventory is complete only if every page and every GET
  succeeded. A failed page blocks every write.

Per target (with --apply):
  1. GET (refresh) - re-select from the fresh state; nothing disabled = done.
  2. PATCH the disabled fields (>= 1s between mutations).
  3. GET (verify, up to 3 tries) - verified only when both fields are
     "enabled" and every other security_and_analysis field is exactly as
     before (none changed, removed or added); else failed.
  Rate limits: 429, and 403 with Retry-After / x-ratelimit-remaining: 0 / a
  "rate limit" message, wait Retry-After, else until x-ratelimit-reset, else
  60s (secondary limits); at most 4 retries. A timeout or 5xx on PATCH is
  reconciled by the refresh GET before any retry. Any other 4xx is permanent
  and never retried.

Journal (dir 700, file 600, ACLs stripped):
  ~/Library/Application Support/gh-security-rollout/secret-scanning-<UTC>.tsv
  repo, repo_id, ss_before, pp_before, action, result, ss_after, pp_after,
  utc, http, detail. A "pending" row precedes every PATCH.
  result: verified | already-enabled | failed | pending | skipped-private |
          skipped-archived | error | done-in-journal

Rollback: there is no rollback command. The journal records every repo's
before-states; to undo one repo, PATCH the same field(s) back to
{"status": "disabled"} (push protection first), after a fresh GET.

Exit codes:
  0   every target verified or already enabled (or nothing to do), and the
      inventory is complete with no error rows
  1   any failed repo, error row, or incomplete inventory
  2   usage error (including an unusable --resume journal)
  3   missing dependency
  4   gh not authenticated

Environment (tests):
  GH_ROLLOUT_GH            gh command (default gh)
  GH_ROLLOUT_SLEEP         sleep command (default sleep)
  GH_ROLLOUT_HTTP_TIMEOUT  seconds per gh request (default 60)

Examples:
  gh-secret-scanning-rollout
  gh-secret-scanning-rollout --apply --only repo-a,repo-b
  gh-secret-scanning-rollout --apply --resume \
    "$HOME/Library/Application Support/gh-security-rollout/secret-scanning-20261015T120000Z.tsv"
EOF
}

# --- arguments -------------------------------------------------------------------

NAME_RE='^[A-Za-z0-9._-]+$'
valid_name() { [[ "$1" =~ $NAME_RE && "$1" != "." && "$1" != ".." ]]; }

APPLY=0
OWNER=""
SCOPE=""
RESUME=""
while [[ $# -gt 0 ]]; do
  case "$1" in
    -h | --help)
      usage
      exit 0
      ;;
    --apply)
      APPLY=1
      shift
      ;;
    --dry-run)
      shift
      ;;
    --only)
      [[ -n "${2-}" ]] || die_usage "--only needs a comma-separated list of repo names"
      IFS=',' read -r -a _names <<<"$2"
      for _n in ${_names[@]+"${_names[@]}"}; do
        [[ -n "$_n" ]] || continue
        valid_name "$_n" || die_usage "invalid repo name in --only: $_n"
        SCOPE="$SCOPE$_n"$'\n'
      done
      [[ -n "$SCOPE" ]] || die_usage "--only needs at least one repo name"
      shift 2
      ;;
    --resume)
      [[ -n "${2-}" ]] || die_usage "--resume needs a journal path"
      RESUME="$2"
      shift 2
      ;;
    --owner)
      [[ -n "${2-}" ]] || die_usage "--owner needs a login"
      OWNER="$2"
      shift 2
      ;;
    *) die_usage "unknown argument: $1 (see --help)" ;;
  esac
done
[[ -z "$OWNER" ]] || valid_name "$OWNER" || die_usage "invalid --owner: $OWNER"
[[ -z "$RESUME" || "$APPLY" -eq 1 ]] || die_usage "--resume requires --apply"

GH="${GH_ROLLOUT_GH:-gh}"
SLEEP_CMD="${GH_ROLLOUT_SLEEP:-sleep}"
HTTP_TIMEOUT="${GH_ROLLOUT_HTTP_TIMEOUT:-60}"
PERL=/usr/bin/perl
MAX_RETRIES=4
MAX_WAIT=3700
SECONDARY_WAIT=60
SPACING=1
VERIFY_TRIES=3
VERIFY_DELAY=2
STATE_ROOT="$HOME/Library/Application Support/gh-security-rollout"
JOURNAL_HEADER=$'# repo\trepo_id\tss_before\tpp_before\taction\tresult\tss_after\tpp_after\tutc\thttp\tdetail'

[[ "$HTTP_TIMEOUT" =~ ^[0-9]+$ && "$HTTP_TIMEOUT" -gt 0 ]] || die_usage "GH_ROLLOUT_HTTP_TIMEOUT must be a positive integer"

umask 077

# ls_led_ok <path> <mode-string>: one `ls -led` line, that mode, no ACL.
ls_led_ok() {
  local out
  out="$(LC_ALL=C /bin/ls -led -- "$1" 2>/dev/null)" || return 1
  [[ -n "$out" && "$out" != *$'\n'* && "${out:0:10}" == "$2" && "${out:10:1}" != "+" ]]
}

if [[ -n "$RESUME" ]]; then
  [[ -f "$RESUME" && ! -L "$RESUME" && -O "$RESUME" ]] ||
    die_usage "--resume: $RESUME is not a regular file owned by you"
  ls_led_ok "$RESUME" -rw------- || die_usage "--resume: $RESUME must be mode 600 without ACL entries"
  [[ "$(head -n1 "$RESUME")" == "$JOURNAL_HEADER" ]] ||
    die_usage "--resume: $RESUME is not a gh-secret-scanning-rollout journal"
fi

require_cmd jq "brew install jq"
require_cmd "$GH" "brew install gh"
[[ -x "$PERL" ]] || die_missing_dep "$PERL is required (request timeouts)"

WORK="$(mktemp -d "${TMPDIR:-/tmp}/gh-secret-scanning-rollout.XXXXXX")" || die "cannot create a work dir"
# shellcheck disable=SC2329 # invoked via trap
cleanup() { rm -rf "$WORK"; }
trap cleanup EXIT

# --- HTTP ------------------------------------------------------------------------

API_HDR="$WORK/hdr"
API_BODY="$WORK/body"
API_STATUS=000
API_CLASS=""
API_WAIT=0
API_DETAIL=""

# sanitize <text>: one printable line, at most 160 chars.
sanitize() { printf '%s' "$1" | LC_ALL=C tr -c '[:print:]' ' ' | cut -c1-160; }

do_sleep() { "$SLEEP_CMD" "$1" </dev/null >/dev/null 2>&1; }

now_epoch() { /bin/date -u +%s; }
now_utc() { /bin/date -u +%Y-%m-%dT%H:%M:%SZ; }

# hdr <lowercase-name>: a response header value from the last request.
hdr() {
  awk -v k="$1" 'NR > 1 {
      i = index($0, ":")
      if (i > 1 && tolower(substr($0, 1, i - 1)) == k) {
        v = substr($0, i + 1); gsub(/^[ \t]+|[ \t]+$/, "", v); print v; exit
      }
    }' "$API_HDR" 2>/dev/null
}

# Run argv with a deadline: TERM, then KILL 2s later; exit 124 on timeout.
# (Go programs such as gh ignore SIGALRM, so the deadline is a parent's.)
# shellcheck disable=SC2016 # perl code
TIMEOUT_PL='use POSIX ":sys_wait_h"; my $t = shift @ARGV;
my $pid = fork(); defined $pid or exit 125;
if ($pid == 0) { exec { $ARGV[0] } @ARGV or exit 127; }
$SIG{ALRM} = sub {
  kill "TERM", $pid;
  for (1 .. 20) { exit 124 if waitpid($pid, WNOHANG) > 0; select(undef, undef, undef, 0.1); }
  kill "KILL", $pid; waitpid($pid, 0); exit 124;
};
alarm $t; waitpid($pid, 0); alarm 0;
exit(($? & 127) ? 128 + ($? & 127) : ($? >> 8));'

# rate_limit_wait: seconds to wait after a rate-limited response.
rate_limit_wait() {
  local ra rem reset w
  ra="$(hdr retry-after)"
  rem="$(hdr x-ratelimit-remaining)"
  reset="$(hdr x-ratelimit-reset)"
  if [[ "$ra" =~ ^[0-9]+$ ]]; then
    w="$ra"
  elif [[ "$rem" == 0 && "$reset" =~ ^[0-9]+$ ]]; then
    w=$((reset - $(now_epoch) + 1))
  else
    w="$SECONDARY_WAIT"
  fi
  [[ "$w" -ge 1 ]] || w=1
  printf '%s' "$w"
}

# is_rate_limited: the last 403 is a (primary or secondary) rate limit.
is_rate_limited() {
  [[ -n "$(hdr retry-after)" || "$(hdr x-ratelimit-remaining)" == 0 ]] && return 0
  jq -r '.message // empty' "$API_BODY" 2>/dev/null | grep -qi 'rate limit'
}

# api_once <method> <path> [input-file]: exactly one request. Sets API_STATUS
# (3 digits, 000 = no response / timeout), API_CLASS (ok | ratelimit |
# transient | permanent), API_WAIT, API_DETAIL; body in $API_BODY.
api_once() {
  local method="$1" path="$2" input="${3-}" rc st msg
  local -a args
  args=(api -i -X "$method" -H "Accept: application/vnd.github+json" -H "X-GitHub-Api-Version: 2022-11-28" "$path")
  [[ -n "$input" ]] && args+=(--input "$input")
  : >"$API_HDR"
  : >"$API_BODY"
  "$PERL" -e "$TIMEOUT_PL" "$HTTP_TIMEOUT" "$GH" "${args[@]}" >"$WORK/raw" 2>"$WORK/err" </dev/null
  rc=$?
  tr -d '\r' <"$WORK/raw" | awk -v h="$API_HDR" -v b="$API_BODY" '
    s == 0 { if ($0 == "") { s = 1; next } print > h; next }
    { print > b }'
  st="$(head -n1 "$API_HDR" | awk '$1 ~ /^HTTP\// && $2 ~ /^[0-9][0-9][0-9]$/ { print $2 }')"
  [[ -n "$st" && "$rc" -lt 124 ]] || st=000
  API_STATUS="$st"
  API_WAIT=0
  case "$st" in
    2??) API_CLASS=ok ;;
    429)
      API_CLASS=ratelimit
      API_WAIT="$(rate_limit_wait)"
      ;;
    403)
      if is_rate_limited; then
        API_CLASS=ratelimit
        API_WAIT="$(rate_limit_wait)"
      else
        API_CLASS=permanent
      fi
      ;;
    5?? | 000) API_CLASS=transient ;;
    *) API_CLASS=permanent ;;
  esac
  if [[ "$API_CLASS" == ok ]]; then
    API_DETAIL=""
  else
    msg="$(jq -r '.message // empty' "$API_BODY" 2>/dev/null)"
    [[ -n "$msg" ]] || msg="$(head -n1 "$WORK/err")"
    [[ "$rc" -eq 124 ]] && msg="timed out after ${HTTP_TIMEOUT}s"
    API_DETAIL="$(sanitize "$method $path: HTTP $st: $msg")"
  fi
  return 0
}

# backoff <attempt>: 2, 4, 8, 16, 30, 30...
backoff() {
  local w=$((2 << $1))
  [[ "$w" -le 30 ]] || w=30
  printf '%s' "$w"
}

# api_get <path>: GET with bounded retries for rate limits and transient
# failures. 0 = 2xx (body in $API_BODY); 1 otherwise (API_* describe it).
api_get() {
  local n=0 w
  while :; do
    api_once GET "$1"
    case "$API_CLASS" in
      ok) return 0 ;;
      permanent) return 1 ;;
      ratelimit) w="$API_WAIT" ;;
      *) w="$(backoff "$n")" ;;
    esac
    if [[ "$n" -ge "$MAX_RETRIES" ]]; then
      API_DETAIL="$API_DETAIL (gave up after $((n + 1)) attempts)"
      return 1
    fi
    if [[ "$w" -gt "$MAX_WAIT" ]]; then
      API_DETAIL="$API_DETAIL (wait ${w}s exceeds ${MAX_WAIT}s)"
      return 1
    fi
    warn "$API_DETAIL; retrying in ${w}s"
    do_sleep "$w"
    n=$((n + 1))
  done
}

# --- repo state ------------------------------------------------------------------

# JQ_STATE: visibility, archived, secret_scanning, push protection of a
# per-repo GET body, distinguishing missing keys from nulls.
# shellcheck disable=SC2016 # jq program
JQ_STATE='
def st(k):
  if has("security_and_analysis") | not then "missing"
  elif .security_and_analysis == null then "null"
  elif (.security_and_analysis | type) != "object" then "invalid"
  elif (.security_and_analysis | has(k)) | not then "missing"
  elif .security_and_analysis[k] == null then "null"
  elif (.security_and_analysis[k] | type) != "object" then "invalid"
  elif (.security_and_analysis[k] | has("status")) | not then "missing"
  elif .security_and_analysis[k].status == null then "null"
  else (.security_and_analysis[k].status | tostring) end;
if (.id | tostring) != $id or .owner.login != $o then "mismatch"
else
  [ (if .private == false and ((.visibility // "public") == "public") then "public"
     elif .private == true then (.visibility // "private")
     else "unknown" end),
    (if .archived == true then "true" elif .archived == false then "false" else "unknown" end),
    st("secret_scanning"), st("secret_scanning_push_protection") ] | @tsv
end'

# The security_and_analysis fields other than the two this script writes.
# shellcheck disable=SC2016 # jq program
JQ_OTHER='(.security_and_analysis // {}) | if type == "object" then del(.secret_scanning, .secret_scanning_push_protection) else {} end'

R_VIS="" R_ARCH="" R_SS="" R_PP="" R_SEL="" R_FIELDS="" R_DETAIL=""

clean_status() {
  if [[ "$1" =~ ^[a-z_-]+$ ]]; then printf '%s' "$1"; else printf 'invalid'; fi
}

# read_state <id>: parse $API_BODY into R_* and classify. 1 = unusable body.
read_state() {
  local out
  out="$(jq -r --arg id "$1" --arg o "$OWNER" "$JQ_STATE" "$API_BODY" 2>/dev/null)" || out=""
  if [[ "$out" != *$'\t'*$'\t'*$'\t'* ]]; then
    R_SEL=error
    if [[ "$out" == mismatch ]]; then
      R_DETAIL="GET returned a different repo id or owner"
    else
      R_DETAIL="unparseable GET body"
    fi
    R_SS=unknown R_PP=unknown R_FIELDS=""
    return 1
  fi
  IFS=$'\t' read -r R_VIS R_ARCH R_SS R_PP <<<"$out"
  R_VIS="$(clean_status "$R_VIS")"
  R_SS="$(clean_status "$R_SS")"
  R_PP="$(clean_status "$R_PP")"
  classify
  return 0
}

# classify: R_SEL (target | skipped-enabled | skipped-private |
# skipped-archived | error), R_FIELDS (ss / pp / ss+pp), R_DETAIL.
classify() {
  R_FIELDS="" R_DETAIL=""
  if [[ "$R_VIS" != public ]]; then
    R_SEL=skipped-private
  elif [[ "$R_ARCH" == true ]]; then
    R_SEL=skipped-archived
  elif [[ "$R_ARCH" != false ]]; then
    R_SEL=error R_DETAIL="archived flag unknown"
  elif [[ "$R_SS" =~ ^(enabled|disabled)$ && "$R_PP" =~ ^(enabled|disabled)$ ]]; then
    [[ "$R_SS" == disabled ]] && R_FIELDS=ss
    [[ "$R_PP" == disabled ]] && R_FIELDS="${R_FIELDS:+$R_FIELDS+}pp"
    if [[ -n "$R_FIELDS" ]]; then R_SEL=target; else R_SEL=skipped-enabled; fi
  else
    R_SEL=error
    R_DETAIL="state unknown (secret_scanning=$R_SS push_protection=$R_PP; missing/null is not disabled)"
  fi
}

fields_label() {
  case "$1" in
    ss) printf 'secret_scanning' ;;
    pp) printf 'push_protection' ;;
    ss+pp) printf 'secret_scanning+push_protection' ;;
  esac
}

# build_patch <fields> <file>: only the disabled fields, secret_scanning first.
build_patch() {
  local ss=false pp=false
  [[ "$1" == ss || "$1" == ss+pp ]] && ss=true
  [[ "$1" == pp || "$1" == ss+pp ]] && pp=true
  jq -n -c --argjson ss "$ss" --argjson pp "$pp" '{security_and_analysis: (
      (if $ss then {secret_scanning: {status: "enabled"}} else {} end)
      + (if $pp then {secret_scanning_push_protection: {status: "enabled"}} else {} end))}' >"$2"
}

# --- inventory -------------------------------------------------------------------

INV_COMPLETE=1
INV_PAGINATION=ok
INV="$WORK/inv.tsv" # sel, name, id, ss, pp, fields, detail

in_scope() { [[ -z "$SCOPE" ]] || printf '%s' "$SCOPE" | grep -qxF -- "$1"; }

inv_row() { printf '%s\t%s\t%s\t%s\t%s\t%s\t%s\n' "$@" >>"$INV"; }

inventory() {
  local pages="$WORK/pages.jsonl" list="$WORK/list.tsv" page=1 name id vis arch
  : >"$INV"
  : >"$pages"
  while :; do
    if ! api_get "user/repos?affiliation=owner&per_page=100&page=$page"; then
      INV_PAGINATION=failed
      warn "repo list page $page failed: $API_DETAIL"
      break
    fi
    if ! jq -e -c 'if type == "array" then . else error("not an array") end' "$API_BODY" >>"$pages" 2>/dev/null; then
      INV_PAGINATION=failed
      warn "repo list page $page is not a JSON array"
      break
    fi
    [[ "$(hdr link)" == *'rel="next"'* ]] || break
    page=$((page + 1))
    if [[ "$page" -gt 1000 ]]; then
      INV_PAGINATION=failed
      warn "repo list has more than 1000 pages; giving up"
      break
    fi
  done
  [[ "$INV_PAGINATION" == ok ]] || INV_COMPLETE=0
  # shellcheck disable=SC2016 # jq program
  if ! jq -r -s --arg o "$OWNER" '
      (add // []) | map(select(.owner.login == $o)) | unique_by(.id) | sort_by(.name) | .[]
      | [ (.name | tostring), (.id | tostring),
          (if .private == false and ((.visibility // "public") == "public") then "public" else "not-public" end),
          (if .archived == true then "true" else "false" end) ] | @tsv' "$pages" >"$list" 2>/dev/null; then
    INV_COMPLETE=0
    INV_PAGINATION=failed
    : >"$list"
    warn "repo list response is not valid JSON"
  fi
  if [[ -n "$SCOPE" ]]; then
    while IFS= read -r name; do
      [[ -n "$name" ]] || continue
      cut -f1 "$list" | grep -qxF -- "$name" ||
        inv_row error "$name" - - - - "not in the owned-repo list"
    done <<<"$SCOPE"
  fi
  while IFS=$'\t' read -r name id vis arch; do
    in_scope "$name" || continue
    if ! valid_name "$name" || [[ ! "$id" =~ ^[0-9]+$ ]]; then
      INV_COMPLETE=0
      inv_row error "$(sanitize "$name")" "$(sanitize "$id")" - - - "unexpected repo name or id"
      continue
    fi
    if [[ "$vis" != public ]]; then
      inv_row skipped-private "$name" "$id" - - - ""
      continue
    fi
    if ! api_get "repos/$OWNER/$name"; then
      INV_COMPLETE=0
      inv_row error "$name" "$id" unknown unknown - "request-failed: $API_DETAIL"
      continue
    fi
    if ! read_state "$id"; then
      INV_COMPLETE=0
      inv_row error "$name" "$id" unknown unknown - "$R_DETAIL"
      continue
    fi
    inv_row "$R_SEL" "$name" "$id" "$R_SS" "$R_PP" "${R_FIELDS:--}" "$R_DETAIL"
  done <"$list"
}

# --- journal ---------------------------------------------------------------------

JOURNAL=""

open_journal() {
  local base ts n=1
  mkdir -p "$STATE_ROOT" 2>/dev/null && /bin/chmod 700 "$STATE_ROOT" 2>/dev/null &&
    /bin/chmod -N "$STATE_ROOT" 2>/dev/null
  ls_led_ok "$STATE_ROOT" drwx------ || die "cannot make $STATE_ROOT private (700, no ACL)"
  if [[ -n "$RESUME" ]]; then
    JOURNAL="$RESUME"
    return 0
  fi
  ts="$(/bin/date -u +%Y%m%dT%H%M%SZ)"
  base="$STATE_ROOT/secret-scanning-$ts"
  JOURNAL="$base.tsv"
  until (set -C && : >"$JOURNAL") 2>/dev/null; do
    n=$((n + 1))
    [[ "$n" -le 50 ]] || die "cannot create a new journal under $STATE_ROOT"
    JOURNAL="$base-$n.tsv"
  done
  /bin/chmod 600 "$JOURNAL" 2>/dev/null && /bin/chmod -N "$JOURNAL" 2>/dev/null
  ls_led_ok "$JOURNAL" -rw------- || die "cannot make $JOURNAL private (600, no ACL)"
  printf '%s\n' "$JOURNAL_HEADER" >>"$JOURNAL" || die "cannot write $JOURNAL"
}

# jrow <repo> <id> <ss_before> <pp_before> <action> <result> <ss_after>
#      <pp_after> <http> <detail>. A failed write stops the run (no write
# may happen without its journal row).
jrow() {
  printf '%s\t%s\t%s\t%s\t%s\t%s\t%s\t%s\t%s\t%s\t%s\n' "$1" "$2" "$3" "$4" "$5" "$6" "$7" "$8" \
    "$(now_utc)" "$9" "$(sanitize "${10}")" >>"$JOURNAL" || die "cannot append to the journal $JOURNAL; stopping"
}

# --- apply -----------------------------------------------------------------------

MUTATED=0
N_VERIFIED=0 N_ALREADY=0 N_FAILED=0 N_SKIPPED=0

# outcome <repo> <id> <ssb> <ppb> <action> <result> <ssa> <ppa> <http> <detail>
outcome() {
  jrow "$@"
  case "$6" in
    verified) N_VERIFIED=$((N_VERIFIED + 1)) ;;
    already-enabled) N_ALREADY=$((N_ALREADY + 1)) ;;
    failed | error) N_FAILED=$((N_FAILED + 1)) ;;
    *) N_SKIPPED=$((N_SKIPPED + 1)) ;;
  esac
  printf '%s\t%s\t%s/%s -> %s/%s\t%s\t%s\n' "$6" "$1" "$3" "$4" "$7" "$8" "$9" "$(sanitize "${10}")"
}

# verify <repo> <id> <ssb> <ppb> <action> <http> <note>: GET until both fields
# are enabled (VERIFY_TRIES), then compare the other fields with the snapshot.
verify() {
  local name="$1" id="$2" n=0 ssa=unknown ppa=unknown detail="$7"
  while :; do
    if api_get "repos/$OWNER/$name" && read_state "$id"; then
      ssa="$R_SS" ppa="$R_PP"
      if [[ "$ssa" == enabled && "$ppa" == enabled ]]; then
        # The other fields must be exactly as before: none changed, none
        # removed, none added.
        # shellcheck disable=SC2016 # jq program
        if jq -e --slurpfile b "$WORK/other.json" "($JQ_OTHER) == \$b[0]" \
          "$API_BODY" >/dev/null 2>&1; then
          outcome "$name" "$id" "$3" "$4" "$5" verified "$ssa" "$ppa" "$6" "$detail"
        else
          outcome "$name" "$id" "$3" "$4" "$5" failed "$ssa" "$ppa" "$6" \
            "other security_and_analysis fields changed after the PATCH"
        fi
        return 0
      fi
    else
      ssa=unknown ppa=unknown
    fi
    n=$((n + 1))
    [[ "$n" -lt "$VERIFY_TRIES" ]] || break
    do_sleep "$VERIFY_DELAY"
  done
  outcome "$name" "$id" "$3" "$4" "$5" failed "$ssa" "$ppa" "$6" \
    "not verified: secret_scanning=$ssa push_protection=$ppa after $VERIFY_TRIES GETs ${detail:+($detail)}"
}

# record_failure <repo> <id> <ssb> <ppb> <action> <http> <detail>: one GET for
# the after-states, then a failed row.
record_failure() {
  local ssa=unknown ppa=unknown
  if api_get "repos/$OWNER/$1" && read_state "$2"; then
    ssa="$R_SS" ppa="$R_PP"
  fi
  outcome "$1" "$2" "$3" "$4" "$5" failed "$ssa" "$ppa" "$6" "$7"
}

process_repo() {
  local name="$1" id="$2" path="repos/$OWNER/$1" attempt=0 w ssb="" ppb="" action=none http=- note=""
  while :; do
    # Refresh immediately before every write (and reconcile before retries).
    if ! api_get "$path"; then
      outcome "$name" "$id" "${ssb:-unknown}" "${ppb:-unknown}" "$action" failed unknown unknown \
        "$API_STATUS" "refresh failed: $API_DETAIL"
      return 0
    fi
    if ! read_state "$id"; then
      outcome "$name" "$id" "${ssb:-unknown}" "${ppb:-unknown}" "$action" error unknown unknown "$http" "$R_DETAIL"
      return 0
    fi
    if [[ -z "$ssb" ]]; then
      ssb="$R_SS" ppb="$R_PP"
      jq -c "$JQ_OTHER" "$API_BODY" >"$WORK/other.json" 2>/dev/null || echo '{}' >"$WORK/other.json"
    fi
    case "$R_SEL" in
      target) ;;
      skipped-enabled)
        if [[ "$attempt" -eq 0 ]]; then
          outcome "$name" "$id" "$ssb" "$ppb" none already-enabled "$R_SS" "$R_PP" - "enabled at refresh"
        else
          verify "$name" "$id" "$ssb" "$ppb" "$action" "$http" "reconciled after $note"
        fi
        return 0
        ;;
      *)
        outcome "$name" "$id" "$ssb" "$ppb" "$action" "$R_SEL" "$R_SS" "$R_PP" "$http" "${R_DETAIL:-at refresh}"
        return 0
        ;;
    esac
    action="patch:$(fields_label "$R_FIELDS")"
    build_patch "$R_FIELDS" "$WORK/patch.json" || {
      outcome "$name" "$id" "$ssb" "$ppb" "$action" failed "$R_SS" "$R_PP" - "cannot build the PATCH body"
      return 0
    }
    jrow "$name" "$id" "$ssb" "$ppb" "$action" pending - - - "attempt $((attempt + 1))"
    [[ "$MUTATED" -eq 1 ]] && do_sleep "$SPACING"
    MUTATED=1
    api_once PATCH "$path" "$WORK/patch.json"
    http="$API_STATUS"
    case "$API_CLASS" in
      ok)
        verify "$name" "$id" "$ssb" "$ppb" "$action" "$http" ""
        return 0
        ;;
      permanent)
        record_failure "$name" "$id" "$ssb" "$ppb" "$action" "$http" "PATCH rejected (not retried): $API_DETAIL"
        return 0
        ;;
      ratelimit) w="$API_WAIT" ;;
      *) w="$(backoff "$attempt")" ;;
    esac
    note="HTTP $http"
    attempt=$((attempt + 1))
    if [[ "$attempt" -gt "$MAX_RETRIES" ]]; then
      record_failure "$name" "$id" "$ssb" "$ppb" "$action" "$http" "gave up after $attempt PATCH attempts: $API_DETAIL"
      return 0
    fi
    if [[ "$w" -gt "$MAX_WAIT" ]]; then
      record_failure "$name" "$id" "$ssb" "$ppb" "$action" "$http" "rate-limit wait ${w}s exceeds ${MAX_WAIT}s: $API_DETAIL"
      return 0
    fi
    warn "$API_DETAIL; waiting ${w}s, then refreshing $name before any retry"
    do_sleep "$w"
  done
}

# --- main ------------------------------------------------------------------------

if [[ -z "$OWNER" ]]; then
  api_get user || die_unauthed "gh api user failed ($API_DETAIL); run: gh auth login"
  OWNER="$(jq -r '.login // empty' "$API_BODY" 2>/dev/null)"
  valid_name "$OWNER" || die_unauthed "gh api user returned no usable login"
fi

inventory

N_TARGET="$(awk -F'\t' '$1 == "target"' "$INV" | wc -l | tr -d ' ')"
N_ERROR="$(awk -F'\t' '$1 == "error"' "$INV" | wc -l | tr -d ' ')"
N_ROWS="$(wc -l <"$INV" | tr -d ' ')"
COMPLETE=true
[[ "$INV_COMPLETE" -eq 1 ]] || COMPLETE=false

printf '# selection\trepo\tsecret_scanning\tpush_protection\tfields\tdetail\n'
LC_ALL=C sort -t $'\t' -k1,1 -k2,2 "$INV" | while IFS=$'\t' read -r sel name id ss pp fields detail; do
  printf '%s\t%s\t%s\t%s\t%s\t%s\n' "$sel" "$name" "$ss" "$pp" "$fields" "$detail"
done
printf 'Owner: %s; repos in scope: %s; Selected: %s; errors: %s; inventory complete: %s (pagination %s)\n' \
  "$OWNER" "$N_ROWS" "$N_TARGET" "$N_ERROR" "$COMPLETE" "$INV_PAGINATION"
[[ "$COMPLETE" == true ]] || warn "inventory incomplete: a failed repo-list page or per-repo GET (see error rows)"

if [[ "$APPLY" -eq 0 ]]; then
  printf 'Dry-run: nothing written. Re-run with --apply to enable.\n'
  [[ "$COMPLETE" == true && "$N_ERROR" -eq 0 ]] && exit 0
  exit 1
fi

if [[ "$INV_PAGINATION" != ok ]]; then
  warn "inventory incomplete: the repo list could not be read completely; no writes"
  exit 1
fi

open_journal
# On --resume, from each repo's LAST journal row:
#   done-ids   verified | already-enabled | done-in-journal: completed; never
#              written again by this journal (a later manual rollback is
#              respected, and the done-in-journal row a resume appends keeps
#              counting as completed on every later resume).
#   open-ids   pending | failed (id, ss_before, pp_before): the outcome was
#              not settled; if the repo is now enabled on both fields it is
#              reconciled with a verified row and no PATCH.
DONE_IDS="$WORK/done-ids"
OPEN_IDS="$WORK/open-ids"
: >"$DONE_IDS"
: >"$OPEN_IDS"
if [[ -n "$RESUME" ]]; then
  awk -F'\t' '!/^#/ && NF >= 6 { last[$2] = $6 }
    END { for (i in last) if (last[i] == "verified" || last[i] == "already-enabled" || last[i] == "done-in-journal") print i }' \
    "$JOURNAL" >"$DONE_IDS"
  awk -F'\t' '!/^#/ && NF >= 6 { last[$2] = $6; ssb[$2] = $3; ppb[$2] = $4 }
    END { for (i in last) if (last[i] == "pending" || last[i] == "failed") print i "\t" ssb[i] "\t" ppb[i] }' \
    "$JOURNAL" >"$OPEN_IDS"
fi

# reconcile_repo <repo> <id> <ss_before> <pp_before>: a resumed repo whose
# last journal row is pending/failed and which the inventory saw enabled.
# Refresh; still enabled on both fields => verified (no PATCH); disabled again
# => the normal refresh/PATCH/verify path; anything else => that outcome.
reconcile_repo() {
  local name="$1" id="$2" ssb ppb
  ssb="$(clean_status "$3")" ppb="$(clean_status "$4")"
  if ! api_get "repos/$OWNER/$name"; then
    outcome "$name" "$id" "$ssb" "$ppb" none failed unknown unknown "$API_STATUS" "reconcile on resume: refresh failed: $API_DETAIL"
    return 0
  fi
  if ! read_state "$id"; then
    outcome "$name" "$id" "$ssb" "$ppb" none error unknown unknown - "reconcile on resume: $R_DETAIL"
    return 0
  fi
  case "$R_SEL" in
    skipped-enabled)
      outcome "$name" "$id" "$ssb" "$ppb" none verified "$R_SS" "$R_PP" - \
        "reconciled on resume: enabled at refresh (last journal row was not settled)"
      ;;
    target) process_repo "$name" "$id" ;;
    *) outcome "$name" "$id" "$ssb" "$ppb" none "$R_SEL" "$R_SS" "$R_PP" - "${R_DETAIL:-reconcile on resume: at refresh}" ;;
  esac
}

printf '# result\trepo\tbefore -> after (secret_scanning/push_protection)\thttp\tdetail\n'
while IFS=$'\t' read -r sel name id ss pp fields detail; do
  if [[ "$sel" == skipped-enabled ]]; then
    open="$(awk -F'\t' -v i="$id" '$1 == i { print; exit }' "$OPEN_IDS")"
    [[ -n "$open" ]] || continue
    IFS=$'\t' read -r _ open_ss open_pp <<<"$open"
    reconcile_repo "$name" "$id" "$open_ss" "$open_pp"
    continue
  fi
  [[ "$sel" == target ]] || continue
  if grep -qxF -- "$id" "$DONE_IDS"; then
    outcome "$name" "$id" "$ss" "$pp" none done-in-journal "$ss" "$pp" - "verified or already enabled in $(basename "$JOURNAL")"
    continue
  fi
  process_repo "$name" "$id"
done < <(LC_ALL=C sort -t $'\t' -k2,2 "$INV")

printf 'Verified: %s; already enabled: %s; failed: %s; skipped: %s\n' "$N_VERIFIED" "$N_ALREADY" "$N_FAILED" "$N_SKIPPED"
printf 'Journal: %s\n' "$JOURNAL"
[[ "$COMPLETE" == true && "$N_ERROR" -eq 0 && "$N_FAILED" -eq 0 ]] && exit 0
exit 1
