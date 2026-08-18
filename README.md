<h1 align="center">Pawvis</h1>

<p align="center">
  <img src="icon.png" alt="Pawvis" width="200">
</p>

<p align="center"><em>Touch-free hand control for your Mac</em></p>

---

Pawvis turns your webcam into a pointing device that works from thin air.
Raise your open hand anywhere the camera can see it and the cursor follows;
dip a finger to click, hold it down to drag, fold two fingers to scroll.
Nothing under your palm, nothing to touch: your hand is the mouse. There's
also a [voice mode, in beta](#voice-control-beta) — talk to your Mac by name
(*"Pawvis, open Safari"*), with the aim of growing into an
accessibility-grade voice control more intuitive and capable than the
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

> [!IMPORTANT]
> **Pawvis really does control your Mac.** It moves the cursor and posts real
> clicks, drags and scrolls, so an accidental finger dip is an accidental
> click, and a click lands on whatever is under the cursor at that moment
> (Send, Delete, Confirm). Treat it like handing someone else your mouse. Give
> it a few minutes somewhere harmless, like the Finder or a scratch document,
> until the gestures feel deliberate, and keep the menu bar toggle in reach:
> tracking stops the moment you switch it off, and the cursor parks whenever
> you close your hand or take it out of the camera's view. With voice control
> on, spoken commands do the same thing, and a misheard sentence is still a
> command. Pawvis is provided as is, without warranty of any kind: its
> developer accepts no liability for any action taken with it, intentional or
> not, or for any resulting loss or damage. Please use it responsibly.

## Gestures

Your hands are tracked whenever tracking is on, but the cursor only follows
once you **show an open hand**: all four fingers up, thumb free. Close it
into a fist for a moment, or take it out of view, to park the cursor again;
the claw fades while it's parked. That keeps a hand that's merely visible
(resting, typing, gesturing) from dragging the cursor around. **Settings →
Tracking** switches back to "Any detected hand" if you'd rather have no
trigger at all, or all the way to **"Never — custom gestures only"**, which
keeps the mouse untouched entirely: your hands become a remote that only
fires the gestures you've assigned.

Once you have it, your hand is the mouse: the cursor rides your palm, and your
fingers are the buttons. Everything below is tunable in **Settings →
Mouse**.

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
- **Stop tracking**: hold up **both hands** open with fingers spread wide, like
  a double high-five, then wave them across each other. Once they have traded
  sides twice (over and back), hand tracking switches off entirely, the same
  as the menu bar switch. Optional, on by default; the number of crossings is
  a setting under **Settings → Tracking**.
- **Custom gestures**: **Settings → Gestures** lists a library of extra
  one-shot gestures, every one of them visible and none of them live until
  you give it an action. Wiggle your fingers with a hand raised palm to the
  camera, or point a hand flat at the screen and drum on invisible keys (a
  separate gesture, and both come in one-hand and two-hand versions). Hold
  a fist with your thumb up, down, or tilted to point straight left or
  right, hold a shaka, or bunch all your fingertips onto your thumb and
  fling the bunch toward any edge or corner, eight directions in all. A
  gesture's action can be anything from the catalog: move between
  virtual desktops, open Mission Control or App Exposé, show the desktop,
  snap the focused window (halves, thirds, two-thirds, quarters, center,
  maximize, minimize, next display), press Return or Escape, go back or
<<<<<<< HEAD
  forward, switch tabs, play/pause, stop tracking, toggle voice control,
  open any app, press any keyboard shortcut, or run a shell command you
  provide (it runs exactly as typed, as you). Every gesture row carries its
  own collapsed **Tuning** section (hold time, wiggle vigor, grab tightness,
  fling distance), so a gesture that won't trigger, or triggers too easily,
  can be dialed in on the spot. Every binding can also carry **per-app
  actions**: add apps to a gesture's row and give each its own action, and
  whichever app is frontmost when the gesture fires decides which action
  runs (a thumbs up can advance slides in Keynote and press your merge
  shortcut in the browser). Leave the main action unassigned and the
  gesture fires only in the apps you listed. The pill at the top of the
  screen confirms every fire, and the Gesture Guide illustrates every
  gesture in full, with what it is currently set to do.
=======
  forward, switch tabs, play/pause, adjust volume or brightness, stop
  tracking, toggle voice control, open any app, press any keyboard shortcut,
  or run a shell command you provide (it runs exactly as typed, as you).
  Every gesture row carries its own collapsed **Tuning** section (hold time,
  wiggle vigor, grab tightness, fling distance), so a gesture that won't
  trigger, or triggers too easily, can be dialed in on the spot. The pill at
  the top of the screen confirms every fire, and the Gesture Guide
  illustrates every gesture in full, with what it is currently set to do.
>>>>>>> origin/main
- **Train your own gestures**: **Settings → Gestures → Train New Gesture**
  opens a camera window with your hand's tracking drawn live, a color per
  fingertip and a ring on the palm. Pick one hand or two, perform your
  motion (or hold a pose) 3 to 10 times, and Pawvis learns a template from
  your takes, tells you when they agree well enough, and lets you try the
  match live before saving. Trained gestures join the Gestures tab with an
  animated badge that replays the learned motion, and they work like the
  built-ins: rename them, remove them, tune how strictly they match, and
  bind them to any action from the same catalog (or leave them unassigned);
  per-app actions work here too.
  Each one can also require a hold before it fires (the pill counts the
  hold down), and a priority switch decides who wins when a gesture looks
  like a click: by default trained gestures keep matching through clicks
  and scrolls, and a match in progress blocks new clicks. Pawvis control
  pauses while the trainer is open, so recording never fights the mouse.
  Training data never leaves this Mac, like all tracking.
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
tolerated). Filler before it is fine too, like "Um, Pawvis, open Chrome",
and a garbled wake word still gets a second look from on-device Apple
Intelligence before Pawvis gives up on the command. **Every command starts
with the wake word**. Speech without it is ignored and never typed or
displayed. Commands are understood by a fast built-in grammar first, then
by on-device Apple Intelligence, and only genuinely visual requests drive
the screen step by step:

