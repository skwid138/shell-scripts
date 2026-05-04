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
# Drain stdin like real ffmpeg does. This is critical regression
# coverage: real ffmpeg consumes its inherited stdin unless invoked
# with -nostdin. If gif_jif fails to redirect stdin or mov2gif drops
# -nostdin, the fps cascade (fed via a herestring) gets silently
# eaten on the first encode and never advances past fps[0]. The stub
# matches that behavior so any regression here is caught by the
# existing cascade tests below.
if [[ ! -t 0 ]]; then
  cat >/dev/null 2>&1 || true
fi

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

# Detect fps from the filter string (looks like "fps=24,scale=...").
fps=""
for arg in "$@"; do
  case "$arg" in
    *fps=*)
      # Extract the digits after the first fps=.
      tmp="${arg#*fps=}"
      fps="${tmp%%,*}"
      break
      ;;
  esac
done
if [[ -n "$fps" ]]; then
  echo "fps=$fps" >>"$STUBDIR/fps_log"
fi

# Per-fps size override (MOCK_FFMPEG_SIZE_AT_FPS_<N>) takes precedence
# over the indexed MOCK_FFMPEG_OUTPUT_SIZES list.
size=""
if [[ -n "$fps" ]]; then
  varname="MOCK_FFMPEG_SIZE_AT_FPS_${fps}"
  size="${!varname:-}"
