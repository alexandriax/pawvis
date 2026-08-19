#!/usr/bin/env bash
# 720p two-pass encode under Discord's 10 MB non-Nitro limit.
set -euo pipefail
cd "$(dirname "$0")"
IN="${1:-pawvis-demo.mp4}"; OUT="${2:-pawvis-demo-discord.mp4}"
ffmpeg -y -v error -i "$IN" -vf scale=1280:720 -c:v libx264 -preset slow -b:v 690k -pass 1 -an -f mp4 /dev/null
ffmpeg -y -v error -i "$IN" -vf scale=1280:720 -c:v libx264 -preset slow -b:v 690k -pass 2 \
  -c:a aac -b:a 96k -movflags +faststart "$OUT"
rm -f ffmpeg2pass-0.log ffmpeg2pass-0.log.mbtree
ls -lh "$OUT"
