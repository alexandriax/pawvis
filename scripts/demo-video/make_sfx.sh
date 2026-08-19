#!/usr/bin/env bash
# Synthesizes the SFX bed used by mix.sh. Pure ffmpeg — no external samples.
set -euo pipefail
cd "$(dirname "$0")/audio"

# transition whoosh: filtered pink noise with a fast in / slow out
ffmpeg -y -v error -f lavfi -i "anoisesrc=color=pink:duration=0.42:amplitude=0.7:seed=42" \
  -af "highpass=f=350,lowpass=f=2400,afade=t=in:d=0.1,afade=t=out:st=0.16:d=0.26,volume=1.6" whoosh.wav

# stamp thud: two decaying low sines
ffmpeg -y -v error -f lavfi \
  -i "aevalsrc=0.9*sin(2*PI*92*t)*exp(-16*t)+0.35*sin(2*PI*58*t)*exp(-11*t):d=0.4:s=48000" thump.wav

# UI click: fast downward chirp
ffmpeg -y -v error -f lavfi \
  -i "aevalsrc=0.75*sin(2*PI*(680-1600*t)*t)*exp(-38*t):d=0.14:s=48000" pop.wav

# call-connect ding: two-note interval
ffmpeg -y -v error -f lavfi \
  -i "aevalsrc=0.5*sin(2*PI*659*t)*exp(-7*t)+0.42*sin(2*PI*988*t)*exp(-6*t)*gt(t\,0.09):d=0.8:s=48000" ding.wav

# success chime: three-note arpeggio
ffmpeg -y -v error -f lavfi \
  -i "aevalsrc=0.46*sin(2*PI*880*t)*exp(-5.5*t)+0.4*sin(2*PI*1174.7*t)*exp(-4.5*t)*gt(t\,0.1)+0.2*sin(2*PI*1760*t)*exp(-7*t)*gt(t\,0.2):d=0.9:s=48000" chime.wav

echo "sfx written to $(pwd)"
