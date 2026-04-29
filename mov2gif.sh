#!/usr/bin/env bash
#
# mov2gif - Convert a video to an optimized GIF using FFmpeg.
#           Utilizes a two-pass palette generation method.

# Default values
FPS=10
SCALE=320
OUTPUT=""

# Print usage instructions
usage() {
    echo "Usage: mov2gif [options] <input_file>"
    echo
    echo "Converts a video file (e.g., .mov) to a high-quality GIF using FFmpeg."
    echo
    echo "Options:"
    echo "  -h, --help              Show this help message and exit."
    echo "  -f, --fps <number>      Frames per second (default: ${FPS})."
    echo "  -s, --scale <width>     GIF width in pixels (default: ${SCALE})."
    echo "                          Height is scaled automatically."
    echo "  -o, --output <path>     Output GIF file name (default: input file name and location with .gif extension)."
    echo
    echo "Notes:"
    echo "  - This script uses a two-pass palette generation for improved color and size."
    echo "  - For best results, you may want to pick an FPS based on video length:"
    echo "      Up to ~60s  => ~5fps"
    echo "      Up to ~30s  => ~10fps"
    echo "      Up to ~15s  => ~20fps"
    echo "      Up to ~10s  => ~33fps"
    echo "    Lower FPS yields smaller files but choppier motion."
    echo
    echo "Examples:"
    echo "  mov2gif input.mov                # uses default FPS=10, scale=320, output=./input.gif"
    echo "  mov2gif -f 5 -s 240 myclip.mov   # 5fps, width=240, auto-scale height, output=./myclip.gif"
    echo
}

# Check if FFmpeg is installed
if ! command -v ffmpeg >/dev/null 2>&1; then
    echo "Error: FFmpeg is not installed or not in your PATH."
    echo "       Please install FFmpeg (e.g., via Homebrew: brew install ffmpeg) and try again."
    exit 1
fi

# Parse arguments
POSITIONAL=()
while [[ $# -gt 0 ]]; do
    case "$1" in
    -h | --help)
        usage
        exit 0
        ;;
    -f | --fps)
        shift
        FPS="$1"
        shift
        ;;
    -s | --scale)
        shift
        SCALE="$1"
        shift
        ;;
    -o | --output)
        shift
        OUTPUT="$1"
        shift
        ;;
    *)
        # Assume anything else is the input file
        POSITIONAL+=("$1")
        shift
        ;;
    esac
done
set -- "${POSITIONAL[@]}" # Restore positional arguments

if [[ ${#POSITIONAL[@]} -lt 1 ]]; then
    echo "Error: Missing input file."
    usage
    exit 1
fi

INPUT_FILE="$1"

# Derive default output filename if not supplied
if [[ -z "$OUTPUT" ]]; then
    # Remove existing extension if any, then add .gif
    BASENAME="${INPUT_FILE%.*}"
    OUTPUT="${BASENAME}.gif"
fi

# Temporary palette file
PALETTE="/tmp/palette-$$.png"

# First pass: Generate palette
ffmpeg -y -i "$INPUT_FILE" \
    -vf "fps=${FPS},scale=${SCALE}:-1:force_original_aspect_ratio=decrease,palettegen" \
    "$PALETTE"

# Second pass: Apply palette to create GIF
ffmpeg -y -i "$INPUT_FILE" -i "$PALETTE" \
    -lavfi "fps=${FPS},scale=${SCALE}:-1:force_original_aspect_ratio=decrease[x]; [x][1:v] paletteuse" \
    "$OUTPUT"

# Clean up
rm -f "$PALETTE"

echo "GIF created: $OUTPUT"
