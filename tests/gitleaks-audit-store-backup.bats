#!/usr/bin/env bats
bats_require_minimum_version 1.5.0
# Tests for gitleaks-audit.sh store backup/restore: --set-export-passphrase,
# --export-store, --import-store.
#
# Every run is under `env -i` with a temp HOME (the private store lives in
# $HOME/.config/gitleaks-audit), TMPDIR redirected into the test dir, a
# synthetic USER, and stub `security` / recording `openssl` wrappers through
# the documented GITLEAKS_AUDIT_SECURITY / GITLEAKS_AUDIT_OPENSSL overrides.
# No test touches the real keychain, the real store, or real LaunchAgents.
# Terminal cases run under script(1) for a real pty.
#
# macOS-only (keychain CLI, bsdtar, BSD stat, ACLs). Skipped elsewhere.

setup() {
  load 'test_helper/bats-support/load'
  load 'test_helper/bats-assert/load'

  [[ "$(uname -s)" == "Darwin" ]] || skip "store export/import is macOS-only (keychain, bsdtar, ACLs)"

  SCRIPT="$BATS_TEST_DIRNAME/../personal/gitleaks-audit.sh"
  T="$BATS_TEST_TMPDIR"
  FAKE_HOME="$T/home"
  BASE="$FAKE_HOME/.config/gitleaks-audit"
  STUBS="$T/stubs"
  FIX="$T/fix"
  CALLS="$T/calls.log"
  TMPD="$T/tmp"
  DEST="$T/dest"
  OUTSIDE="$T/outside"
  mkdir -p "$FAKE_HOME" "$STUBS" "$FIX" "$TMPD" "$DEST" "$OUTSIDE"
  /bin/chmod 755 "$FAKE_HOME"
  : >"$CALLS"
  printf 'keep\n' >"$OUTSIDE/sentinel"
  printf 'keep\n' >"$FAKE_HOME/sentinel"

  PASS="test passphrase one"
  printf '%s' "$PASS" >"$FIX/passphrase"
  NOW=2000000000
  TS=20330518T033320Z
  write_stubs
  write_tarbuild
}

teardown() {
  /bin/chmod -RN "$BATS_TEST_TMPDIR" 2>/dev/null
  /bin/chmod -R u+rwx "$BATS_TEST_TMPDIR" 2>/dev/null
  return 0
}

# --- stubs -----------------------------------------------------------------------

write_stubs() {
  # security: records argv (bracketed) and env; never records the secret.
  cat >"$STUBS/security" <<'EOF'
#!/bin/bash
{
  printf 'security'
  printf ' [%s]' "$@"
  printf '\n'
  env | sed 's/^/security-env /'
} >>"$CALLS"
case "${1-}" in
  find-generic-password)
    [[ -f "$FIX/security_sleep" ]] && sleep "$(cat "$FIX/security_sleep")"
    rc="$(cat "$FIX/security_rc" 2>/dev/null || echo 0)"
    if [[ "$rc" -eq 0 ]]; then
      cat "$FIX/passphrase"
      echo
    else
      echo "security: SecKeychainSearchCopyNext: The specified item could not be found in the keychain." >&2
    fi
    exit "$rc"
    ;;
  add-generic-password)
    touch "$FIX/added"
    exit "$(cat "$FIX/security_add_rc" 2>/dev/null || echo 0)"
    ;;
esac
exit 1
EOF
  # openssl: records argv and env, then runs the real one (fd 3 inherited).
  cat >"$STUBS/openssl-rec" <<'EOF'
#!/bin/bash
{
  printf 'openssl'
  printf ' [%s]' "$@"
  printf '\n'
  env | sed 's/^/openssl-env /'
} >>"$CALLS"
exec /usr/bin/openssl "$@"
EOF
  printf '#!/bin/bash\necho 8.30.1\n' >"$STUBS/gitleaks"
  chmod +x "$STUBS/security" "$STUBS/openssl-rec" "$STUBS/gitleaks"
}

