<h1 align="center">Pawvis</h1>

<p align="center">
  <img src="icon.png" alt="Pawvis" width="200">
</p>

<p align="center"><em>macOS touch-free gesture &amp; voice control</em></p>

---

Pawvis turns your webcam into a pointing device that works from thin air.
Raise your open hand anywhere the camera can see it and the cursor follows;
dip a finger to click. Nothing under your palm, nothing to touch. Talk to
your Mac by name, without a keyboard in reach: *"Pawvis, go to github.com"*,
*"Pawvis, type hello"*, *"Pawvis, open Safari"*. The aim is an
accessibility-grade voice control that's more intuitive and capable than the
built-in one.

Hand tracking runs entirely on-device with Apple's Vision framework; speech
recognition is Apple's on-device engine; and free-form visual commands are
resolved by on-device Apple Intelligence. By default, nothing you do leaves
your Mac; the one exception is the opt-in agent hand-off below.

<p align="center">
  <a href="https://github.com/alexandriax/pawvis/releases/latest/download/Pawvis.zip"><strong>⬇&nbsp; Download Pawvis for macOS</strong></a>
  <br>
  <a href="https://github.com/alexandriax/pawvis/releases/latest"><img src="https://img.shields.io/github/v/release/alexandriax/pawvis?label=latest&color=8B5CF6" alt="Latest release"></a>
  <br>
  <sub>Signed and notarized · macOS 14+ · unzip and drag to Applications</sub>
</p>

## Gestures

Your hands are tracked whenever tracking is on, but the cursor only follows
once you **show an open hand**: all four fingers up, thumb free. Close it
into a fist for a moment, or take it out of view, to park the cursor again;
the claw fades while it's parked. That keeps a hand that's merely visible
(resting, typing, gesturing) from dragging the cursor around. **Settings →
Tracking** switches back to "Any detected hand" if you'd rather have no
trigger at all.

Once you have it, your hand is the mouse: the cursor rides your palm, and your
fingers are the buttons. Everything below is tunable in **Settings →
Gestures**.

- **Move**: hold your hand open, fingers up, and move it.
- **Click**: dip your **index finger**, like tapping a mouse button.
  Measured against your middle finger, so tilting your whole hand can't
  click. A quick release is always a clean click.
- **Right-click**: dip a second finger (**pinky** by default, configurable).
  Hold it to right-drag.
- **Drag / hold**: keep the finger down and move. Deliberate movement starts
  a drag immediately; otherwise a short window protects quick clicks from
  turning into accidental drags. The window length is a slider.
- **Double / triple click**: tap again quickly in the same spot.
- **Scroll**: fold your **middle and ring fingers** in, index and pinky up,
  then move your hand up and down. The cursor parks while the pose is held.
  Toggle it (or invert the direction) in Settings.
- **Reach adapts to distance.** Auto mode sizes the tracking area from how big
  your hand looks, so the whole screen stays reachable up close *and* far away
  with your fingers staying inside the camera frame. Manual mode gives you a
  fixed area and a slider.

The on-screen claw is your cursor: open while pointing, retracted and purple
while the left button is held, blue for the right button, ringed in light blue
while scrolling, faded while control is parked, with a ring that tightens as
your click forms and a pulse confirming every click. Small dots mark each
detected fingertip.

The menu bar icon opens a live status panel (hands seen, whether control is
armed, voice-control state) plus a **Gesture Guide** window that walks
through every gesture.

## Voice control (beta)

Off by default while in beta. Enable it in **Settings → Voice (Beta)**,
then press **Start** next to Voice control in the menu bar. Address Pawvis
by its **wake word** (default `Pawvis`, configurable; mishearings are
tolerated). **Every command starts with the wake word**. Speech without it
is ignored and never typed or displayed:

| Say | Pawvis does |
|---|---|
| "Pawvis, **go to** heresalexandria dot com" | Navigates the frontmost browser there (via the address bar); opens your default browser if you're not in one. Non-URL targets become a web search. |
| "Pawvis, **type** good morning" | Types exactly that text into the focused app. One-shot, no lingering dictation mode. |
| "Pawvis, **press** command shift T" | Presses any key or shortcut: enter, tab, escape, arrows, page up/down, F-keys, letters and digits with modifiers. |
| "Pawvis, **open** Notes" | Launches (or brings forward) an app, with fuzzy name matching. |
| "Pawvis, **switch to** Chrome" | Brings a running app forward. |
| "Pawvis, **click** / right click / double click" | Clicks at the pointer. |
| "Pawvis, **scroll** down / up a page" | Scrolls at the pointer. |
| "Pawvis, *anything else*" | On-device Apple Intelligence maps the spoken words to an intent (open app, go to URL, type text, press keys…), absorbing speech-recognition garbling, and grounds screen commands ("click sign in") against the area **around your pointer**, widening to the whole screen only if the target isn't nearby. |
| "Pawvis, **stop listening**" | Turns voice control off. |

Speech recognition is **Apple's on-device engine**: private, free, no API
key, no cloud (SpeechAnalyzer on macOS 26+, SFSpeechRecognizer before that).
Visual commands need macOS 26 with Apple Intelligence enabled; everything
else works without it.

