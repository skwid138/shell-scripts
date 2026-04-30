#!/usr/bin/env bats
# CLI tests for personal/mov2gif.sh
#
# `ffmpeg` is stubbed via PATH override; calls are logged to STATEFILE.

setup() {
  load 'test_helper/bats-support/load'
  load 'test_helper/bats-assert/load'
  SCRIPT="$BATS_TEST_DIRNAME/../personal/mov2gif.sh"

  STUBDIR="$(mktemp -d)"
  STATEFILE="$STUBDIR/calls.log"
  export PATH="$STUBDIR:$PATH"
  export STATEFILE
}

teardown() {
  [[ -d "$STUBDIR" ]] && rm -rf "$STUBDIR"
}

write_ffmpeg_stub() {
  cat >"$STUBDIR/ffmpeg" <<'EOF'
#!/usr/bin/env bash
echo "ffmpeg $*" >>"$STATEFILE"
# When asked to write the palette PNG, materialize it so pass 2 sees it.
for arg in "$@"; do
  case "$arg" in
    /tmp/palette-*.png) : >"$arg" ;;
  esac
done
exit 0
EOF
  chmod +x "$STUBDIR/ffmpeg"
}

@test "mov2gif: --help exits 0 and prints Usage" {
  run "$SCRIPT" --help
  assert_success
  assert_output --partial "Usage:"
}

@test "mov2gif: -h exits 0 and prints Usage" {
  run "$SCRIPT" -h
  assert_success
  assert_output --partial "Usage:"
}

@test "mov2gif: unknown flag exits 2" {
  run "$SCRIPT" --bogus-flag
  assert_failure 2
  assert_output --partial "unknown flag"
}

@test "mov2gif: missing input file exits 2" {
  write_ffmpeg_stub
  run "$SCRIPT"
  assert_failure 2
  assert_output --partial "missing input"
}

@test "mov2gif: happy path runs two ffmpeg passes" {
  write_ffmpeg_stub
  input="$BATS_TEST_TMPDIR/clip.mov"
  : >"$input"
  run "$SCRIPT" "$input"
  assert_success
  run cat "$STATEFILE"
  # Two ffmpeg calls (palette + paletteuse).
  assert_output --partial "palettegen"
  assert_output --partial "paletteuse"
  assert_output --partial "$input"
}

@test "mov2gif: -f and -s flags propagate into ffmpeg filter" {
  write_ffmpeg_stub
  input="$BATS_TEST_TMPDIR/clip.mov"
  : >"$input"
  run "$SCRIPT" -f 7 -s 480 "$input"
  assert_success
  run cat "$STATEFILE"
  assert_output --partial "fps=7"
  assert_output --partial "scale=480"
}

@test "mov2gif: -o overrides default output path" {
  write_ffmpeg_stub
  input="$BATS_TEST_TMPDIR/clip.mov"
  : >"$input"
  out="$BATS_TEST_TMPDIR/custom.gif"
  run "$SCRIPT" -o "$out" "$input"
  assert_success
  run cat "$STATEFILE"
  assert_output --partial "$out"
}

@test "mov2gif: missing ffmpeg on PATH exits 3" {
  input="$BATS_TEST_TMPDIR/clip.mov"
  : >"$input"
  PATH="/usr/bin:/bin" run "$SCRIPT" "$input"
  assert_failure 3
  assert_output --partial "ffmpeg"
}
