# Pawvis demo video

Source for the animated product demo (1920x1080, 30 fps, 87.5 s). Everything is
generated: the picture is one self-contained animated SVG scene graph, the
voiceover is OpenAI TTS, the backing track came from Suno, and the SFX are
synthesized with ffmpeg. There is no binary project file to open — every edit is
a code edit, and the whole film rebuilds from this directory.

## Files

| file | what it is |
|---|---|
| `demo.html` | the whole film. A scene graph in SVG plus a global `SEEK(t)` that renders the frame at time `t`. Deterministic: no `Date.now()`, no RNG. |
| `render.mjs` | drives `demo.html` in headless Chrome, writes PNG frames (4 pages in parallel) |
| `segments.json` | the narration script, one entry per voiceover segment |
| `gen_tts.mjs` | segments -> `audio/nN.wav` via OpenAI TTS (`gpt-4o-mini-tts`, voice `nova`) |
| `make_sfx.sh` | synthesizes whoosh / thump / pop / ding / chime with ffmpeg |
| `mix.sh` | narration + music + SFX -> `audio/mix.wav`; music sidechain-ducked under the voice, normalized to -14 LUFS |
| `build.sh` | render frames -> H.264 -> mux -> `pawvis-demo.mp4` |
| `discord.sh` | 720p two-pass re-encode that fits Discord's 10 MB limit |

Raw assets committed here: `audio/music.mp3` (the Suno track), `audio/n1..n9.wav`
(the narration takes) and the five synthesized SFX. The narration is committed
rather than regenerated on demand because TTS output is not reproducible and the
on-screen beats are synced to these exact recordings.

Generated output — `frames/`, `audio/mix.wav`, `*.mp4` — is gitignored.

## Build

```bash
npm install                 # puppeteer-core only
./make_sfx.sh               # once
node gen_tts.mjs            # only if segments.json changed; needs an API key
./mix.sh                    # -> audio/mix.wav
./build.sh                  # -> pawvis-demo.mp4   (~15 min for 2625 frames)
```

Preview single moments instead of rendering everything:

```bash
PAGE=demo.html OUTDIR=probe node render.mjs probe "2.5,13,21,48.9,85"
```

Frame N of the finished film is at `t = N/30`, so a probe at the same `t` is
exactly what lands in the video.

## Editing

### The timeline

`TL` at the top of `demo.html` maps each scene to `[start, end]` in seconds and
`DUR` is the total. A scene's update function receives `u` — seconds since *that
scene* started — so keyframes inside a scene are scene-relative. `K(t, stops,
easing)` is the keyframe helper; easings available are `lin`, `eo`, `ei`, `eio`,
`xo` (expo-out), `back` (overshoot) and `spring` (damped pop).

Three places must stay in sync when a scene changes length:

1. `TL` and `DUR` in `demo.html`
2. `DUR` in `render.mjs`
3. `N=(...)` narration offsets and the SFX arrays in `mix.sh` (all ms)

The scene-boundary wipes are driven by their own list near the bottom of
`demo.html` (`for (const b of [...])`) — those numbers are the same boundaries as
`TL`, so they move too.

### Scenes and the camera (the easy mistake)

`scene(name, build)` builds two groups: a **camera** group that gets the slow
push-in from `camMove()`, and the **outer** group that does not move. The build
callback receives both:

```js
scene('s1', (g, fixed) => { ... })
//            ^camera  ^pinned
```

Anything parented to `g` inherits the camera drift — correct for scene content.
Anything that must hold still (titles, HUD, lower thirds) belongs on `fixed`.
Putting a title on the camera group makes it drift *and* re-rasterize at a
changing sub-pixel scale every frame, which reads on screen as shaking.

### Hands

`POSES` holds one entry per gesture; each finger is `[baseAngle, length, hook]`
where `length` 0..1 curls the finger into the palm and `hook` bends the distal
joint in degrees. `mixPose(a, b, u)` blends two poses, which is how every
gesture animates:

```js
hand.pose(mixPose(POSES.open, POSES.scroll, fold));
```

The hand is drawn as one continuous silhouette recomputed per frame, so poses
stay seamless — don't add separate finger shapes on top of it.

