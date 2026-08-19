#!/usr/bin/env bash
# Builds audio/mix.wav: narration + Suno music bed (sidechain-ducked) + SFX.
# Verified target: ~-14 LUFS integrated, true peak <= -1.5 dBTP.
set -euo pipefail
cd "$(dirname "$0")/audio"

DUR=87.5

# --- narration start times (ms), one per segment, aligned to the scene timeline
N=(800 6600 23400 31700 40100 47000 55500 66800 79000)

# --- SFX placements (ms)
WHOOSH=(5750 22550 30950 39350 46250 54750 66050 78150)   # one per scene wipe
THUMP=(19770 20770)                                        # FREE / OPEN SOURCE stamps land on the words
POP=(32820 42950 74850)                                    # click, gesture fire, voice
DING=(41200)                                               # video call connects
CHIME=(61750)                                              # trained gesture matched

fc=""; idx=0; mixin=""
for i in "${!N[@]}"; do
  fc+="[$i:a]aresample=48000,adelay=${N[$i]}:all=1[a$i];"; mixin+="[a$i]"
done
fc+="${mixin}amix=inputs=${#N[@]}:normalize=0,apad=whole_dur=$DUR,atrim=0:$DUR,aformat=channel_layouts=stereo[narr];"
fc+="[narr]asplit=2[nk][nmix];"
fc+="[9:a]atrim=0:$DUR,aresample=48000,aformat=channel_layouts=stereo,afade=t=in:st=0:d=1.2,afade=t=out:st=83.0:d=2.5,volume=0.32[mus];"
fc+="[mus][nk]sidechaincompress=threshold=0.035:ratio=10:attack=12:release=420[duck];"

# SFX bus: each source is split per placement, delayed, then summed
sfxin=""; s=0
add_sfx() { # $1=input index  $2=volume  $3...=delays
  local inp=$1 vol=$2; shift 2
  local n=$#; local tag="x${inp}"
  fc+="[${inp}:a]volume=${vol},asplit=${n}"
  for ((k=0;k<n;k++)); do fc+="[${tag}_$k]"; done; fc+=";"
  local j=0
  for d in "$@"; do fc+="[${tag}_$j]adelay=${d}:all=1[s${tag}_$j];"; sfxin+="[s${tag}_$j]"; s=$((s+1)); j=$((j+1)); done
}
add_sfx 10 0.28 "${WHOOSH[@]}"
add_sfx 11 0.16 "${THUMP[@]}"
add_sfx 12 0.18 "${POP[@]}"
add_sfx 13 0.30 "${DING[@]}"
add_sfx 14 0.30 "${CHIME[@]}"
fc+="${sfxin}amix=inputs=${s}:normalize=0,apad=whole_dur=$DUR,atrim=0:$DUR,aformat=channel_layouts=stereo[sfx];"
fc+="[duck][nmix][sfx]amix=inputs=3:normalize=0,loudnorm=I=-14:TP=-1.5:LRA=11,aresample=48000[out]"

ffmpeg -y -v error \
  -i n1.wav -i n2.wav -i n3.wav -i n4.wav -i n5.wav -i n6.wav -i n7.wav -i n8.wav -i n9.wav \
  -i music.mp3 -i whoosh.wav -i thump.wav -i pop.wav -i ding.wav -i chime.wav \
  -filter_complex "$fc" -map "[out]" -c:a pcm_s16le mix.wav

echo "mix.wav:"; ffprobe -v error -show_entries format=duration -of csv=p=0 mix.wav
ffmpeg -hide_banner -nostats -i mix.wav -af ebur128=framelog=quiet -f null - 2>&1 | grep -E '    I:|LRA:' | head -2