# write_tarbuild: $T/tarbuild.pl OUT reads entry specs on stdin, one per line:
#   <typeflag>\t<name>\t<content>[\tkey=value...]
# keys override raw header fields (name/size/mode/chksum/linkname/prefix/
# magic/version) or shape the payload (padbyte=<c>, conceal=<name>: the
# payload is a full header block for <name>). \xHH and \n are decoded.
# Directives: "!noend", "!trailing\t<bytes>", "!truncate\t<n>" (drop n
# bytes from the end of the archive).
write_tarbuild() {
  cat >"$T/tarbuild.pl" <<'EOF'
use strict;
use warnings;
my $out = shift;
sub dec { my $s = shift; $s = "" unless defined $s; $s =~ s/\\x([0-9a-fA-F]{2})/chr(hex($1))/ge; $s =~ s/\\n/\n/g; return $s }
sub ofield { my ($v, $w) = @_; return sprintf("%0*o \0", $w - 2, $v) }
sub header {
  my (%o) = @_;
  my $h = pack("a100 a8 a8 a8 a12 a12 a8 a1 a100 a6 a2 a32 a32 a8 a8 a155 a12",
    $o{name}, $o{mode}, $o{uid}, $o{gid}, $o{size}, $o{mtime}, " " x 8, $o{type},
    $o{linkname}, $o{magic}, $o{version}, "u", "g", ofield(0, 8), ofield(0, 8), $o{prefix}, "");
  my $sum = unpack("%32C*", $h);
  substr($h, 148, 8) = pack("a8", defined $o{chksum} ? $o{chksum} : sprintf("%06o\0 ", $sum));
  return $h;
}
my ($tar, $noend, $trailing, $truncate) = ("", 0, "", 0);
while (my $l = <STDIN>) {
  chomp $l;
  next if $l eq "";
  my @f = split /\t/, $l, -1;
  if ($f[0] eq "!noend") { $noend = 1; next }
  if ($f[0] eq "!trailing") { $trailing = dec($f[1]); next }
  if ($f[0] eq "!truncate") { $truncate = $f[1]; next }
  my ($type, $name, $content, @kv) = @f;
  $content = dec($content);
  my %o = (type => dec($type), name => dec($name), mode => ofield(0644, 8), uid => ofield(501, 8),
    gid => ofield(20, 8), mtime => ofield(1700000000, 12),
    linkname => "", magic => "ustar\0", version => "00", prefix => "");
  my ($padbyte, $conceal) = ("\0", undef);
  for my $kv (@kv) {
    my ($k, $v) = split /=/, $kv, 2;
    $v = dec($v);
    if ($k eq "padbyte") { $padbyte = $v } elsif ($k eq "conceal") { $conceal = $v } else { $o{$k} = $v }
  }
  my $payload = $content;
  if (defined $conceal) {
    $payload = header(%o, type => "0", name => $conceal, size => ofield(0, 12), chksum => undef, linkname => "", prefix => "", magic => "ustar\0", version => "00");
  }
  $o{size} = ofield(length($payload), 12) unless defined $o{size};
  my $pad = (512 - length($payload) % 512) % 512;
  $tar .= header(%o) . $payload . ($padbyte x $pad);
}
$tar .= "\0" x 1024 unless $noend;
$tar .= $trailing;
substr($tar, -$truncate) = "" if $truncate;
open(my $fh, ">", $out) or die "$out: $!";
binmode $fh;
print $fh $tar;
close $fh or die;
EOF
}

# tarbuild <out.tar.gz>: build from the spec on stdin, then gzip it.
tarbuild() {
  /usr/bin/perl "$T/tarbuild.pl" "$T/built.tar" || return 1
  /usr/bin/gzip -c "$T/built.tar" >"$1"
}

# --- runners ---------------------------------------------------------------------

audit_env() {
  printf '%s\n' HOME="$FAKE_HOME" USER=tuser TMPDIR="$TMPD" CALLS="$CALLS" FIX="$FIX" \
    GITLEAKS_AUDIT_BASE_PATH="$STUBS:/usr/bin:/bin:/usr/sbin:/sbin" GITLEAKS_AUDIT_NOW="$NOW" \
    GITLEAKS_AUDIT_SECURITY="${SECURITY_OVR:-$STUBS/security}" GITLEAKS_AUDIT_OPENSSL="$STUBS/openssl-rec" \
    GITLEAKS_AUDIT_SECURITY_TIMEOUT="${SEC_TIMEOUT:-30}" GITLEAKS_AUDIT_PERL="${PERL_OVR:-/usr/bin/perl}" \
    GITLEAKS_AUDIT_TEST_HOOK="${HOOK:-}"
}

# run_audit [args...]: hermetic env, /bin/bash, no stdin (no TTY).
run_audit() {
  local -a envs=()
  local e
  while IFS= read -r e; do envs+=("$e"); done < <(audit_env)
  run --separate-stderr env -i "${envs[@]}" /bin/bash "$SCRIPT" "$@" </dev/null 3>&-
}

# run_tty [args...]: the same under script(1) (a real pty). $T/typed, when
# present, is typed repeatedly until the run ends (read -s discards input
# typed before it starts reading).
run_tty() {
  local -a envs=()
  local e
  while IFS= read -r e; do envs+=("$e"); done < <(audit_env)
  rm -f "$T/tty.done"
  # stdin of script(1) must be a pipe (a FIFO makes its tcgetattr fail with
  # EOPNOTSUPP). The wrapped command marks completion so the feeder stops.
  run bash -c '
    trap "" PIPE
    t="$1"
    shift
    feed() {
      local i
      for i in $(seq 1 80); do
        [[ -e "$t/tty.done" ]] && return 0
        [[ -f "$t/typed" ]] && cat "$t/typed" 2>/dev/null
        sleep 0.25
      done
    }
    feed | /usr/bin/script -q /dev/null /bin/bash -c "\"\$@\"; rc=\$?; touch \"$t/tty.done\"; exit \$rc" _ "$@"
    rc=${PIPESTATUS[1]}
    touch "$t/tty.done"
    exit "$rc"' _ "$T" env -i "${envs[@]}" /bin/bash "$SCRIPT" "$@" 3>&-
}

# --- store fixtures --------------------------------------------------------------

TOML='[extend]
useDefault = true

