#!/usr/bin/env bats
# CLI tests for personal/gif_jif.sh
#
# `ffmpeg` and `ffprobe` are stubbed via PATH override. The ffmpeg stub
# also handles being invoked recursively through mov2gif.sh — it ignores
# pass-1 (palettegen) calls and on pass-2 (paletteuse) it materializes
# the requested output file at a controllable size.
#
# Mock contract (env vars):
#   MOCK_FFPROBE_W, MOCK_FFPROBE_H, MOCK_FFPROBE_FPS, MOCK_FFPROBE_DUR
#       Values for the ffprobe stub to print. Defaults provided.
#   MOCK_FFMPEG_OUTPUT_SIZES
#       Colon-separated list of bytes for successive paletteuse calls.
#       Each call consumes one entry; if exhausted, the last is reused.
#   STATEFILE
#       Path to a log file. Each ffmpeg invocation writes one line.

setup() {
  load 'test_helper/bats-support/load'
  load 'test_helper/bats-assert/load'
  SCRIPT="$BATS_TEST_DIRNAME/../personal/gif_jif.sh"

  STUBDIR="$(mktemp -d)"
  STATEFILE="$STUBDIR/calls.log"
  COUNTERFILE="$STUBDIR/ffmpeg.count"
  : >"$STATEFILE"
  : >"$COUNTERFILE"

  # Defaults: 1280x720 @ 30fps, 8s duration.
  export MOCK_FFPROBE_W="${MOCK_FFPROBE_W:-1280}"
  export MOCK_FFPROBE_H="${MOCK_FFPROBE_H:-720}"
  export MOCK_FFPROBE_FPS="${MOCK_FFPROBE_FPS:-30/1}"
  export MOCK_FFPROBE_DUR="${MOCK_FFPROBE_DUR:-8.0}"
  export MOCK_FFMPEG_OUTPUT_SIZES="${MOCK_FFMPEG_OUTPUT_SIZES:-1024}"

  export STATEFILE COUNTERFILE STUBDIR
  export PATH="$STUBDIR:$PATH"
}

teardown() {
  [[ -d "$STUBDIR" ]] && rm -rf "$STUBDIR"
}

write_stubs() {
  cat >"$STUBDIR/ffprobe" <<'EOF'
#!/usr/bin/env bash
echo "ffprobe $*" >>"$STATEFILE"
cat <<EOT
width=$MOCK_FFPROBE_W
height=$MOCK_FFPROBE_H
r_frame_rate=$MOCK_FFPROBE_FPS
duration=$MOCK_FFPROBE_DUR
EOT
exit 0
EOF
  chmod +x "$STUBDIR/ffprobe"

  cat >"$STUBDIR/ffmpeg" <<'EOF'
#!/usr/bin/env bash
# Log every call.
echo "ffmpeg $*" >>"$STATEFILE"

# Identify the output path: it's the last argument that ends in .gif or
# is a /tmp/palette-*.png file. We materialize a file at that path.
out=""
is_paletteuse=0
for arg in "$@"; do
  case "$arg" in
    *paletteuse*) is_paletteuse=1 ;;
  esac
done

# The actual output filename is the final arg.
eval "out=\${$#}"

# Pass-1 (palettegen): just create the palette PNG (no size tracking).
if [[ "$is_paletteuse" -eq 0 ]]; then
  case "$out" in
    /tmp/palette-*.png) : >"$out" ;;
  esac
  exit 0
fi

# Pass-2 (paletteuse): materialize at controlled size, increment counter.
n=$(($(cat "$COUNTERFILE" 2>/dev/null || echo 0) + 1))
echo "$n" >"$COUNTERFILE"

