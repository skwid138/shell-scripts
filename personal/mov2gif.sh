#!/usr/bin/env bash
# mov2gif — convert a video to an optimized GIF using FFmpeg.
#
# Behavior:
#   - Uses FFmpeg's two-pass palette generation method for high-quality output.
#   - Pass 1: generate a palette PNG from the input at the chosen fps/scale.
#   - Pass 2: apply the palette to render the GIF.
#   - Cleans up the temp palette afterwards.
#
# Examples:
#   mov2gif.sh input.mov                # default fps=10, scale=320, output=./input.gif
#   mov2gif.sh -f 5 -s 240 myclip.mov   # 5fps, width=240
#   mov2gif.sh -o /tmp/out.gif clip.mov # explicit output path
#
# Exit codes (per docs/EXIT-CODES.md):
#   0  success
#   1  generic runtime failure (ffmpeg failed)
#   2  usage error (missing input file, bad flag)
#   3  missing dependency (ffmpeg)

set -uo pipefail
source "$(dirname "$0")/../lib/common.sh"

# Defaults.
FPS=10
SCALE=320
OUTPUT=""

usage() {
  cat <<EOF
Usage: mov2gif.sh [OPTIONS] <input_file>

Convert a video file (e.g., .mov) to a high-quality GIF using FFmpeg's
two-pass palette generation.

Arguments:
  input_file              Path to the source video.

Options:
  -h, --help              Show this help and exit.
  -f, --fps NUMBER        Frames per second (default: ${FPS}).
  -s, --scale WIDTH       GIF width in pixels (default: ${SCALE}).
                          Height is scaled automatically.
  -o, --output PATH       Output GIF file (default: <input>.gif next to input).

Notes:
  Pick FPS based on clip length:
    Up to ~60s  =>  ~5fps
    Up to ~30s  =>  ~10fps
    Up to ~15s  =>  ~20fps
    Up to ~10s  =>  ~33fps
  Lower FPS yields smaller files but choppier motion.

Examples:
  mov2gif.sh input.mov
  mov2gif.sh -f 5 -s 240 myclip.mov
  mov2gif.sh -o /tmp/out.gif clip.mov
EOF
}

# Parse arguments.
POSITIONAL=()
while [[ $# -gt 0 ]]; do
  case "$1" in
    -h | --help)
      usage
      exit 0
      ;;
    -f | --fps)
      [[ -n "${2:-}" ]] || die_usage "--fps requires a value"
      FPS="$2"
      shift 2
      ;;
    -s | --scale)
      [[ -n "${2:-}" ]] || die_usage "--scale requires a value"
      SCALE="$2"
      shift 2
      ;;
    -o | --output)
      [[ -n "${2:-}" ]] || die_usage "--output requires a value"
      OUTPUT="$2"
      shift 2
      ;;
    -*)
      die_usage "unknown flag: $1 (try --help)"
      ;;
    *)
      POSITIONAL+=("$1")
      shift
      ;;
  esac
done

if [[ ${#POSITIONAL[@]} -lt 1 ]]; then
  die_usage "missing input file (try --help)"
fi

require_cmd "ffmpeg" "brew install ffmpeg"

INPUT_FILE="${POSITIONAL[0]}"

# Derive default output filename if not supplied.
if [[ -z "$OUTPUT" ]]; then
  BASENAME="${INPUT_FILE%.*}"
  OUTPUT="${BASENAME}.gif"
fi

# Temporary palette file.
PALETTE="/tmp/palette-$$.png"

# Pass 1: generate palette.
# -nostdin is critical: without it, ffmpeg consumes its inherited stdin,
# which silently breaks callers that pipe data into us (e.g. gif_jif.sh
# feeds its fps cascade via a herestring; ffmpeg would drain those lines
# on the first encode and the cascade would never advance past fps[0]).
ffmpeg -nostdin -y -i "$INPUT_FILE" \
  -vf "fps=${FPS},scale=${SCALE}:-1:force_original_aspect_ratio=decrease,palettegen" \
  "$PALETTE" || die "ffmpeg palette generation failed"

# Pass 2: apply palette to create GIF.
ffmpeg -nostdin -y -i "$INPUT_FILE" -i "$PALETTE" \
  -lavfi "fps=${FPS},scale=${SCALE}:-1:force_original_aspect_ratio=decrease[x]; [x][1:v] paletteuse" \
  "$OUTPUT" || die "ffmpeg gif render failed"

# Clean up.
rm -f "$PALETTE"

echo "GIF created: $OUTPUT"