[[allowlists]]
targetRules = ['"'"'generic-api-key'"'"']
condition = "AND"
paths = ['"'"'^src/x\.json$'"'"']
regexTarget = "line"
regexes = ['"'"'^\n?[ \t]*"key": "[0-9a-f]{40}",?$'"'"']'

ign() { printf '%040d:src/f%d.txt:rule-a:%d' "$1" "$1" "$1"; }

# store_file <relpath-under-base> <content>: a 600 file, parents 700.
store_file() {
  mkdir -p "$(dirname "$BASE/$1")"
  printf '%s\n' "$2" >"$BASE/$1"
  /bin/chmod 600 "$BASE/$1"
}

# mkstore: a valid store with nested repos, both file kinds, protected, config.
mkstore() {
  mkdir -p "$BASE/repos"
  store_file repos/alpha/gitleaks.toml "$TOML"
  store_file repos/alpha/gitleaksignore "$(ign 1)"
  store_file "repos/team x/beta/gitleaksignore" "# comment
$(ign 2)"
  mkdir -p "$BASE/repos/empty-dir"
  store_file protected "# <rel> <fingerprint>
alpha $(ign 3)"
  store_file config "# excludes
vendor/skip"
  find "$FAKE_HOME/.config" -type d -exec /bin/chmod 700 {} +
}

# tree <dir>: one line per node under the store parts of <dir> (repos/,
# protected, config): type, path, mode, ACL presence, sha256 of files.
tree() {
  (
    cd "$1" || exit 1
    for top in repos protected config; do
      [[ -e "$top" || -L "$top" ]] && find "$top" -print
    done | LC_ALL=C sort | while IFS= read -r p; do
      local h=- acl=noacl
      [[ -f "$p" && ! -L "$p" ]] && h="$(shasum -a 256 <"$p" | cut -d' ' -f1)"
      [[ "$(/bin/ls -led "$p" | wc -l | tr -d ' ')" -gt 1 ]] && acl=acl
      printf '%s %s %s %s %s\n' "$(/usr/bin/stat -f %HT "$p")" "$p" "$(/usr/bin/stat -f %Lp "$p")" "$acl" "$h"
    done
  )
}

published() { sed -n 's/^published: //p' <<<"$output"; }
# says / refute_says <text>: the text is (not) in stdout or stderr.
says() {
  grep -qF -- "$1" <<<"$output
${stderr-}" || {
    echo "expected '$1' in: $output ${stderr-}" >&2
    return 1
  }
}
refute_says() {
  if grep -qF -- "$1" <<<"$output
${stderr-}"; then
    echo "unexpected '$1' in: $output ${stderr-}" >&2
    return 1
  fi
}
restore_dirs() { find "$BASE" -maxdepth 1 -name 'restore-*' 2>/dev/null; }
no_acl() { [[ "$(/bin/ls -led "$1" | wc -l | tr -d ' ')" -eq 1 ]]; }

# assert_rejected <rule text>: exit 1, no restore dir, the rule named, the
# sentinels outside untouched, no temp files left.
assert_rejected() {
  assert_failure 1
  [[ -z "$(restore_dirs)" ]] || {
    echo "restore dir created: $(restore_dirs)" >&2
    return 1
  }
  grep -qF -- "$1" <<<"$output
$stderr" || {
    echo "rule '$1' not named in: $output $stderr" >&2
    return 1
  }
  [[ "$(cat "$OUTSIDE/sentinel")" == keep && "$(cat "$FAKE_HOME/sentinel")" == keep ]]
  [[ "$(ls -A "$OUTSIDE")" == sentinel ]]
  [[ -z "$(ls -A "$TMPD")" ]] || {
    echo "temp files left: $(ls -A "$TMPD")" >&2
    return 1
  }
}

# good_plain_archive: export the fixture store as a plain archive; sets ARCH.
good_plain_archive() {
  mkstore
  run_audit --export-store "$DEST" --plain
  assert_success
  ARCH="$(published)"
  [[ -f "$ARCH" ]]
}

# --- help / usage ----------------------------------------------------------------

@test "store backup: --help documents the modes, keychain scope, iCloud, and restore consequences" {
  run_audit --help
  assert_success
  local m
  for m in --set-export-passphrase "--export-store <dest-dir> [--plain]" "--import-store <archive>" \
    "file-based login keychain" "iCloud Keychain (which syncs through the Passwords app)" \
    "does not sync to your other devices" "File Provider" "Advanced Data Protection" "never put the live store" \
    "off this Mac" "GITLEAKS_AUDIT_SECURITY" "GITLEAKS_AUDIT_OPENSSL" "restore-<UTC" "--full"; do
    assert_output --partial -- "$m"
  done
}

@test "store backup: usage errors (missing arguments, --plain without --export-store)" {
  run_audit --export-store
  assert_failure 2
  run_audit --import-store
  assert_failure 2
  run_audit --plain
  assert_failure 2
  run_audit --import-store x --plain
  assert_failure 2
}

# --- passphrase setter -----------------------------------------------------------

@test "store backup: --set-export-passphrase without a TTY is refused and never calls security" {
  run_audit --set-export-passphrase
  assert_failure 1
  grep -q "terminal" <<<"$stderr"
  run grep -c '^security' "$CALLS"
  assert_output "0"
}