# Pick size: nth entry of MOCK_FFMPEG_OUTPUT_SIZES (colon-delimited),
# clamped to last value if list is shorter.
IFS=':' read -r -a sizes <<<"$MOCK_FFMPEG_OUTPUT_SIZES"
idx=$((n - 1))
if [[ "$idx" -ge "${#sizes[@]}" ]]; then idx=$((${#sizes[@]} - 1)); fi
size="${sizes[$idx]}"

# Truncate to requested size (portable across macOS/Linux).
if command -v truncate >/dev/null 2>&1; then
  truncate -s "$size" "$out"
else
  # macOS fallback via dd (no truncate by default).
  dd if=/dev/zero of="$out" bs=1 count=0 seek="$size" 2>/dev/null
fi
exit 0
EOF
  chmod +x "$STUBDIR/ffmpeg"
}

@test "gif_jif: --help exits 0 and mentions any video format" {
  write_stubs
  run "$SCRIPT" --help
  assert_success
  assert_output --partial "Usage:"
  assert_output --partial "any video format"
}

@test "gif_jif: missing input file exits 2" {
  write_stubs
  run "$SCRIPT" --pr
  assert_failure 2
  assert_output --partial "missing input"
}

@test "gif_jif: nonexistent input file exits 2" {
  write_stubs
  run "$SCRIPT" --pr /no/such/file.mov
  assert_failure 2
  assert_output --partial "not found"
}

@test "gif_jif: no preset selected exits 2" {
  write_stubs
  input="$BATS_TEST_TMPDIR/clip.mov"
  : >"$input"
  run "$SCRIPT" "$input"
  assert_failure 2
  assert_output --partial "no preset"
}

@test "gif_jif: unknown flag exits 2" {
  write_stubs
  run "$SCRIPT" --bogus
  assert_failure 2
  assert_output --partial "unknown flag"
}

@test "gif_jif: -o with multiple presets exits 2" {
  write_stubs
  input="$BATS_TEST_TMPDIR/clip.mov"
  : >"$input"
  run "$SCRIPT" --pr --slack -o /tmp/x.gif "$input"
  assert_failure 2
  assert_output --partial "exactly one preset"
}

@test "gif_jif: --fps with multiple presets exits 2" {
  write_stubs
  input="$BATS_TEST_TMPDIR/clip.mov"
  : >"$input"
  run "$SCRIPT" --pr --slack --fps 10 "$input"
  assert_failure 2
  assert_output --partial "exactly one preset"
}

@test "gif_jif: --scale with multiple presets exits 2" {
  write_stubs
  input="$BATS_TEST_TMPDIR/clip.mov"
  : >"$input"
  run "$SCRIPT" --pr --slack --scale 480 "$input"
  assert_failure 2
  assert_output --partial "exactly one preset"
}

@test "gif_jif: --max-size garbage exits 2" {
  write_stubs
  input="$BATS_TEST_TMPDIR/clip.mov"
  : >"$input"
  run "$SCRIPT" --max-size garbage "$input"
  assert_failure 2
  assert_output --partial "malformed --max-size"
}

@test "gif_jif: --max-size 5MB parses and runs" {
  write_stubs
  export MOCK_FFMPEG_OUTPUT_SIZES="3500000" # ~3.5MB, under 5MB*0.7=3.5MB threshold
  input="$BATS_TEST_TMPDIR/clip.mov"
  : >"$input"
  run "$SCRIPT" --max-size 5MB "$input"
  assert_success
  [[ -f "$BATS_TEST_TMPDIR/clip.custom.gif" ]]
}

@test "gif_jif: --max-size 500KB parses" {
  write_stubs
  export MOCK_FFMPEG_OUTPUT_SIZES="400000"
  input="$BATS_TEST_TMPDIR/clip.mov"
  : >"$input"
  run "$SCRIPT" --max-size 500KB "$input"
  assert_success
}

@test "gif_jif: --max-size 1GB parses" {
  write_stubs
  export MOCK_FFMPEG_OUTPUT_SIZES="900000000"
  input="$BATS_TEST_TMPDIR/clip.mov"
  : >"$input"
  run "$SCRIPT" --max-size 1GB "$input"
  assert_success
}

@test "gif_jif: --max-size raw bytes parses" {
  write_stubs
  export MOCK_FFMPEG_OUTPUT_SIZES="800000"
  input="$BATS_TEST_TMPDIR/clip.mov"
  : >"$input"
  run "$SCRIPT" --max-size 1000000 "$input"
  assert_success
}

@test "gif_jif: single --pr produces basename.pr.gif" {
  write_stubs
  # 8MB output, well under 9.5MB budget but above 70% threshold (6.97MB).
  export MOCK_FFMPEG_OUTPUT_SIZES="8000000"
  input="$BATS_TEST_TMPDIR/clip.mov"
  : >"$input"
  run "$SCRIPT" --pr "$input"
  assert_success
  [[ -f "$BATS_TEST_TMPDIR/clip.pr.gif" ]]
  assert_output --partial "clip.pr.gif"
}

@test "gif_jif: --pr --slack --max produces three files" {
  write_stubs
  # Each preset's first encode lands in budget.
  export MOCK_FFMPEG_OUTPUT_SIZES="8000000:40000000:1000000"
  input="$BATS_TEST_TMPDIR/clip.mov"
  : >"$input"
  run "$SCRIPT" --pr --slack --max "$input"
  assert_success
  [[ -f "$BATS_TEST_TMPDIR/clip.pr.gif" ]]
  [[ -f "$BATS_TEST_TMPDIR/clip.slack.gif" ]]
  [[ -f "$BATS_TEST_TMPDIR/clip.max.gif" ]]
}

@test "gif_jif: stdout has one line per created file" {
  write_stubs
  export MOCK_FFMPEG_OUTPUT_SIZES="8000000:40000000:1000000"
  input="$BATS_TEST_TMPDIR/clip.mov"
  : >"$input"
  # Use bash directly to separate stdout from stderr.
  stdout_file="$BATS_TEST_TMPDIR/stdout.txt"
  bash "$SCRIPT" --pr --slack --max "$input" >"$stdout_file" 2>/dev/null
  rc=$?
  [[ "$rc" -eq 0 ]]
  count="$(wc -l <"$stdout_file" | tr -d ' ')"
  [[ "$count" -eq 3 ]]
  grep -q "clip.pr.gif" "$stdout_file"
  grep -q "clip.slack.gif" "$stdout_file"
  grep -q "clip.max.gif" "$stdout_file"
}

@test "gif_jif: budget hit on first iteration -> single paletteuse call" {
  write_stubs
  # 8MB, within [6.97MB, 9.5MB] sweet spot for --pr.
  export MOCK_FFMPEG_OUTPUT_SIZES="8000000"
  input="$BATS_TEST_TMPDIR/clip.mov"
  : >"$input"
  run "$SCRIPT" --pr "$input"
  assert_success
  # Only one paletteuse pass-2 call should have happened.
  paletteuse_calls="$(grep -c paletteuse "$STATEFILE" || true)"
  [[ "$paletteuse_calls" -eq 1 ]]
}

@test "gif_jif: budget exceeded then converges" {
  write_stubs
  # First encode: 20MB (over --pr's 9.5MB). Second: 8MB (in sweet spot).
  export MOCK_FFMPEG_OUTPUT_SIZES="20000000:8000000"
  input="$BATS_TEST_TMPDIR/clip.mov"
  : >"$input"
  run "$SCRIPT" --pr "$input"
  assert_success
  [[ -f "$BATS_TEST_TMPDIR/clip.pr.gif" ]]
  paletteuse_calls="$(grep -c paletteuse "$STATEFILE" || true)"
  [[ "$paletteuse_calls" -eq 2 ]]
  # Final size should be the second value (8MB).
  size="$(stat -f%z "$BATS_TEST_TMPDIR/clip.pr.gif" 2>/dev/null || stat -c%s "$BATS_TEST_TMPDIR/clip.pr.gif")"
  [[ "$size" -eq 8000000 ]]
}

@test "gif_jif: budget unreachable + non-TTY scales down without hang" {
  write_stubs
  # All iterations return oversized output; mock stays oversized through
  # the scale-down retry too. Script must NOT hang and must produce a file.
  export MOCK_FFMPEG_OUTPUT_SIZES="50000000"
  input="$BATS_TEST_TMPDIR/clip.mov"
  : >"$input"
  # Run with stdin closed (non-TTY) and capture stderr separately.
  stderr_file="$BATS_TEST_TMPDIR/stderr.txt"
  bash "$SCRIPT" --pr "$input" </dev/null >/dev/null 2>"$stderr_file"
  # File should exist regardless.
  [[ -f "$BATS_TEST_TMPDIR/clip.pr.gif" ]]
  grep -q "non-TTY" "$stderr_file"
}

@test "gif_jif: .mp4 input accepted" {
  write_stubs
  export MOCK_FFMPEG_OUTPUT_SIZES="8000000"
  input="$BATS_TEST_TMPDIR/clip.mp4"
  : >"$input"
  run "$SCRIPT" --pr "$input"
  assert_success
  [[ -f "$BATS_TEST_TMPDIR/clip.pr.gif" ]]
}

@test "gif_jif: .webm input accepted" {
  write_stubs
  export MOCK_FFMPEG_OUTPUT_SIZES="8000000"
  input="$BATS_TEST_TMPDIR/clip.webm"
  : >"$input"
  run "$SCRIPT" --pr "$input"
  assert_success
  [[ -f "$BATS_TEST_TMPDIR/clip.pr.gif" ]]
}

@test "gif_jif: missing ffprobe exits 3" {
  cat >"$STUBDIR/ffmpeg" <<'EOF'
#!/usr/bin/env bash
exit 0
EOF
  chmod +x "$STUBDIR/ffmpeg"
  # Don't write ffprobe stub.
  input="$BATS_TEST_TMPDIR/clip.mov"
  : >"$input"
  PATH="$STUBDIR:/usr/bin:/bin" run "$SCRIPT" --pr "$input"
  assert_failure 3
  assert_output --partial "ffprobe"
}