| Say | Pawvis does |
|---|---|
| "Pawvis, **go to** heresalexandria dot com" or "**open** discord dot com **in Chrome**" | Navigates there in the frontmost browser (via the address bar), or in a named app; falls back to your default browser, saying so, if you don't name one or it isn't found. Non-URL targets become a web search. |
| "Pawvis, **type** good morning" | Types exactly that text into the focused app. One-shot, no lingering dictation mode. |
| "Pawvis, **press** command shift T" | Presses any key or shortcut: enter, tab, escape, arrows, page up/down, F-keys, letters and digits with modifiers. |
| "Pawvis, **open** Notes" | Launches (or brings forward) an app, with fuzzy name matching. |
| "Pawvis, **switch to** Chrome" | Brings a running app forward. |
| "Pawvis, **click** / right click / double click" | Clicks at the pointer. |
| "Pawvis, **scroll** down / up a page" | Scrolls at the pointer. |
| "Pawvis, **pause** / **play**" | Presses the hardware play/pause key. macOS routes it to whatever's actually playing, not necessarily the frontmost app. |
| "Pawvis, **close the window** / minimize / new tab / copy / paste / undo / save / select all / quit Safari" | Instant window and edit commands, no AI round-trip. |
| "Pawvis, *anything else*" | On-device Apple Intelligence carries it out **step by step**: it reads the screen (accessibility + OCR, menus included), does the next action, looks again, and repeats until the request is done, up to 8 steps. Multi-step commands work: "open Notes and start a new note", "select the pawvis project and start a new conversation". A bottom-right panel streams each step with a **Cancel** button. |
| "Pawvis, **stop**" | Cancels a running multi-step command. With nothing running, turns voice control off. |
| "Pawvis, **stop listening**" | Turns voice control off. |

You can chain several commands into one sentence and Pawvis runs each step
in order, like "Pawvis, pause this, open a new tab, and go to youtube dot
com".

Speech recognition is **Apple's on-device engine**: private, free, no API
key, no cloud (SpeechAnalyzer on macOS 26+, SFSpeechRecognizer before that).
The step-by-step autopilot needs macOS 26 with Apple Intelligence enabled;
everything else works without it. Autopilot runs verify each step actually
happened before reporting a command done, rather than taking the model's
word for it.

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
meant for Pawvis and recovers the command before the hand-off.

> [!WARNING]
> **The agent relays are the sharpest thing in Pawvis. They do not ask.**
> Claude Code and Codex are launched with their own permission prompts turned
> off (`--dangerously-skip-permissions`,
> `--dangerously-bypass-approvals-and-sandbox`), so nothing pauses to confirm
> anything: the agent simply carries out what it was handed, with your user
> account, your files, your logged-in sessions and your credentials. That
> covers deleting or rewriting files, installing software, running shell
> commands, opening apps, and sending things on your behalf. Speech
> recognition is not perfect, and a misheard command is still executed. It is
> also the one mode that sends what you say beyond your Mac, to the agent CLI
> you picked. It is off by default, and Pawvis makes you accept this warning
> in a dialog before it will turn on. If you want a confirmation step before
> actions run, stay on the on-device handler. Turning it on is your call and
> your responsibility: no liability is accepted for what an agent does with
> your machine, however it was asked.

## Install

[**Download Pawvis.zip**](https://github.com/alexandriax/pawvis/releases/latest/download/Pawvis.zip)
(always the latest release), unzip, and drag **Pawvis.app** to your
Applications folder. Homebrew users: a cask scaffold lives in
`Casks/pawvis.rb`, pending submission to homebrew/cask.

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
swift test          # the full unit suite, keep it green
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
                       + the custom one-shot gestures (wiggles, held poses, flings)
                       + user-trained gestures (recorded takes → matched templates)
    Actions/           gesture actions · typed-shortcut parsing · window placement math
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