@test "store backup: --set-export-passphrase runs add-generic-password -U with -w as the final token (security prompts)" {
  run_tty --set-export-passphrase
  assert_success
  [[ -e "$FIX/added" ]]
  run grep '^security ' "$CALLS"
  assert_output "security [add-generic-password] [-U] [-s] [gitleaks-audit-export] [-a] [tuser] [-w]"
}

# --- passphrase retrieval --------------------------------------------------------

@test "store backup: export looks up the passphrase with find-generic-password and never exposes it in argv or env" {
  mkstore
  run_audit --export-store "$DEST"
  assert_success
  grep -qxF "security [find-generic-password] [-s] [gitleaks-audit-export] [-a] [tuser] [-w]" "$CALLS"
  grep -q '^openssl .*\[-pass\] \[fd:3\]' "$CALLS"
  grep -q '^openssl .*\[-aes-256-cbc\] \[-pbkdf2\] \[-iter\] \[600000\] \[-salt\]' "$CALLS"
  run grep -cF -- "$PASS" "$CALLS"
  assert_output "0"
  run grep -F -- "passphrase" <<<"$(grep '^openssl-env\|^security-env' "$CALLS")"
  assert_output ""
}

@test "store backup: keychain exit 44 says not found and how to set it; other errors and a timeout are hard errors; no artifact" {
  mkstore
  echo 44 >"$FIX/security_rc"
  run_audit --export-store "$DEST"
  assert_failure 1
  says "not found (or search failure"
  says "--set-export-passphrase"
  [[ -z "$(ls -A "$DEST")" ]]

  echo 51 >"$FIX/security_rc"
  run_audit --export-store "$DEST"
  assert_failure 1
  says "keychain lookup failed (security exit 51)"
  refute_says "not found"
  [[ -z "$(ls -A "$DEST")" ]]

  rm "$FIX/security_rc"
  echo 20 >"$FIX/security_sleep"
  local start=$SECONDS
  SEC_TIMEOUT=1 run_audit --export-store "$DEST"
  assert_failure 1
  says "keychain lookup timed out after 1s"
  refute_says "not found"
  [[ $((SECONDS - start)) -lt 15 ]]
  [[ -z "$(ls -A "$DEST")" ]]
  # The passphrase is looked up before the audit lock is even attempted.
  [[ ! -e "$FAKE_HOME/Library/Caches" ]]
}

@test "store backup: import with no TTY never prompts (keychain not found is an error)" {
  mkstore
  run_audit --export-store "$DEST"
  assert_success
  ARCH="$(published)"
  echo 44 >"$FIX/security_rc"
  run_audit --import-store "$ARCH"
  assert_failure 1
  says "no terminal to prompt"
  refute_says "Passphrase for"
  [[ -z "$(restore_dirs)" ]]
}

@test "store backup: import falls back to a terminal prompt when the keychain has no passphrase" {
  mkstore
  run_audit --export-store "$DEST"
  assert_success
  ARCH="$(published)"
  echo 44 >"$FIX/security_rc"
  printf '%s\n' "$PASS" >"$T/typed"
  run_tty --import-store "$ARCH"
  assert_success
  assert_output --partial "Passphrase for"
  [[ -n "$(restore_dirs)" ]]
}

@test "store backup: import with a keychain error other than 44 is a hard error, even with a TTY" {
  mkstore
  run_audit --export-store "$DEST"
  ARCH="$(published)"
  echo 51 >"$FIX/security_rc"
  printf '%s\n' "$PASS" >"$T/typed"
  run_tty --import-store "$ARCH"
  assert_failure 1
  assert_output --partial "keychain lookup failed (security exit 51)"
  refute_output --partial "Passphrase for"
  [[ -z "$(restore_dirs)" ]]
}

# --- round trips -----------------------------------------------------------------

@test "store backup: plain round trip restores the store byte-for-byte (modes, no ACLs, same node set)" {
  mkstore
  run_audit --export-store "$DEST" --plain
  assert_success
  assert_output --partial "published: $DEST/gitleaks-store-$TS.tar.gz"
  grep -q "WARNING: --plain" <<<"$stderr"
  local a
  a="$(published)"
  [[ "$a" == "$DEST/gitleaks-store-$TS.tar.gz" && -f "$a" ]]
  [[ "$(/usr/bin/stat -f %Lp "$a")" == 600 ]]
  no_acl "$a"
  assert_output --partial "sha256: $(shasum -a 256 <"$a" | cut -d' ' -f1)"
  [[ "$(ls -A "$DEST")" == "gitleaks-store-$TS.tar.gz" ]]
  run_audit --import-store "$a"
  assert_success
  local r
  r="$(restore_dirs)"
  [[ "$r" == "$BASE/restore-$TS" ]]
  [[ "$(tree "$r")" == "$(tree "$BASE")" ]]
  [[ -n "$(tree "$BASE")" ]]
  assert_output --partial "mv"
  assert_output --partial "gitleaks-audit.sh --full"
}

