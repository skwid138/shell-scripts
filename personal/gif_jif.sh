#!/usr/bin/env bash
# gif_jif — budget-aware wrapper around mov2gif.sh.
#
# Probes the input video, then for each requested preset encodes a GIF
# (via mov2gif.sh) and binary-searches the scale until the output fits
# the preset's byte budget.
#
# Presets (see --help for full rationale):
#   --max     unlimited budget; native fps + scale; one-shot.
#   --slack   50MB budget, 1000px cap (smooth Slack inline playback).
#   --pr      9.5MB budget, 1280px cap (under GitHub's 10MB attachment limit).
#   --max-size SIZE  custom byte budget (e.g. 8MB, 500KB, 1GB, 9961472).
#
# Each preset produces <basename>.<preset>.gif. --max-size produces
# <basename>.custom.gif. With a single preset, -o overrides the path.
#
# Exit codes (per docs/EXIT-CODES.md):
#   0  all gifs created
#   1  ffmpeg/ffprobe runtime failure, or user chose [q]uit at budget prompt
#   2  usage error (bad args, no preset, conflicting flags, malformed --max-size)
#   3  ffmpeg or ffprobe missing

set -uo pipefail
# shellcheck source=../lib/common.sh
source "$(dirname "$0")/../lib/common.sh"

MOV2GIF="$(dirname "$0")/mov2gif.sh"

# Preset budgets in bytes and pixel caps. Kept as a `case` function rather
# than an associative array (bash 3.2 portability — see CONVENTIONS.md).
preset_budget() {
  case "$1" in
    max) echo "0" ;;          # 0 = unlimited
    slack) echo "52428800" ;; # 50 MB
    pr) echo "9961472" ;;     # 9.5 MB
    custom) echo "$CUSTOM_BUDGET" ;;
    *) return 1 ;;
  esac
}

preset_dim_cap() {
  case "$1" in
    max) echo "0" ;; # 0 = unlimited
    slack) echo "1000" ;;
    pr) echo "1280" ;;
    custom) echo "0" ;; # custom: no dim cap, only byte budget
    *) return 1 ;;
  esac
}

usage() {
  cat <<'EOF'
Usage: gif_jif.sh [PRESETS...] [OPTIONS] <input_file>

Budget-aware wrapper around mov2gif.sh. Probes the input and binary-
searches scale until each requested preset's byte budget is met.

Accepts any video format ffmpeg can decode (.mov, .mp4, .webm, .mkv,
.avi, etc.). Extension-agnostic.

Presets (one or more required; can be combined):
  --max         Unlimited budget; native fps + scale; one-shot encode.
  --slack       50MB budget, 1000px cap.
                Slack's actual upload limit is 1GB, but inline GIF
                playback gets choppy above ~50MB; 1000px keeps preview
                rendering smooth.
  --pr          9.5MB budget, 1280px cap.
                GitHub PR/issue attachment limit is 10MB; 9.5MB leaves
                headroom for the multipart wrapper.
  --max-size SIZE
                Custom byte budget. Accepts 8MB, 500KB, 1GB, or raw
                bytes (e.g. 9961472). Output is <basename>.custom.gif.

Options:
  -h, --help            Show this help.
  -f, --fps N           Override fps (single-preset only).
  -s, --scale N         Override starting scale in px (single-preset only).
  -o, --output PATH     Output path. Only valid with exactly one preset.

Output:
  One line per created file path on stdout (composes with xargs).
  Progress and warnings go to stderr.

Examples:
  gif_jif.sh clip.mov --pr
  gif_jif.sh clip.mp4 --pr --slack --max
  gif_jif.sh clip.webm --max-size 8MB
  gif_jif.sh clip.mov --pr -o /tmp/out.gif

Exit codes:
  0 success    1 runtime/quit    2 usage    3 missing dep
EOF
}

# parse_size <input> -> echo bytes (or return 1).
# Accepts: 9961472, 8MB, 500KB, 1GB, 1.5MB. Case-insensitive suffix.
parse_size() {
  local in="$1"
  [[ -n "$in" ]] || return 1
  # Lowercase via tr (bash 3.2 portable; no ${var,,}).
  local lc
  lc="$(printf '%s' "$in" | tr '[:upper:]' '[:lower:]')"
  local num suffix
  if [[ "$lc" =~ ^([0-9]+(\.[0-9]+)?)([kmg]?b?)?$ ]]; then
    num="${BASH_REMATCH[1]}"
    suffix="${BASH_REMATCH[3]}"
  else
    return 1
  fi
  local mult=1
  case "$suffix" in
    "" | b) mult=1 ;;
    k | kb) mult=1024 ;;
    m | mb) mult=1048576 ;;
    g | gb) mult=1073741824 ;;
    *) return 1 ;;
  esac
  # Use awk for float * int -> int.
  awk -v n="$num" -v m="$mult" 'BEGIN { printf "%d\n", n * m }'
}

