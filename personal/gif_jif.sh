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
searches scale until each requested preset's byte budget is met. If
scale alone cannot fit the budget, fps is used as a secondary search
lever, cascading through 18, 12, 8 fps before giving up.

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
  -f, --fps N           Override fps (single-preset only). Disables the
                        fps cascade — explicit override wins.
  -s, --scale N         Override starting scale in px (single-preset only).
  -o, --output PATH     Output path. Only valid with exactly one preset.
  -v, --verbose         Pass ffmpeg's progress output through to stderr
                        (otherwise suppressed). Useful for long encodes.
  --dry-run             Probe input and print the starting (fps, scale)
                        per preset without encoding. No files written.
                        Output format: '<preset> fps=N scale=N', one
                        per line. Example:
                          $ gif_jif.sh clip.mov --dry-run --pr --slack
                          pr fps=24 scale=1280
                          slack fps=24 scale=1000

Algorithm (per preset, when a budget applies):
  1. Pick starting fps: native, capped at 24 if duration > 10s.
  2. Binary-search scale within [240, preset_dim_cap] for up to 5
     iterations, looking for output in [70%, 100%] of budget.
  3. If scale floor still exceeds budget, drop fps to the next level
     in the cascade (18 → 12 → 8) and re-search scale.
  4. If even fps=8 at scale=240 exceeds budget, prompt the user (TTY)
     or warn and write best-effort (non-TTY).

Output:
  One line per created file path on stdout (composes with xargs).
  Progress and warnings go to stderr.

Examples:
  gif_jif.sh clip.mov --pr
  gif_jif.sh clip.mp4 --pr --slack --max
  gif_jif.sh clip.webm --max-size 8MB
  gif_jif.sh clip.mov --pr -o /tmp/out.gif
  gif_jif.sh clip.mov --dry-run --pr --slack --max
  gif_jif.sh clip.mov --pr --verbose

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
DRY_RUN=0
VERBOSE_FF=0
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
    -v | --verbose)
      VERBOSE_FF=1
      shift
      ;;
    --dry-run)
      DRY_RUN=1
      shift
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
# When VERBOSE_FF=1, mov2gif's stderr (which carries ffmpeg's progress
# output) is allowed through to the user's terminal. Stdout stays
# suppressed either way (only the "GIF created" line, which we don't
# want polluting our own stdout contract).
encode_once() {
  local fps="$1" scale="$2" out="$3"
  if [[ "$VERBOSE_FF" -eq 1 ]]; then
    if ! "$MOV2GIF" -f "$fps" -s "$scale" -o "$out" "$INPUT" >/dev/null; then
      return 1
    fi
  else
    if ! "$MOV2GIF" -f "$fps" -s "$scale" -o "$out" "$INPUT" >/dev/null 2>&1; then
      return 1
    fi
  fi
  return 0
}

# duration_gt_10s -> rc 0 if duration > 10.
duration_gt_10s() {
  awk -v d="$DURATION" 'BEGIN { exit !(d+0 > 10) }'
}

# starting_fps -> echoes the fps to start at given the user override
# (if any) and duration heuristic.
starting_fps() {
  if [[ -n "$USER_FPS" ]]; then
    printf '%s\n' "$USER_FPS"
    return 0
  fi
  local f="$NATIVE_FPS"
  if duration_gt_10s && [[ "$f" -gt 24 ]]; then
    f=24
  fi
  printf '%s\n' "$f"
}

# starting_scale <preset> -> echoes the scale to start at.
starting_scale() {
  local preset="$1"
  local dim_cap
  dim_cap="$(preset_dim_cap "$preset")" || die "internal: unknown preset $preset"
  if [[ -n "$USER_SCALE" ]]; then
    printf '%s\n' "$USER_SCALE"
  elif [[ "$dim_cap" -eq 0 ]]; then
    printf '%s\n' "$NATIVE_WIDTH"
  else
    imin "$NATIVE_WIDTH" "$dim_cap"
  fi
}

