#!/bin/bash

## Count all files including hidden in a given directory
countf() {
  ls -lAR "$1" | grep '^-' | wc -l
}

## Count all non-hidden files in a given directory
countf_a() {
  ls -lR \$1 | grep '^-' | wc -l
}

## Debug key codes
key_debug() {
  echo "Press any key combination to see its code (Ctrl+C to exit)"
  while true; do
    read -k 1
    echo -n "$REPLY" | hexdump -C
  done
}

## Convert a video's format to a different format using FFmpeg
## Example: clipflip input.mov output.mp4
# The first argument is the input file, and the second argument is the output file
clipflip() {
  local input="$1"
  local output="$2"
  ffmpeg -i "$input" -c:v libx264 -c:a aac "$output"
}