# --- arg parse ---
PRESETS=()
CUSTOM_BUDGET=""
USE_CUSTOM=0
USER_FPS=""
USER_SCALE=""
OUTPUT=""
ARGS=()

while [[ $# -gt 0 ]]; do
  case "$1" in
    -h | --help)
      usage
      exit 0
      ;;
    --max)
      PRESETS+=("max")
      shift
      ;;
    --slack)
      PRESETS+=("slack")
      shift
      ;;
    --pr)
      PRESETS+=("pr")
      shift
      ;;
    --max-size)
      [[ -n "${2:-}" ]] || die_usage "--max-size requires a value"
      if ! CUSTOM_BUDGET="$(parse_size "$2")"; then
        die_usage "malformed --max-size value: $2 (try 8MB, 500KB, 1GB, or raw bytes)"
      fi
      [[ "$CUSTOM_BUDGET" -gt 0 ]] || die_usage "--max-size must be > 0 bytes"
      USE_CUSTOM=1
      shift 2
      ;;
    -f | --fps)
      [[ -n "${2:-}" ]] || die_usage "--fps requires a value"
      USER_FPS="$2"
      shift 2
      ;;
    -s | --scale)
      [[ -n "${2:-}" ]] || die_usage "--scale requires a value"
      USER_SCALE="$2"
      shift 2
      ;;
    -o | --output)
      [[ -n "${2:-}" ]] || die_usage "--output requires a value"
      OUTPUT="$2"
      shift 2
      ;;
    --)
      shift
      while [[ $# -gt 0 ]]; do
        ARGS+=("$1")
        shift
      done
      break
      ;;
    -*) die_usage "unknown flag: $1 (try --help)" ;;
    *)
      ARGS+=("$1")
      shift
      ;;
  esac
done

if [[ "$USE_CUSTOM" -eq 1 ]]; then
  PRESETS+=("custom")
fi