# fps_cascade <starting_fps> -> echoes a unique, descending sorted list
# of fps levels for the cascade. Levels are: starting_fps, 18, 12, 8.
# Duplicates and any level >= starting_fps are dropped after the first.
# Output: one fps per line.
fps_cascade() {
  local start="$1"
  printf '%s\n' "$start"
  local lvl
  for lvl in 18 12 8; do
    if [[ "$lvl" -lt "$start" ]]; then
      printf '%s\n' "$lvl"
    fi
  done
}

# _search_at_fps <fps> <scale_ceil> <budget> <tmpfile>
# Binary-searches scale within [240, scale_ceil] at the given fps for up
# to 5 iterations, looking for a result in [70%, 100%] of budget.
# Sets module-level globals on return:
#   SEARCH_SIZE  - bytes of last encode (the file at $tmpfile)
#   SEARCH_SCALE - scale used for that encode
#   SEARCH_OK    - 1 if last encode is <= budget, 0 otherwise
# Returns 0 always (encoding failures call die internally).
_search_at_fps() {
  local fps="$1" ceil="$2" budget="$3" tmpfile="$4"
  local floor=240
  local scale
  scale="$(starting_scale "$CURRENT_PRESET")"
  if [[ "$scale" -gt "$ceil" ]]; then scale="$ceil"; fi
  if [[ "$scale" -lt "$floor" ]]; then scale="$floor"; fi

  local lo="$floor" hi="$ceil"
  local lower_thresh
  lower_thresh="$(awk -v b="$budget" 'BEGIN { printf "%d\n", b*0.7 }')"

  local last_size=0
  local i
  for i in 1 2 3 4 5; do
    if ! encode_once "$fps" "$scale" "$tmpfile"; then
      rm -f "$tmpfile"
      die "ffmpeg encoding failed (preset=$CURRENT_PRESET, fps=$fps, iter=$i)"
    fi
    last_size="$(filesize "$tmpfile")"
    info "[$CURRENT_PRESET] fps=$fps iter $i: scale=$scale size=$last_size budget=$budget"

    if [[ "$last_size" -le "$budget" ]]; then
      if [[ "$last_size" -ge "$lower_thresh" ]]; then
        SEARCH_SIZE="$last_size"
        SEARCH_SCALE="$scale"
        SEARCH_OK=1
        return 0
      fi
      if [[ "$scale" -ge "$ceil" ]]; then
        SEARCH_SIZE="$last_size"
        SEARCH_SCALE="$scale"
        SEARCH_OK=1
        return 0
      fi
      lo="$scale"
      local next=$(((scale + hi) / 2))
      if [[ "$next" -le "$scale" ]]; then next=$((scale + 1)); fi
      if [[ "$next" -gt "$ceil" ]]; then next="$ceil"; fi
      scale="$next"
    else
      if [[ "$scale" -le "$floor" ]]; then
        # Already at floor; cannot shrink further.
        break
      fi
      hi="$scale"
      local next=$(((lo + scale) / 2))
      if [[ "$next" -ge "$scale" ]]; then next=$((scale - 1)); fi
      if [[ "$next" -lt "$floor" ]]; then next="$floor"; fi
      scale="$next"
    fi
  done

  SEARCH_SIZE="$last_size"
  SEARCH_SCALE="$scale"
  if [[ "$last_size" -le "$budget" ]]; then
    SEARCH_OK=1
  else
    SEARCH_OK=0
  fi
}