### Agent hand-off (optional)

Settings → Voice can hand every command to an installed agent CLI
(**Claude Code** or **Codex**) instead of the on-device brain. "Pawvis,
*anything*" then pipes everything after the wake word to the agent, asked to
perform it via computer use, as a headless auto-approved run in the
background. While it runs, a panel at the bottom-right of the screen streams
the agent's output live with a **Cancel** button (running sessions are also
listed, and cancellable, under **Settings → Voice → Background agent
sessions**), and the outcome, success or failure, always flashes in the
top-of-screen capsule. Only "Pawvis, stop listening" stays local, so you can
always shut it off instantly. Pausing after the wake word is fine: a bare
"Pawvis" keeps listening a few seconds for the command, and if dictation
mangles the wake word ("Paw this…"), the on-device model confirms it was
meant for Pawvis and recovers the command before the hand-off. Strictly
opt-in and off by default: the agent runs with permission checks bypassed and
can do anything you could do at the keyboard.

## Install

[**Download Pawvis.zip**](https://github.com/alexandriax/pawvis/releases/latest/download/Pawvis.zip)
(always the latest release), unzip, and drag **Pawvis.app** to your
Applications folder.

Pawvis starts with you after every login, so gesture control is just there.
Turn it off in **Settings → General → Launch Pawvis at login** (or in System
Settings → General → Login Items; Pawvis won't put itself back).

Pawvis checks for updates once a day and can install them itself. A new version
announces itself in a macOS notification, once per version, with an **Install…**
button that opens **Settings → About** where the release notes and the one-click
install live. **Check Now** on that page runs the check on demand.

### Permissions

On first run Pawvis asks for:

- **Camera**: hand tracking. Frames are processed in memory and discarded.
- **Accessibility**: moving the cursor and clicking. Tracking runs without
  it, but clicks won't land until it's granted (System Settings → Privacy &
  Security → Accessibility).
- **Microphone**: only when you first start voice control.
- **Screen Recording** *(optional)*: lets visual voice commands OCR what
  accessibility can't describe (canvases, images). Everything else works
  without it.
- **Notifications** *(optional)*: asked for the first time an update is
  actually waiting, never at launch. Decline it and new versions still show up
  in the menu bar and in Settings → About.

Releases are signed with a Developer ID and notarized by Apple, so they open
normally: no right-click → Open, and the Accessibility permission you grant
carries across updates.

## Build from source

Requires macOS 14+ and the Xcode toolchain.

```bash
make app            # release build → build/Pawvis.app
open build/Pawvis.app
```

```bash
swift test          # 239 unit tests
swift build         # debug build
```

Every icon asset (app icon, `.icns`, menu bar glyph, claw cursor) is derived
from the hand-drawn `claw.png` by one deterministic script. Re-running it on an
unchanged `claw.png` reproduces the committed art byte for byte:

```bash
make icon           # == swift scripts/process_claw.swift
```

See [AGENTS.md](AGENTS.md) for architecture notes, the settings-UI rules, and
the hard-won gesture-engine constraints.

## How it works

```
Sources/
  PawvisCore/          pure logic, unit-tested, no AppKit/AVFoundation
    Geometry/          Vec2 · One Euro filter · interaction-box mapper
    Hands/             21-landmark model · pinch/dip/curl metrics
    Gestures/          GestureEngine: frames → clicks, drags, scrolls, cursor moves
    VoiceControl/      wake-word + command parser · spoken URLs & key chords
    Update/            semantic versions · check / offer / notify policy
    Config/            settings tree (field-tolerant decoding)
  Pawvis/              the menu bar app
    Camera/            AVCaptureSession · Vision hand pose
    Control/           CGEvent mouse + keyboard synthesis
    Overlay/           click-through claw cursor and indicators
    VoiceControl/      on-device speech engine · command executor ·
                       screen context (AX + OCR) · Apple Intelligence resolver
    Update/            update checking · self-update · the "new version" banner
    Support/           permissions · logging · theme
    App/ UI/           menu bar, settings, gesture guide
```

The gesture engine is deterministic and clock-free, with all timing coming
from frame timestamps, so click chaining, drag timing, hysteresis, debounce
and tracking-loss recovery are covered by unit tests rather than by hand.

## Privacy

- Camera frames never leave your Mac, and the overlay is excluded from
  screenshots and screen recordings by default (there's a toggle if you want
  to record a demo).
- Voice audio never leaves your Mac. Recognition is Apple's on-device
  engine, and the menu bar icon carries a dot for as long as the mic is live.
  (The on-screen pill announces it too, then fades after five seconds so it
  isn't sitting on your screen all day.)
- Visual commands are resolved by the on-device Apple Intelligence model; the
  screenshots and accessibility snapshots it reads stay in memory and are
  never written to disk or uploaded.
- The optional agent hand-off is off by default, and it's the one thing that
  leaves your Mac: enable it and everything you say after the wake word is
  sent to the agent CLI you chose (Claude Code or Codex) and runs there with
  permission checks bypassed. "Pawvis, stop listening" always stays local.

## License

MIT