Gestures should stay honest to what the app actually does. The scroll scene
folds middle+ring only on the down-strokes and opens the hand for the reset
stroke, because holding the pose on the way up would scroll the page back up.
The claw's parked ring is keyed off the same `fold` value so the cursor
indicator can't contradict the hand.

### Text boxes

Don't hardcode the width of a pill or stamp around a label — measure it. The
file uses `getComputedTextLength()` at runtime (see `layoutChip`, `layoutOSS`,
`layoutWord`) and sizes the box to the measured text with fixed padding. Fonts
must be loaded first, hence the `document.fonts.status === 'loaded'` guard.

### Determinism

`SEEK(t)` must render the same pixels for the same `t` every time — frames are
rendered out of order across 4 parallel pages. No `Date.now()`, no
`Math.random()`, no animation that depends on previous state. The film grain
looks random but is a seeded `feTurbulence` driven by `t`.

## Recording / regenerating the raw assets

### Narration

Edit `segments.json`, then `node gen_tts.mjs`. The key comes from
`$OPENAI_API_KEY` or the repo-root `.env` (gitignored). Voice is `nova`; the
delivery is steered by the `INSTRUCTIONS` string at the top of `gen_tts.mjs`
rather than by punctuation tricks.

Segment durations change whenever you regenerate, so re-check the offsets in
`mix.sh` against `TL` afterwards — `ffprobe -v error -show_entries
format=duration -of csv=p=0 audio/nN.wav`.

To sync a graphic to a specific spoken word, transcribe with word-level
timestamps instead of guessing:

```bash
curl -s https://api.openai.com/v1/audio/transcriptions \
  -H "Authorization: Bearer $OPENAI_API_KEY" \
  -F file=@audio/n2.wav -F model=whisper-1 \
  -F response_format=verbose_json -F "timestamp_granularities[]=word"
```

Watch for a word that occurs twice in one segment: n2 says "free" both in
"touch-free hand control" and in the closing "completely free, and open source",
and the stamps are cued to the second one.

### Music

`audio/music.mp3` is a Suno instrumental generated from roughly:

> uplifting minimal electronic, warm analog synth plucks, marimba, soft
> four-on-the-floor, playful optimistic tech product demo background music,
> instrumental, clean modern mix, gentle build, steady energy, 105 bpm

To swap it, drop a new file in as `audio/music.mp3` and re-run `./mix.sh`. The
bed sits at `volume=0.32` before ducking; if a new track is denser, lower that
rather than turning the voice up.

### SFX

`./make_sfx.sh` regenerates all five from ffmpeg oscillators — no samples, no
licensing. Placements and per-cue gains live in `mix.sh`.

### App screenshots

The real-UI cameos (`docs/assets/app-menu.png`,
`docs/assets/app-settings-custom.png`) come from a running build. `AGENTS.md`
covers the settings-window rules; the useful part here is that Settings can be
opened straight to a tab instead of being clicked to:

```bash
make app
PAWVIS_OPEN_SETTINGS=gestures open build/Pawvis.app   # general|tracking|mouse|gestures|voice|about
screencapture -o -w docs/assets/app-settings-custom.png
```

`-o` drops the window shadow; `-w` still asks you to click the window you want
(use `-l<windowid>` if you need it fully unattended). Capture at the window's
native size — `demo.html` scales these down inside a mock frame, so upscaling
shows. Set up any demo state through a throwaway defaults domain rather than
your real preferences, so a screenshot session can't leave demo settings behind.

## Output

`build.sh` writes a ~33 MB CRF 17 master. For Discord or anywhere with an
attachment cap, `./discord.sh` produces a 720p two-pass cut under 10 MB with the
same audio.

## Audio levels

`mix.sh` targets -14 LUFS integrated with true peak <= -1.5 dBTP and ducks the
music under the voice with `sidechaincompress`. It prints the measured loudness
when it finishes. After any retiming, confirm the voice still sits clearly above
the bed — compare a music-only window against a narration window:

```bash
ffmpeg -ss 5.2 -t 0.5 -i audio/mix.wav -af astats=measure_perchannel=none -f null - 2>&1 | grep 'RMS level'
```

## Assets

Fonts, app screenshots and the app icon are referenced out of `docs/assets/` and
`icon.png` rather than duplicated, so the video always matches the site. Colors
track `docs/site.css` (`#8B5CF6` / `#C4B5FD` purple, `#0EA5E9` / `#7DD3FC` blue).