# encode_for_preset <preset_name> <final_out_path>
# Smart-encodes per the algorithm in --help. Echoes nothing; on success
# leaves the gif at <final_out_path>. On user-quit, deletes file and
# returns 1.
encode_for_preset() {
  local preset="$1"
  local final="$2"
  CURRENT_PRESET="$preset"
  local budget dim_cap
  budget="$(preset_budget "$preset")" || die "internal: unknown preset $preset"
  dim_cap="$(preset_dim_cap "$preset")" || die "internal: unknown preset $preset"

  local start_fps start_scale
  start_fps="$(starting_fps)"
  start_scale="$(starting_scale "$preset")"

  local tmpfile
  tmpfile="/tmp/gif_jif-$$-${preset}.gif"

  info "[$preset] starting: fps=$start_fps scale=$start_scale budget=$budget"

  # --- max preset / unlimited budget: one-shot. ---
  if [[ "$budget" -eq 0 ]]; then
    if ! encode_once "$start_fps" "$start_scale" "$tmpfile"; then
      rm -f "$tmpfile"
      die "ffmpeg encoding failed (preset=$preset)"
    fi
    mv -f "$tmpfile" "$final"
    return 0
  fi

  # --- budgeted preset: scale binary-search with fps cascade. ---
  local ceil
  if [[ "$dim_cap" -eq 0 ]]; then
    ceil="$NATIVE_WIDTH"
  else
    ceil="$(imin "$NATIVE_WIDTH" "$dim_cap")"
  fi

  # Build fps cascade. User-supplied --fps disables the cascade (the
  # explicit override is the only level we try).
  local cascade
  if [[ -n "$USER_FPS" ]]; then
    cascade="$start_fps"
  else
    cascade="$(fps_cascade "$start_fps")"
  fi

  # Iterate through fps levels. Track the smallest oversized result so
  # that, if every level exhausts, we hand the best one to the
  # budget-unreachable handler.
  local best_size=""
  local best_scale=""
  local best_fps=""
  local final_fps=""
  local fps_level
  while IFS= read -r fps_level; do
    [[ -n "$fps_level" ]] || continue
    SEARCH_SIZE=0
    SEARCH_SCALE=0
    SEARCH_OK=0
    _search_at_fps "$fps_level" "$ceil" "$budget" "$tmpfile"
    if [[ "$SEARCH_OK" -eq 1 ]]; then
      mv -f "$tmpfile" "$final"
      return 0
    fi
    # Over budget at this fps level; remember the smallest size so far.
    if [[ -z "$best_size" || "$SEARCH_SIZE" -lt "$best_size" ]]; then
      best_size="$SEARCH_SIZE"
      best_scale="$SEARCH_SCALE"
      best_fps="$fps_level"
    fi
    final_fps="$fps_level"
  done <<<"$cascade"

  # Cascade exhausted: tmpfile holds whatever the last fps level produced.
  # We've ensured that file is over budget. Report against the smallest
  # we saw.
  warn "[$preset] budget unreachable across fps cascade (best size=$best_size at fps=$best_fps scale=$best_scale, budget=$budget)"

  if [[ -t 0 && -t 1 ]]; then
    local choice=""
    while :; do
      printf 'Budget unreachable for [%s]. [p]roceed (keep oversized), [s]cale-down (drop fps further), [q]uit? ' "$preset" >&2
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
        : # fall through to fps-floor retry
        ;;
    esac
  else
    warn "[$preset] non-TTY; falling back to scale-down"
  fi

  # "Scale-down" branch: drop fps below the cascade floor (6 fps) and
  # retry once at scale=240. This is the last resort. If even this
  # exceeds budget, we write what we got and warn.
  local retry_fps=6
  local retry_scale=240
  info "[$preset] scale-down retry: fps=$retry_fps scale=$retry_scale"
  if ! encode_once "$retry_fps" "$retry_scale" "$tmpfile"; then
    rm -f "$tmpfile"
    die "ffmpeg encoding failed during scale-down retry (preset=$preset)"
  fi
  local last_size
  last_size="$(filesize "$tmpfile")"
  if [[ "$last_size" -gt "$budget" ]]; then
    warn "[$preset] still over budget after fps-floor retry (size=$last_size budget=$budget); writing anyway"
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

# --- dry-run: print starting (fps, scale) per preset and exit. ---
if [[ "$DRY_RUN" -eq 1 ]]; then
  for preset in "${PRESETS[@]}"; do
    s_fps="$(starting_fps)"
    s_scale="$(starting_scale "$preset")"
    printf '%s fps=%s scale=%s\n' "$preset" "$s_fps" "$s_scale"
  done
  exit 0
fi

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