fi
if [[ -z "$size" ]]; then
  # Pick size: nth entry of MOCK_FFMPEG_OUTPUT_SIZES (colon-delimited),
  # clamped to last value if list is shorter.
  IFS=':' read -r -a sizes <<<"$MOCK_FFMPEG_OUTPUT_SIZES"
  idx=$((n - 1))
  if [[ "$idx" -ge "${#sizes[@]}" ]]; then idx=$((${#sizes[@]} - 1)); fi
  size="${sizes[$idx]}"
fi

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

# --- v2: --dry-run, --verbose, fps cascade -------------------------------

@test "gif_jif: --dry-run --pr exits 0, no files, prints pr fps=N scale=N" {
  write_stubs
  input="$BATS_TEST_TMPDIR/clip.mov"
  : >"$input"
  run "$SCRIPT" --dry-run --pr "$input"
  assert_success
  # No gif file created.
  [[ ! -f "$BATS_TEST_TMPDIR/clip.pr.gif" ]]
  # No paletteuse calls (no encoding happened).
  paletteuse_calls="$(grep -c paletteuse "$STATEFILE" || true)"
  [[ "$paletteuse_calls" -eq 0 ]]
  # Output line format: "pr fps=<N> scale=<N>".
  echo "$output" | grep -qE '^pr fps=[0-9]+ scale=[0-9]+$'
}

@test "gif_jif: --dry-run --pr --slack --max prints three lines, no files" {
  write_stubs
  input="$BATS_TEST_TMPDIR/clip.mov"
  : >"$input"
  stdout_file="$BATS_TEST_TMPDIR/stdout.txt"
  bash "$SCRIPT" --dry-run --pr --slack --max "$input" >"$stdout_file" 2>/dev/null
  rc=$?
  [[ "$rc" -eq 0 ]]
  count="$(wc -l <"$stdout_file" | tr -d ' ')"
  [[ "$count" -eq 3 ]]
  grep -qE '^pr fps=[0-9]+ scale=[0-9]+$' "$stdout_file"
  grep -qE '^slack fps=[0-9]+ scale=[0-9]+$' "$stdout_file"
  grep -qE '^max fps=[0-9]+ scale=[0-9]+$' "$stdout_file"
  [[ ! -f "$BATS_TEST_TMPDIR/clip.pr.gif" ]]
  [[ ! -f "$BATS_TEST_TMPDIR/clip.slack.gif" ]]
  [[ ! -f "$BATS_TEST_TMPDIR/clip.max.gif" ]]
}

@test "gif_jif: --dry-run --max-size 5MB prints custom fps=N scale=N" {
  write_stubs
  input="$BATS_TEST_TMPDIR/clip.mov"
  : >"$input"
  run "$SCRIPT" --dry-run --max-size 5MB "$input"
  assert_success
  echo "$output" | grep -qE '^custom fps=[0-9]+ scale=[0-9]+$'
}

@test "gif_jif: --dry-run without preset exits 2" {
  write_stubs
  input="$BATS_TEST_TMPDIR/clip.mov"
  : >"$input"
  run "$SCRIPT" --dry-run "$input"
  assert_failure 2
  assert_output --partial "no preset"
}

@test "gif_jif: --dry-run honors --fps and --scale overrides" {
  write_stubs
  input="$BATS_TEST_TMPDIR/clip.mov"
  : >"$input"
  run "$SCRIPT" --dry-run --fps 15 --scale 480 --pr "$input"
  assert_success
  echo "$output" | grep -qE '^pr fps=15 scale=480$'
}

@test "gif_jif: --verbose accepted (smoke via dry-run)" {
  write_stubs
  input="$BATS_TEST_TMPDIR/clip.mov"
  : >"$input"
  run "$SCRIPT" --dry-run --verbose --max "$input"
  assert_success
  echo "$output" | grep -qE '^max fps=[0-9]+ scale=[0-9]+$'
}

@test "gif_jif: fps cascade — over budget at fps=30, succeeds at fps=18" {
  write_stubs
  # Force a >10s clip so starting fps is capped at 24 — and we still
  # want fps>=24 to be over budget. Use 11s.
  export MOCK_FFPROBE_DUR="11.0"
  # Per-fps sizing: at fps=24 always over (50MB), at fps=18 in budget (8MB).
  export MOCK_FFMPEG_SIZE_AT_FPS_24="50000000"
  export MOCK_FFMPEG_SIZE_AT_FPS_18="8000000"
  export MOCK_FFMPEG_OUTPUT_SIZES="50000000" # fallback
  input="$BATS_TEST_TMPDIR/clip.mov"
  : >"$input"
  run "$SCRIPT" --pr "$input"
  assert_success
  [[ -f "$BATS_TEST_TMPDIR/clip.pr.gif" ]]
  # Verify cascade reached fps=18.
  grep -q "fps=18" "$STUBDIR/fps_log"
}

@test "gif_jif: fps cascade exhausted — non-TTY produces best-effort file" {
  write_stubs
  # Always over budget, regardless of fps.
  export MOCK_FFMPEG_OUTPUT_SIZES="60000000"
  input="$BATS_TEST_TMPDIR/clip.mov"
  : >"$input"
  stderr_file="$BATS_TEST_TMPDIR/stderr.txt"
  bash "$SCRIPT" --pr "$input" </dev/null >/dev/null 2>"$stderr_file"
  # File exists despite never fitting budget.
  [[ -f "$BATS_TEST_TMPDIR/clip.pr.gif" ]]
  grep -q "non-TTY" "$stderr_file"
  grep -q "budget unreachable" "$stderr_file"
  # Cascade visited multiple fps levels.
  grep -q "fps=18" "$STUBDIR/fps_log"
  grep -q "fps=8" "$STUBDIR/fps_log"
}

@test "gif_jif: user-supplied --fps disables cascade" {
  write_stubs
  # If the cascade ran, fps=18 would yield in-budget output. Setting
  # --fps 30 must NOT cascade — only fps=30 is tried.
  export MOCK_FFMPEG_SIZE_AT_FPS_30="50000000"
  export MOCK_FFMPEG_SIZE_AT_FPS_18="8000000"
  export MOCK_FFMPEG_OUTPUT_SIZES="50000000"
  input="$BATS_TEST_TMPDIR/clip.mov"
  : >"$input"
  stderr_file="$BATS_TEST_TMPDIR/stderr.txt"
  bash "$SCRIPT" --fps 30 --pr "$input" </dev/null >/dev/null 2>"$stderr_file"
  # File still produced (best-effort via budget-unreachable handler).
  [[ -f "$BATS_TEST_TMPDIR/clip.pr.gif" ]]
  # fps=18 must NOT appear in the log — cascade was disabled.
  if grep -q "fps=18" "$STUBDIR/fps_log"; then
    echo "fps=18 unexpectedly present — cascade was not disabled by --fps" >&2
    return 1
  fi
  # fps=30 must appear.
  grep -q "fps=30" "$STUBDIR/fps_log"
  # Budget-unreachable handling kicked in.
  grep -q "budget unreachable" "$stderr_file"
}

# --- v3: stdin-drain regression, output paths, edge cases, portability ---

@test "gif_jif: stdin-drain regression — extra lines on stdin do not break cascade" {
  # Direct regression test for the production bug where ffmpeg, invoked
  # without -nostdin or </dev/null, consumed the herestring feeding the
  # fps cascade loop and silently skipped past fps levels 18/12/8.
  #
  # We pipe a long stdin payload into gif_jif. The bats ffmpeg stub
  # drains stdin to mimic real ffmpeg, so a regression (missing
  # </dev/null in encode_once or missing -nostdin in mov2gif) would
  # let ffmpeg consume the cascade herestring and skip past the first
  # fps level.
  #
  # With the fix in place, all four cascade levels (30, 18, 12, 8) must
  # show up in the fps_log.
  write_stubs
  # Always over budget so the cascade fully exhausts.
  export MOCK_FFMPEG_OUTPUT_SIZES="60000000"
  input="$BATS_TEST_TMPDIR/clip.mov"
  : >"$input"
  stderr_file="$BATS_TEST_TMPDIR/stderr.txt"
  # Pipe garbage into stdin. A correct implementation ignores it; a
  # broken one will let ffmpeg eat the herestring along with this.
  yes | head -n 1000 | bash "$SCRIPT" --pr "$input" >/dev/null 2>"$stderr_file"
  [[ -f "$BATS_TEST_TMPDIR/clip.pr.gif" ]]
  # Default MOCK_FFPROBE_DUR=8.0 so starting fps stays at native 30.
  # Cascade should visit 30, 18, 12, 8 — four unique levels.
  unique_levels="$(sort -u "$STUBDIR/fps_log" | wc -l | tr -d ' ')"
  if [[ "$unique_levels" -lt 4 ]]; then
    echo "expected 4 unique fps levels in cascade, got $unique_levels:" >&2
    cat "$STUBDIR/fps_log" >&2
    return 1
  fi
  # Specifically confirm each cascade level was tried.
  grep -q "^fps=30$" "$STUBDIR/fps_log"
  grep -q "^fps=18$" "$STUBDIR/fps_log"
  grep -q "^fps=12$" "$STUBDIR/fps_log"
  grep -q "^fps=8$" "$STUBDIR/fps_log"
}

@test "gif_jif: -o path is honored for single preset" {
  write_stubs
  export MOCK_FFMPEG_OUTPUT_SIZES="8000000"
  input="$BATS_TEST_TMPDIR/clip.mov"
  : >"$input"
  out="$BATS_TEST_TMPDIR/explicit/custom-name.gif"
  mkdir -p "$BATS_TEST_TMPDIR/explicit"
  run "$SCRIPT" --pr -o "$out" "$input"
  assert_success
  [[ -f "$out" ]]
  # Default-named file must NOT exist when -o is given.
  [[ ! -f "$BATS_TEST_TMPDIR/clip.pr.gif" ]]
  # stdout names the explicit path.
  assert_output --partial "$out"
}

@test "gif_jif: --max-size 0 rejected as usage error" {
  write_stubs
  input="$BATS_TEST_TMPDIR/clip.mov"
  : >"$input"
  run "$SCRIPT" --max-size 0 "$input"
  assert_failure 2
  assert_output --partial "must be > 0"
}

@test "gif_jif: --max-size 1.5MB (decimal) parses and runs" {
  write_stubs
  # 1.5MB = 1572864 bytes. Use a size in the [70%, 100%] sweet spot.
  export MOCK_FFMPEG_OUTPUT_SIZES="1300000"
  input="$BATS_TEST_TMPDIR/clip.mov"
  : >"$input"
  run "$SCRIPT" --max-size 1.5MB "$input"
  assert_success
  [[ -f "$BATS_TEST_TMPDIR/clip.custom.gif" ]]
}

@test "gif_jif: native fps capped at 24 when duration > 10s" {
  write_stubs
  export MOCK_FFPROBE_FPS="60/1"
  export MOCK_FFPROBE_DUR="11.0"
  input="$BATS_TEST_TMPDIR/clip.mov"
  : >"$input"
  run "$SCRIPT" --dry-run --pr "$input"
  assert_success
  echo "$output" | grep -qE '^pr fps=24 scale=[0-9]+$'
}

@test "gif_jif: native fps NOT capped when duration <= 10s" {
  write_stubs
  export MOCK_FFPROBE_FPS="60/1"
  export MOCK_FFPROBE_DUR="9.0"
  input="$BATS_TEST_TMPDIR/clip.mov"
  : >"$input"
  run "$SCRIPT" --dry-run --max "$input"
  assert_success
  # Short clips keep native fps.
  echo "$output" | grep -qE '^max fps=60 scale=[0-9]+$'
}

@test "gif_jif: --scale 240 (floor boundary) does not infinite-loop" {
  write_stubs
  # Always over budget. With --scale 240 the search starts at the floor,
  # so the binary search must exit immediately rather than loop.
  export MOCK_FFMPEG_OUTPUT_SIZES="60000000"
  input="$BATS_TEST_TMPDIR/clip.mov"
  : >"$input"
  # Run with a timeout safety net via background + kill, but really just
  # rely on bats' own timeout. If this test hangs, the script is broken.
  bash "$SCRIPT" --scale 240 --pr "$input" </dev/null >/dev/null 2>/dev/null
  [[ -f "$BATS_TEST_TMPDIR/clip.pr.gif" ]]
}

@test "gif_jif: tmpfile cleaned up when ffmpeg fails mid-encode" {
  # Stub ffmpeg to fail on paletteuse so encode_once returns nonzero.
  cat >"$STUBDIR/ffprobe" <<'EOF'
#!/usr/bin/env bash
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
if [[ ! -t 0 ]]; then cat >/dev/null 2>&1 || true; fi
# Pass 1 (palettegen): succeed and create the palette so pass 2 starts.
for arg in "$@"; do
  case "$arg" in
    *paletteuse*) exit 1 ;; # always fail pass-2
    /tmp/palette-*.png) : >"$arg" ;;
  esac
done
exit 0
EOF
  chmod +x "$STUBDIR/ffmpeg"

  input="$BATS_TEST_TMPDIR/clip.mov"
  : >"$input"
  run "$SCRIPT" --pr "$input"
  assert_failure 1
  # No leaked tmpfile in /tmp matching our PID prefix.
  leaked="$(ls /tmp/gif_jif-*-pr.gif 2>/dev/null | wc -l | tr -d ' ')"
  [[ "$leaked" -eq 0 ]]
  # No final output file either.
  [[ ! -f "$BATS_TEST_TMPDIR/clip.pr.gif" ]]
}

@test "gif_jif: r_frame_rate=0/0 falls back to fps=30" {
  write_stubs
  # Some sources (still images, weird containers) report 0/0 fps.
  # The script must not divide-by-zero or carry a 0 fps forward.
  export MOCK_FFPROBE_FPS="0/0"
  input="$BATS_TEST_TMPDIR/clip.mov"
  : >"$input"
  run "$SCRIPT" --dry-run --max "$input"
  assert_success
  echo "$output" | grep -qE '^max fps=30 scale=[0-9]+$'
}

@test "gif_jif: portable filesize — works when only GNU stat -c%s available" {
  write_stubs
  # Shadow `stat` with a stub that only honors -c%s (GNU semantics) and
  # fails on -f%z (BSD semantics). Confirms the fallback branch in
  # filesize() works on Linux even though dev is on macOS.
  cat >"$STUBDIR/stat" <<'EOF'
#!/usr/bin/env bash
# Reject BSD-style -f%z, accept GNU -c%s.
case "$1" in
  -f%z) exit 1 ;;
  -c%s)
    # Use wc -c for a portable byte count.
    wc -c <"$2" | tr -d ' '
    exit 0
    ;;
  *) exit 2 ;;
esac
EOF
  chmod +x "$STUBDIR/stat"
  export MOCK_FFMPEG_OUTPUT_SIZES="8000000"
  input="$BATS_TEST_TMPDIR/clip.mov"
  : >"$input"
  run "$SCRIPT" --pr "$input"
  assert_success
  [[ -f "$BATS_TEST_TMPDIR/clip.pr.gif" ]]
}