@test "store backup: encrypted round trip restores the store byte-for-byte" {
  mkstore
  run_audit --export-store "$DEST"
  assert_success
  local a
  a="$(published)"
  [[ "$a" == "$DEST/gitleaks-store-$TS.tar.gz.enc" ]]
  [[ "$(head -c 8 "$a")" == "Salted__" ]]
  run_audit --import-store "$a"
  assert_success
  [[ "$(tree "$(restore_dirs)")" == "$(tree "$BASE")" ]]
  # Also detected by the Salted__ magic when renamed.
  rm -rf "$(restore_dirs)"
  cp "$a" "$T/renamed.bin"
  run_audit --import-store "$T/renamed.bin"
  assert_success
  [[ "$(tree "$(restore_dirs)")" == "$(tree "$BASE")" ]]
}

@test "store backup: import decrypts with the passphrase on fd 3 only (never in argv or env)" {
  mkstore
  run_audit --export-store "$DEST"
  assert_success
  local a
  a="$(published)"
  : >"$CALLS"
  run_audit --import-store "$a"
  assert_success
  grep -qxF "security [find-generic-password] [-s] [gitleaks-audit-export] [-a] [tuser] [-w]" "$CALLS"
  grep -q '^openssl \[enc\] \[-d\] .*\[-pass\] \[fd:3\]' "$CALLS"
  run grep -cF -- "$PASS" "$CALLS"
  assert_output "0"
}

