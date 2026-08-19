#!/usr/bin/env bash
# Full pipeline: frames -> H.264 -> mux with mix.wav.
# Usage: ./build.sh [output.mp4]      (renders 2565 frames; takes ~15 min)
set -euo pipefail
cd "$(dirname "$0")"
OUT="${1:-pawvis-demo.mp4}"

[ -f audio/mix.wav ] || { echo "audio/mix.wav missing — run ./make_sfx.sh then ./mix.sh"; exit 1; }

echo "==> rendering frames"
rm -rf frames && PAGE=demo.html OUTDIR=frames node render.mjs full

echo "==> encoding $OUT"
ffmpeg -y -v error -framerate 30 -i frames/f%05d.png -i audio/mix.wav \
  -c:v libx264 -preset medium -crf 17 -pix_fmt yuv420p \
  -c:a aac -b:a 192k -shortest -movflags +faststart "$OUT"

ffprobe -v error -show_entries format=duration,size -of default=noprint_wrappers=1 "$OUT"
echo "==> done: $OUT"
