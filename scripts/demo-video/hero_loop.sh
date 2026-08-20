#!/bin/bash
# The splash page's hero loop: scenes 3 and 4 of the demo film (point, then
# click & drag), cut wipe-to-wipe so the loop's restart reads as one of the
# film's own scene cuts. Renders from demo.html and encodes one H.264 MP4 —
# a VP9 WebM was tried and came out *larger* than x264 on these flat animated
# fills, so the universal format is also the small one.
#
#   ./hero_loop.sh    ->  ../../docs/assets/hero-loop.mp4  (~700 KB)
#
# The bounds are TL.s3[0] and TL.s4[1] in demo.html; if those scenes move,
# move these with them.
set -euo pipefail
cd "$(dirname "$0")"

T0=22.8
T1=39.6

OUTDIR=frames-hero node render.mjs range "$T0" "$T1"

# 1280x720 to match the poster (assets/demo-cover.jpg): the hero never draws
# wider than that, and flat animated fills compress far below camera footage.
ffmpeg -y -framerate 30 -i frames-hero/f%05d.png -vf scale=1280:720 \
  -c:v libx264 -crf 26 -preset slow -pix_fmt yuv420p -movflags +faststart -an \
  ../../docs/assets/hero-loop.mp4

rm -rf frames-hero
ls -lh ../../docs/assets/hero-loop.*