@test "store backup: export holds only repos/, protected, config and MANIFEST (no review/, restore-*/, or audit state)" {
  mkstore
  mkdir -p "$BASE/review" "$BASE/restore-20300101T000000Z/repos/x" "$FAKE_HOME/Library/Application Support/gitleaks-audit/repos/abc"
  printf 'draft\n' >"$BASE/review/notes"
  printf 'old\n' >"$BASE/restore-20300101T000000Z/repos/x/gitleaksignore"
  printf 'state\n' >"$FAKE_HOME/Library/Application Support/gitleaks-audit/repos/abc/known"
  printf 'x\n' >"$BASE/stray-file"
  find "$BASE" -type d -exec /bin/chmod 700 {} +
  run_audit --export-store "$DEST" --plain
  assert_success
  run /usr/bin/tar -tzf "$(published)"
  assert_success
  local m
  while IFS= read -r m; do
    case "$m" in
      MANIFEST | config | protected | repos/ | repos/*) ;;
      *)
        echo "unexpected member: $m" >&2
        return 1
        ;;
    esac
  done <<<"$output"
  refute_output --partial "review"
  refute_output --partial "restore-"
  refute_output --partial "known"
  refute_output --partial "stray-file"
  assert_line "repos/alpha/gitleaksignore"
  assert_line "MANIFEST"
}

@test "store backup: a wrong passphrase is a decrypt error and creates no restore dir" {
  mkstore
  run_audit --export-store "$DEST"
  ARCH="$(published)"
  printf 'some other passphrase' >"$FIX/passphrase"
  run_audit --import-store "$ARCH"
  assert_rejected "decrypt"
  says "wrong passphrase"
}

# --- export validation -----------------------------------------------------------

@test "store backup: export refuses an unexpected file in the store (no artifact)" {
  mkstore
  store_file repos/alpha/README "notes"
  run_audit --export-store "$DEST" --plain
  assert_failure 1
  says "repos/alpha/README"
  [[ -z "$(ls -A "$DEST")" ]]
  rm "$BASE/repos/alpha/README"
  ln -s "$BASE/protected" "$BASE/repos/alpha/gitleaksignore.link"
  run_audit --export-store "$DEST" --plain
  assert_failure 1
  [[ -z "$(ls -A "$DEST")" ]]
}

@test "store backup: export validates every repo in the store, discovered or not (malformed suppression)" {
  mkstore
  store_file repos/ghost/gitleaks.toml "[[rules]]"
  run_audit --export-store "$DEST" --plain
  assert_failure 1
  says "repos/ghost/gitleaks.toml"
  [[ -z "$(ls -A "$DEST")" ]]
  rm "$BASE/repos/ghost/gitleaks.toml"
  store_file protected "not a manifest line"
  run_audit --export-store "$DEST" --plain
  assert_failure 1
  says "protected"
  [[ -z "$(ls -A "$DEST")" ]]
}

@test "store backup: a 100-byte member name round-trips; 101 bytes fails with no artifact" {
  mkstore
  # repos/<rel>/gitleaksignore is len(rel) + 21 bytes.
  local rel100 rel101
  rel100="$(printf 'r%.0s' $(seq 1 79))"
  rel101="$(printf 'r%.0s' $(seq 1 80))"
  store_file "repos/$rel100/gitleaksignore" "$(ign 4)"
  find "$BASE" -type d -exec /bin/chmod 700 {} +
  run_audit --export-store "$DEST" --plain
  assert_success
  run_audit --import-store "$(published)"
  assert_success
  [[ "$(tree "$(restore_dirs)")" == "$(tree "$BASE")" ]]
  rm -rf "$(restore_dirs)" "${DEST:?}"/*
  store_file "repos/$rel101/gitleaksignore" "$(ign 5)"
  find "$BASE" -type d -exec /bin/chmod 700 {} +
  run_audit --export-store "$DEST" --plain
  assert_failure 1
  says "longer than 100 bytes"
  [[ -z "$(ls -A "$DEST")" ]]
}

@test "store backup: export while another run holds the audit lock exits 75 with no artifact" {
  mkstore
  sleep 60 &
  local holder=$!
  mkdir -p "$FAKE_HOME/Library/Caches/gitleaks-audit.lock"
  printf 'pid=%s\nhost=h\nstarted=%s\n' "$holder" "$(/bin/date -u +%s)" >"$FAKE_HOME/Library/Caches/gitleaks-audit.lock/owner"
  run_audit --export-store "$DEST" --plain
  kill "$holder" 2>/dev/null
  assert_failure 75
  [[ -z "$(ls -A "$DEST")" ]]
}

# --- publication -----------------------------------------------------------------

@test "store backup: a symlinked or dangling destination is refused" {
  mkstore
  ln -s "$DEST" "$T/dest-link"
  run_audit --export-store "$T/dest-link" --plain
  assert_failure 1
  says "symlink"
  ln -s "$T/nowhere" "$T/dangling"
  run_audit --export-store "$T/dangling" --plain
  assert_failure 1
  run_audit --export-store "$T/missing-dir" --plain
  assert_failure 1
  : >"$T/a-file"
  run_audit --export-store "$T/a-file" --plain
  assert_failure 1
  [[ -z "$(ls -A "$DEST")" ]]
}

@test "store backup: an occupied final name (file, dir, symlink to dir, dangling symlink) gets the -2 name; nothing is written into it" {
  mkstore
  local final="$DEST/gitleaks-store-$TS.tar.gz" kind
  mkdir -p "$T/target-dir"
  for kind in file dir dirlink dangling; do
    rm -rf "${final:?}" "$DEST"/gitleaks-store-*
    case "$kind" in
      file) printf 'other\n' >"$final" ;;
      dir) mkdir "$final" ;;
      dirlink) ln -s "$T/target-dir" "$final" ;;
      dangling) ln -s "$T/no-such-target" "$final" ;;
    esac
    run_audit --export-store "$DEST" --plain
    assert_success
    [[ "$(published)" == "$DEST/gitleaks-store-$TS-2.tar.gz" ]]
    [[ -f "$DEST/gitleaks-store-$TS-2.tar.gz" ]]
    case "$kind" in
      file) [[ "$(cat "$final")" == other ]] ;;
      dir) [[ -z "$(ls -A "$final")" ]] ;;
      dirlink) [[ -L "$final" && -z "$(ls -A "$T/target-dir")" ]] ;;
      dangling) [[ -L "$final" && ! -e "$T/no-such-target" ]] ;;
    esac
    [[ -z "$(find "$DEST" -maxdepth 1 -name '.gitleaks-export*')" ]]
  done
}

@test "store backup: a link(2) failure other than EEXIST is a hard error with no artifact" {
  mkstore
  mkdir -p "$T/perl5"
  cat >"$T/perl5/FailLink.pm" <<'EOF'
package FailLink;
use Errno ();
BEGIN { *CORE::GLOBAL::link = sub { $! = Errno::EPERM(); return 0 }; }
1;
EOF
  cat >"$T/eperm-perl" <<EOF
#!/bin/bash
case "\$*" in *"link("*) exec /usr/bin/perl -I"$T/perl5" -MFailLink "\$@" ;; esac
exec /usr/bin/perl "\$@"
EOF
  chmod +x "$T/eperm-perl"
  PERL_OVR="$T/eperm-perl" run_audit --export-store "$DEST" --plain
  assert_failure 1
  says "Operation not permitted"
  [[ -z "$(ls -A "$DEST")" ]]
}

@test "store backup: publication under an inherited ACL: subdir stripped before use, file ACL-free, final name absent mid-write" {
  mkstore
  /bin/chmod +a "everyone allow read,file_inherit,directory_inherit" "$DEST"
  cat >"$T/hook" <<HOOK
#!/bin/bash
case "\$1" in
  subdir-created)
    [[ -z "\$(ls -A "\$2")" ]] && echo "subdir-created empty" >>"$T/seams"
    echo "subdir-created acl-lines=\$(/bin/ls -led "\$2" | wc -l | tr -d ' ')" >>"$T/seams" ;;
  after-strip) echo "after-strip acl-lines=\$(/bin/ls -led "\$2" | wc -l | tr -d ' ') mode=\$(/usr/bin/stat -f %Lp "\$2")" >>"$T/seams" ;;
  file-created) echo "file-created acl-lines=\$(/bin/ls -led "\$2" | wc -l | tr -d ' ') mode=\$(/usr/bin/stat -f %Lp "\$2")" >>"$T/seams" ;;
  mid-write)
    if ls "$DEST"/gitleaks-store-* >/dev/null 2>&1; then echo "mid-write final-present" >>"$T/seams"; else echo "mid-write final-absent" >>"$T/seams"; fi ;;
esac
exit 0
HOOK
  chmod +x "$T/hook"
  HOOK="$T/hook" run_audit --export-store "$DEST"
  assert_success
  run cat "$T/seams"
  assert_output "subdir-created empty
subdir-created acl-lines=2
after-strip acl-lines=1 mode=700
file-created acl-lines=1 mode=600
mid-write final-absent"
  local a
  a="$DEST/gitleaks-store-$TS.tar.gz.enc"
  [[ -f "$a" && "$(/usr/bin/stat -f %Lp "$a")" == 600 ]]
  no_acl "$a"
  [[ "$(ls -A "$DEST")" == "gitleaks-store-$TS.tar.gz.enc" ]]
}

@test "store backup: a failing chmod -N on the publication subdir leaves no subdir, no file, no artifact" {
  mkstore
  cat >"$STUBS/chmod" <<'EOF'
#!/bin/bash
[[ "${1-}" == "-N" && "${2-}" == *"/.gitleaks-export."* ]] && exit 1
exec /bin/chmod "$@"
EOF
  chmod +x "$STUBS/chmod"
  run_audit --export-store "$DEST" --plain
  assert_failure 1
  says "ACL"
  [[ -z "$(ls -A "$DEST")" ]]
}

# --- import rejections -----------------------------------------------------------

@test "store backup: import rejects a harmless member outside the allowlist" {
  printf '5\trepos/\t\n5\trepos/x/\t\n0\trepos/x/README\thello\n' | tarbuild "$T/a.tar.gz"
  run_audit --import-store "$T/a.tar.gz"
  assert_rejected "not in the allowlist"
}

@test "store backup: import rejects symlink, hardlink, fifo, pax and GNU longname entries by typeflag" {
  local spec
  for spec in "2	repos/x/gitleaksignore		linkname=../../../outside/sentinel" \
    "1	repos/x/gitleaksignore		linkname=MANIFEST" \
    "6	repos/x/gitleaksignore	" \
    "x	PaxHeader/MANIFEST	30 path=../outside/sentinel\n" \
    "L	././@LongLink	repos/x/gitleaksignore"; do
    printf '5\trepos/\t\n%s\n0\tMANIFEST\tm\n' "$spec" | tarbuild "$T/a.tar.gz"
    run_audit --import-store "$T/a.tar.gz"
    assert_rejected "typeflag"
  done
}

@test "store backup: import rejects '..', absolute, and empty-component paths" {
  printf '0\trepos/../outside/sentinel\tx\n' | tarbuild "$T/a.tar.gz"
  run_audit --import-store "$T/a.tar.gz"
  assert_rejected "'..'"
  printf '0\t/tmp/abs\tx\n' | tarbuild "$T/a.tar.gz"
  run_audit --import-store "$T/a.tar.gz"
  assert_rejected "absolute"
  printf '0\trepos//gitleaksignore\tx\n' | tarbuild "$T/a.tar.gz"
  run_audit --import-store "$T/a.tar.gz"
  assert_rejected "empty path component"
}

@test "store backup: import rejects duplicate and case-insensitive duplicate members" {
  printf '0\tMANIFEST\ta\n0\tMANIFEST\tb\n' | tarbuild "$T/a.tar.gz"
  run_audit --import-store "$T/a.tar.gz"
  assert_rejected "duplicate member"
  printf '5\trepos/\t\n5\trepos/abc/\t\n5\trepos/ABC/\t\n' | tarbuild "$T/a.tar.gz"
  run_audit --import-store "$T/a.tar.gz"
  assert_rejected "case-insensitive duplicate"
}

@test "store backup: import rejects malformed headers (checksum, base-256, octal, NUL-hidden suffix)" {
  printf '0\tMANIFEST\tm\tchksum=000001\\x00 \n' | tarbuild "$T/a.tar.gz"
  run_audit --import-store "$T/a.tar.gz"
  assert_rejected "checksum"
  printf '0\tMANIFEST\tm\tsize=\\x80\\x00\\x00\\x00\\x00\\x00\\x00\\x00\\x00\\x00\\x00\\x01\n' | tarbuild "$T/a.tar.gz"
  run_audit --import-store "$T/a.tar.gz"
  assert_rejected "base-256"
  printf '0\tMANIFEST\tm\tmode=0006x4 \\x00\n' | tarbuild "$T/a.tar.gz"
  run_audit --import-store "$T/a.tar.gz"
  assert_rejected "octal"
  printf '0\tMANIFEST\\x00../../outside/sentinel\tm\n' | tarbuild "$T/a.tar.gz"
  run_audit --import-store "$T/a.tar.gz"
  assert_rejected "NUL"
  printf '0\tMANIFEST\tm\tmagic=ustar \n' | tarbuild "$T/a.tar.gz"
  run_audit --import-store "$T/a.tar.gz"
  assert_rejected "magic"
  printf '0\tMANIFEST\tm\tprefix=repos\n' | tarbuild "$T/a.tar.gz"
  run_audit --import-store "$T/a.tar.gz"
  assert_rejected "prefix"
}

@test "store backup: import rejects a sized directory concealing a header and a regular entry ending in /" {
  printf '5\trepos/\t\tconceal=repos/x/gitleaksignore\n' | tarbuild "$T/a.tar.gz"
  run_audit --import-store "$T/a.tar.gz"
  assert_rejected "directory entry with nonzero size"
  printf '0\tMANIFEST/\tm\n' | tarbuild "$T/a.tar.gz"
  run_audit --import-store "$T/a.tar.gz"
  assert_rejected "regular entry whose name ends in /"
}

@test "store backup: import rejects truncation, bad padding, and trailing garbage" {
  printf '0\tMANIFEST\t%s\n!noend\n!truncate\t700\n' "$(printf 'm%.0s' $(seq 1 600))" | tarbuild "$T/a.tar.gz"
  run_audit --import-store "$T/a.tar.gz"
  assert_rejected "truncated"
  printf '0\tMANIFEST\tm\tpadbyte=Z\n' | tarbuild "$T/a.tar.gz"
  run_audit --import-store "$T/a.tar.gz"
  assert_rejected "padding"
  printf '0\tMANIFEST\tm\n!trailing\tGARBAGE\n' | tarbuild "$T/a.tar.gz"
  run_audit --import-store "$T/a.tar.gz"
  assert_rejected "trailing data"
}

@test "store backup: import rejects a gzip bomb and an oversize encrypted blob before parsing, and a damaged gzip trailer" {
  head -c 7340032 /dev/zero | /usr/bin/gzip -c >"$T/bomb.tar.gz"
  run_audit --import-store "$T/bomb.tar.gz"
  assert_rejected "exceeds limit"
  refute_says "typeflag"
  head -c 7340032 /dev/zero >"$T/big"
  bash -c 'printf "%s\n" "$1" | /usr/bin/openssl enc -aes-256-cbc -pbkdf2 -iter 600000 -salt -in "$2" -out "$3" -pass fd:3 3<&0 0</dev/null' _ "$PASS" "$T/big" "$T/big.enc"
  rm "$T/big"
  run_audit --import-store "$T/big.enc"
  assert_rejected "exceeds limit"
  good_plain_archive
  local n
  n="$(wc -c <"$ARCH" | tr -d ' ')"
  cp "$ARCH" "$T/damaged.tar.gz"
  printf '\xff\xff\xff\xff' | dd of="$T/damaged.tar.gz" bs=1 seek=$((n - 8)) conv=notrunc 2>/dev/null
  run_audit --import-store "$T/damaged.tar.gz"
  assert_rejected "decompress error"
}

# manifest_archive <out> <manifest-transform>: a store archive (real tar)
# whose MANIFEST is rewritten by the sed expression.
manifest_archive() {
  local s="$T/stage"
  rm -rf "$s"
  mkdir -p "$s/repos/alpha"
  printf '%s\n' "$(ign 1)" >"$s/repos/alpha/gitleaksignore"
  printf '# p\n' >"$s/protected"
  (cd "$s" && shasum -a 256 repos/alpha/gitleaksignore protected) | sed "$2" >"$s/MANIFEST"
  (cd "$s" && COPYFILE_DISABLE=1 /usr/bin/tar --format ustar -c -z -n -f "$1" repos/ repos/alpha/ repos/alpha/gitleaksignore protected MANIFEST)
}

@test "store backup: import verifies MANIFEST both ways (mismatch, missing entry, extra entry)" {
  manifest_archive "$T/ok.tar.gz" 's/x/x/'
  run_audit --import-store "$T/ok.tar.gz"
  assert_success
  rm -rf "$(restore_dirs)"
  manifest_archive "$T/a.tar.gz" 's/^[0-9a-f]\{64\}  protected$/0000000000000000000000000000000000000000000000000000000000000000  protected/'
  run_audit --import-store "$T/a.tar.gz"
  assert_rejected "MANIFEST"
  says "sha256 mismatch"
  manifest_archive "$T/a.tar.gz" '/protected$/d'
  run_audit --import-store "$T/a.tar.gz"
  assert_rejected "not listed in MANIFEST"
  manifest_archive "$T/a.tar.gz" '$a\
0000000000000000000000000000000000000000000000000000000000000000  config'
  run_audit --import-store "$T/a.tar.gz"
  assert_rejected "listed in MANIFEST but not in the archive"
}

@test "store backup: import never touches the live store (bytes, modes, ACLs, node set), present or absent" {
  good_plain_archive
  # Make the live store differ from the archive, and record it.
  store_file repos/alpha/gitleaksignore "$(ign 9)"
  local before
  before="$(tree "$BASE")"
  run_audit --import-store "$ARCH"
  assert_success
  [[ "$(tree "$BASE")" == "$before" ]]
  [[ "$(tree "$(restore_dirs)")" != "$before" ]]
  assert_output --partial "existing store"
  # No live store at all: still none afterwards.
  rm -rf "$BASE"
  run_audit --import-store "$ARCH"
  assert_success
  [[ ! -e "$BASE/repos" && ! -e "$BASE/protected" && ! -e "$BASE/config" ]]
  [[ -n "$(restore_dirs)" ]]
  assert_output --partial "fresh"
  assert_output --partial "audit state is not restored"
}

@test "store backup: a second import the same second gets a unique restore dir" {
  good_plain_archive
  run_audit --import-store "$ARCH"
  assert_success
  run_audit --import-store "$ARCH"
  assert_success
  [[ -d "$BASE/restore-$TS" && -d "$BASE/restore-$TS-2" ]]
}
