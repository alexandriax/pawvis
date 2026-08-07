<h1 align="center">Pawvis</h1>

<p align="center">
  <img src="icon.png" alt="Pawvis" width="200">
</p>

<p align="center"><em>macOS visual gesture &amp; voice control</em></p>

---

Pawvis turns your webcam into a pointing device and your voice into a
keyboard. Move your hand to move the cursor, dip a finger to click, and speak
to type — without touching a mouse or keyboard.

Hand tracking runs entirely on-device with Apple's Vision framework, and voice
dictation defaults to Apple's on-device speech engine, so by default nothing
you do leaves your Mac.

<p align="center">
  <a href="https://github.com/alexandriax/pawvis/releases/latest/download/Pawvis.zip"><strong>⬇&nbsp; Download Pawvis for macOS</strong></a>
  <br>
  <a href="https://github.com/alexandriax/pawvis/releases/latest"><img src="https://img.shields.io/github/v/release/alexandriax/pawvis?label=latest&color=8B5CF6" alt="Latest release"></a>
  <br>
  <sub>Signed and notarized · macOS 14+ · unzip and drag to Applications</sub>
</p>

## Gestures

Pick the click gesture that suits you in **Settings → Gestures**. Whichever
you choose: the cursor follows your hand, holding the gesture drags, and a
quick release is a clean click.

| Click gesture | How you click |
|---|---|
| **Mouse tap** (default) | Hold your hand open and dip your **index finger**, like tapping a mouse button. Measured against your middle finger, so tilting your whole hand can't click. |
| **Whole-hand pinch** | Gather all your fingertips onto your thumb. Averaging four fingers makes false clicks rare. |
| **High-five, thumb to click** | Hand open like a high-five; tuck your thumb across your palm. |
| **Pinch** | Touch your thumb and index fingertip together. |

- **Right-click** — in mouse-tap and high-five modes, dip a second finger
  (pinky by default, configurable). Hold it to right-drag.
- **Drag / hold** — keep the gesture held and move. Deliberate movement starts
  a drag immediately; otherwise a short window protects quick clicks from
  turning into accidental drags. The window length is a slider.
- **Double / triple click** — repeat the gesture quickly in the same spot.
- **Reach adapts to distance.** Auto mode sizes the tracking area from how big
  your hand looks, so the whole screen stays reachable up close *and* far away
  with your fingers staying inside the camera frame. Manual mode gives you a
  fixed area and a slider.

The on-screen claw is your cursor: open while pointing, retracted and purple
while the left button is held, blue for the right button, with a ring that
tightens as your click gesture forms and a pulse confirming every click. Small
dots mark each detected fingertip.

## Voice dictation

1. Open the menu bar icon and press **Start** next to Dictation.
2. Say a **wake word** — `type`, `text`, `enter`, `write`, or `dictate`
   (editable) — and everything after it is typed into the focused app:
   *"type hello world"*.
3. Say **"stop typing"** to stop. While dictating, *"new line"*,
   *"new paragraph"*, *"press enter"* and *"press tab"* do what they say.

The default engine is **Apple's on-device recognition** — private, free, no
setup (SpeechAnalyzer on macOS 26+, SFSpeechRecognizer before that). An
optional **OpenAI** engine is available in Settings if you prefer it; it needs
your own API key (stored in your login keychain) and streams audio only while
dictation is armed.

## Install

[**Download Pawvis.zip**](https://github.com/alexandriax/pawvis/releases/latest/download/Pawvis.zip)
(always the latest release), unzip, and drag **Pawvis.app** to your
Applications folder.

Pawvis checks for updates once a day and can install them itself —
**Settings → About → Check Now**.

### Permissions

On first run Pawvis asks for:

- **Camera** — hand tracking. Frames are processed in memory and discarded.
- **Accessibility** — moving the cursor and clicking. Tracking runs without
  it, but clicks won't land until it's granted (System Settings → Privacy &
  Security → Accessibility).
- **Microphone** — only when you first start dictation.

Releases are signed with a Developer ID and notarized by Apple, so they open
normally — no right-click → Open, and the Accessibility permission you grant
carries across updates.

## Build from source

Requires macOS 14+ and the Xcode toolchain.

```bash
make app            # release build → build/Pawvis.app
open build/Pawvis.app
```

```bash
swift test          # 187 unit tests
swift build         # debug build
make icon           # regenerate icon art (needs OPENAI_API_KEY)
```

See [AGENTS.md](AGENTS.md) for architecture notes, the settings-UI rules, and
the hard-won gesture-engine constraints.

## How it works

```
Sources/
  PawvisCore/          pure logic, unit-tested, no AppKit/AVFoundation
    Geometry/          Vec2 · One Euro filter · interaction-box mapper
    Hands/             21-landmark model · pinch/dip/curl metrics
    Gestures/          GestureEngine: frames → clicks, drags, cursor moves
    Dictation/         wake-word parser · OpenAI Realtime protocol
    Update/            semantic versions · update-check policy
    Config/            settings tree (field-tolerant decoding)
  Pawvis/              the menu bar app
    Camera/            AVCaptureSession · Vision hand pose
    Control/           CGEvent mouse + keyboard synthesis
    Overlay/           click-through claw cursor and indicators
    Dictation/         mic capture · Apple + OpenAI engines
    Update/            update checking and self-update
    App/ UI/           menu bar, settings, gesture guide
```

The gesture engine is deterministic and clock-free — all timing comes from
frame timestamps — so click chaining, drag timing, hysteresis, debounce and
tracking-loss recovery are covered by unit tests rather than by hand.

## Privacy

- Camera frames never leave your Mac, and the overlay is excluded from
  screenshots and screen recordings by default (there's a toggle if you want
  to record a demo).
- Dictation audio stays on-device with the Apple engine. With the optional
  OpenAI engine, audio is sent only between arming and disarming dictation,
  and the menu bar icon and on-screen pill always show when that's the case.
- Your OpenAI key, if you use one, lives in the login keychain.

## License

MIT