[[ ${#PRESETS[@]} -ge 1 ]] || die_usage "no preset selected (try --pr, --slack, --max, or --max-size; see --help)"
[[ ${#ARGS[@]} -ge 1 ]] || die_usage "missing input file (try --help)"
[[ ${#ARGS[@]} -le 1 ]] || die_usage "expected one input file, got ${#ARGS[@]}"

INPUT="${ARGS[0]}"
[[ -f "$INPUT" ]] || die_usage "input file not found: $INPUT"

# Multi-preset constraint checks.
if [[ ${#PRESETS[@]} -gt 1 ]]; then
  [[ -z "$OUTPUT" ]] || die_usage "-o/--output requires exactly one preset (got ${#PRESETS[@]})"
  [[ -z "$USER_FPS" ]] || die_usage "--fps requires exactly one preset (got ${#PRESETS[@]})"
  [[ -z "$USER_SCALE" ]] || die_usage "--scale requires exactly one preset (got ${#PRESETS[@]})"
fi

require_cmd "ffmpeg" "brew install ffmpeg"
require_cmd "ffprobe" "brew install ffmpeg"
[[ -x "$MOV2GIF" ]] || die "mov2gif.sh not found or not executable at: $MOV2GIF"

# --- probe ---
probe_input() {
  local out
  if ! out="$(ffprobe -v error -select_streams v:0 \
    -show_entries stream=width,height,r_frame_rate,duration \
    -of default=noprint_wrappers=1 "$INPUT" 2>&1)"; then
    die "ffprobe failed: $out"
  fi
  NATIVE_WIDTH=0
  NATIVE_HEIGHT=0
  local fps_raw=""
  DURATION=0
  while IFS='=' read -r k v; do
    case "$k" in
      width) NATIVE_WIDTH="$v" ;;
      height) NATIVE_HEIGHT="$v" ;;
      r_frame_rate) fps_raw="$v" ;;
      duration) DURATION="$v" ;;
    esac
  done <<<"$out"
  # Parse "30/1" -> 30. Use awk for fractional fps too.
  if [[ "$fps_raw" == */* ]]; then
    NATIVE_FPS="$(awk -v r="$fps_raw" 'BEGIN { split(r, a, "/"); if (a[2]+0 == 0) print 0; else printf "%d\n", a[1]/a[2] }')"
  else
    NATIVE_FPS="${fps_raw%.*}"
  fi
  [[ -n "$NATIVE_FPS" && "$NATIVE_FPS" != "0" ]] || NATIVE_FPS=30
  [[ "$NATIVE_WIDTH" -gt 0 ]] || die "ffprobe: could not determine input width"
}

probe_input
info "probed: ${NATIVE_WIDTH}x${NATIVE_HEIGHT} @ ${NATIVE_FPS}fps, ${DURATION}s"

# Returns integer min(a, b).
imin() { if [[ "$1" -lt "$2" ]]; then echo "$1"; else echo "$2"; fi; }
imax() { if [[ "$1" -gt "$2" ]]; then echo "$1"; else echo "$2"; fi; }

filesize() {
  # Portable file size in bytes (BSD stat on macOS, GNU on Linux).
  if stat -f%z "$1" 2>/dev/null; then return 0; fi
  stat -c%s "$1" 2>/dev/null
}

# encode_once <fps> <scale> <out_path> -> 0 success, nonzero fail.
encode_once() {
  local fps="$1" scale="$2" out="$3"
  if ! "$MOV2GIF" -f "$fps" -s "$scale" -o "$out" "$INPUT" >/dev/null 2>&1; then
    return 1
  fi
  return 0
}

# duration_gt_10s -> rc 0 if duration > 10.
duration_gt_10s() {
  awk -v d="$DURATION" 'BEGIN { exit !(d+0 > 10) }'
}

# encode_for_preset <preset_name> <final_out_path>
# Smart-encodes per the algorithm in --help. Echoes nothing; on success
# leaves the gif at <final_out_path>. On user-quit, deletes file and
# returns 1.
encode_for_preset() {
  local preset="$1"
  local final="$2"
  local budget dim_cap
  budget="$(preset_budget "$preset")" || die "internal: unknown preset $preset"
  dim_cap="$(preset_dim_cap "$preset")" || die "internal: unknown preset $preset"

  # Starting fps.
  local fps
  if [[ -n "$USER_FPS" ]]; then
    fps="$USER_FPS"
  else
    fps="$NATIVE_FPS"
    if duration_gt_10s && [[ "$fps" -gt 24 ]]; then
      fps=24
    fi
  fi

  # Starting scale.
  local scale
  if [[ -n "$USER_SCALE" ]]; then
    scale="$USER_SCALE"
  elif [[ "$dim_cap" -eq 0 ]]; then
    scale="$NATIVE_WIDTH"
  else
    scale="$(imin "$NATIVE_WIDTH" "$dim_cap")"
  fi

  local tmpfile
  tmpfile="/tmp/gif_jif-$$-${preset}.gif"
  # Cleanup tmpfile on function exit if still around.

  info "[$preset] starting: fps=$fps scale=$scale budget=$budget"

  # --- max preset / unlimited budget: one-shot. ---
  if [[ "$budget" -eq 0 ]]; then
    if ! encode_once "$fps" "$scale" "$tmpfile"; then
      rm -f "$tmpfile"
      die "ffmpeg encoding failed (preset=$preset)"
    fi
    mv -f "$tmpfile" "$final"
    return 0
  fi

  # --- budgeted preset: binary-search scale. ---
  # Bounds: floor=240, ceil=cap-or-native.
  local floor=240
  local ceil
  if [[ "$dim_cap" -eq 0 ]]; then
    ceil="$NATIVE_WIDTH"
  else
    ceil="$(imin "$NATIVE_WIDTH" "$dim_cap")"
  fi
  # Ensure scale is within [floor, ceil] to start.
  if [[ "$scale" -gt "$ceil" ]]; then scale="$ceil"; fi
  if [[ "$scale" -lt "$floor" ]]; then scale="$floor"; fi

  local lo="$floor" hi="$ceil"
  local lower_thresh
  # 70% of budget.
  lower_thresh="$(awk -v b="$budget" 'BEGIN { printf "%d\n", b*0.7 }')"

  local last_size=0
  local last_ok_size=0
  local last_ok_scale=0
  local i
  for i in 1 2 3 4 5; do
    if ! encode_once "$fps" "$scale" "$tmpfile"; then
      rm -f "$tmpfile"
      die "ffmpeg encoding failed (preset=$preset, iter=$i)"
    fi
    last_size="$(filesize "$tmpfile")"
    info "[$preset] iter $i: scale=$scale size=$last_size budget=$budget"

    if [[ "$last_size" -le "$budget" ]]; then
      last_ok_size="$last_size"
      last_ok_scale="$scale"
      if [[ "$last_size" -ge "$lower_thresh" ]]; then
        # In sweet spot.
        mv -f "$tmpfile" "$final"
        return 0
      fi
      # Under-budget: try larger scale unless already at ceiling.
      if [[ "$scale" -ge "$ceil" ]]; then
        mv -f "$tmpfile" "$final"
        return 0
      fi
      lo="$scale"
      local next=$(((scale + hi) / 2))
      if [[ "$next" -le "$scale" ]]; then next=$((scale + 1)); fi
      if [[ "$next" -gt "$ceil" ]]; then next="$ceil"; fi
      scale="$next"
    else
      # Over budget: scale down.
      if [[ "$scale" -le "$floor" ]]; then
        # Already at floor; cannot shrink further by binary-search.
        break
      fi
      hi="$scale"
      local next=$(((lo + scale) / 2))
      if [[ "$next" -ge "$scale" ]]; then next=$((scale - 1)); fi
      if [[ "$next" -lt "$floor" ]]; then next="$floor"; fi
      scale="$next"
    fi
  done

  # Exited loop without converging.
  if [[ "$last_size" -le "$budget" ]]; then
    # Last encode is acceptable (under budget but maybe well under).
    mv -f "$tmpfile" "$final"
    return 0
  fi

  # Budget unreachable: tmpfile still oversized. Decide based on TTY.
  warn "[$preset] budget unreachable after 5 iterations (size=$last_size budget=$budget)"

  if [[ -t 0 && -t 1 ]]; then
    local choice=""
    while :; do
      printf 'Budget unreachable for [%s]. [p]roceed (keep oversized), [s]cale-down (one more shrink), [q]uit? ' "$preset" >&2
      if ! IFS= read -r choice; then
        choice="s"
        break
      fi
      case "$choice" in
        p | P | proceed)
          choice="p"
          break
          ;;
        s | S | scale-down)
          choice="s"
          break
          ;;
        q | Q | quit)
          choice="q"
          break
          ;;
      esac
    done
    case "$choice" in
      p)
        mv -f "$tmpfile" "$final"
        return 0
        ;;
      q)
        rm -f "$tmpfile"
        warn "[$preset] user quit"
        return 1
        ;;
      s)
        : # fall through to scale-down retry
        ;;
    esac
  else
    warn "[$preset] non-TTY; falling back to scale-down"
  fi

  # Scale-down retry: halve the scale once more, floor at $floor.
  local retry_scale=$((scale / 2))
  if [[ "$retry_scale" -lt "$floor" ]]; then retry_scale="$floor"; fi
  info "[$preset] scale-down retry: scale=$retry_scale"
  if ! encode_once "$fps" "$retry_scale" "$tmpfile"; then
    rm -f "$tmpfile"
    die "ffmpeg encoding failed during scale-down retry (preset=$preset)"
  fi
  last_size="$(filesize "$tmpfile")"
  if [[ "$last_size" -gt "$budget" ]]; then
    warn "[$preset] still over budget after scale-down (size=$last_size budget=$budget); writing anyway"
  fi
  mv -f "$tmpfile" "$final"
  return 0
}

# --- main loop ---
basename_no_ext() {
  local f="$1"
  local b
  b="$(basename "$f")"
  printf '%s' "${b%.*}"
}

INPUT_BASE="$(basename_no_ext "$INPUT")"
INPUT_DIR="$(dirname "$INPUT")"

CREATED=()
FAIL=0

for preset in "${PRESETS[@]}"; do
  if [[ -n "$OUTPUT" && ${#PRESETS[@]} -eq 1 ]]; then
    final="$OUTPUT"
  else
    final="${INPUT_DIR}/${INPUT_BASE}.${preset}.gif"
  fi
  if encode_for_preset "$preset" "$final"; then
    CREATED+=("$final")
    info "[$preset] wrote $final"
  else
    FAIL=1
  fi
done

# Print created paths (one per line) to stdout.
for p in "${CREATED[@]:-}"; do
  [[ -n "$p" ]] && printf '%s\n' "$p"
done

if [[ "$FAIL" -ne 0 ]]; then
  exit 1
fi
exit 0
