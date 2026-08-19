# Pawvis demo video

Source for the animated product demo (1920x1080, 30 fps, ~87 s). Everything is
generated: the picture is one self-contained animated SVG scene graph, the
voiceover is OpenAI TTS, the backing track came from Suno, and the SFX are
synthesized with ffmpeg. There are no binary project files to open — edits are
code edits.

## Files

| file | what it is |
|---|---|
| `demo.html` | the whole film. A scene graph in SVG + a global `SEEK(t)` that renders the frame at time `t`. Deterministic: no `Date.now()`, no RNG. |
| `render.mjs` | drives `demo.html` in headless Chrome and writes PNG frames (4 pages in parallel) |
| `segments.json` | the narration script, one entry per voiceover segment |
| `gen_tts.mjs` | segments -> `audio/nN.wav` via OpenAI TTS (`gpt-4o-mini-tts`, voice `nova`) |
| `make_sfx.sh` | synthesizes whoosh / thump / pop / ding / chime with ffmpeg |
| `mix.sh` | narration + music + SFX -> `audio/mix.wav`, music sidechain-ducked under the voice, normalized to -14 LUFS |
| `build.sh` | render frames -> H.264 -> mux -> `pawvis-demo.mp4` |
| `discord.sh` | 720p two-pass re-encode under Discord's 10 MB limit |
| `audio/music.mp3` | the Suno backing track ("Pawvis Demo Theme") |

Generated output (`frames/`, `*.mp4`, `audio/mix.wav`, `audio/nN.wav`) is
gitignored. `audio/music.mp3` is committed because it cannot be regenerated.

## Build

```bash
npm install                 # puppeteer-core only
./make_sfx.sh               # once
node gen_tts.mjs            # needs OPENAI_API_KEY in ../../.env ; costs a few cents
./mix.sh                    # -> audio/mix.wav
./build.sh                  # -> pawvis-demo.mp4  (~15 min for 2565 frames)
```

Preview single moments without a full render:

```bash
PAGE=demo.html OUTDIR=probe node render.mjs probe "2.5,13,24.5,41.5,83"
```

## How the timeline works

`TL` at the top of `demo.html` maps each scene to its `[start, end]` in seconds,
and `DUR` is the total. Each scene's update function receives `u` (seconds since
that scene started), so keyframes inside a scene are scene-relative. `K(t, stops,
easing)` is the keyframe helper.

The narration offsets in `mix.sh` (`N=(...)`, ms) and the scene starts in `TL`
are kept in sync by hand: each segment starts ~0.5 s after its scene does. If you
change a scene's length, shift the later scene bounds, `DUR` (here and in
`render.mjs`), and the corresponding narration/SFX offsets together.

To sync a graphic to a specific spoken word, transcribe that segment with
word-level timestamps rather than guessing:

```bash
curl -s https://api.openai.com/v1/audio/transcriptions \
  -H "Authorization: Bearer $OPENAI_API_KEY" \
  -F file=@audio/n2.wav -F model=whisper-1 \
  -F response_format=verbose_json -F "timestamp_granularities[]=word"
```

Watch out for words that appear twice in one segment (n2 says "free" both in
"touch-free hand control" and in the closing "completely free, and open source").

## Assets

Pulled from the repo rather than duplicated: fonts and app screenshots from
`docs/assets/`, the app icon from `icon.png`. Colors match `docs/site.css`
(`#8B5CF6` / `#C4B5FD` purple, `#0EA5E9` / `#7DD3FC` blue).

## Audio levels

`mix.sh` targets -14 LUFS integrated with true peak <= -1.5 dBTP, and ducks the
music under the voice with `sidechaincompress`. It prints the measured loudness
when it finishes; if you retime narration, re-check that the voice still sits
clearly above the bed.
