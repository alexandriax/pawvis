# Working on Pawvis

Notes for anyone (human or agent) making changes here. Read this before
touching the UI or the gesture engine — most of it exists because something
went wrong once.

## Build, test, run

```bash
swift build            # debug
swift test             # full suite — keep it green, it's the safety net
make app               # release build + assembles build/Pawvis.app + signs
open build/Pawvis.app
```

Extras:

- `build/Pawvis.app/Contents/MacOS/Pawvis --selftest` — headless smoke test
  (engine, settings round-trip, launch-at-login rules, voice parser).
- `PAWVIS_NO_AUTOSTART=1` — launch without starting tracking, so automated
  runs don't trip the camera permission prompt.
- `PAWVIS_OPEN_GUIDE=1` — open the Gesture Guide window at launch, the same
  eyes-on hook as `PAWVIS_OPEN_SETTINGS` below. Its posed-hand art is
  bundle-only, so a bare `swift run` shows the SF Symbol fallbacks instead:
  look at the guide from `build/Pawvis.app`, not from the binary.
- `PAWVIS_OPEN_WELCOME=1` — open the first-run welcome window at launch
  regardless of the `Pawvis.firstRunCompleted` flag. A genuinely new install
  (flag unset, camera not yet granted) gets it automatically instead of
  auto-starting tracking; `PAWVIS_NO_AUTOSTART=1` suppresses that and leaves
  the flag untouched, so automated runs stay headless.
- `Pawvis --gesture-eval <video…> [--verbose]` — run the real Vision +
  engine pipeline over a webcam recording and print every custom gesture
  that fires (plus per-frame openness/splay/palm diagnostics with
  `--verbose`). The ground-truth harness for the motion gestures: record a
  clip of the gesture and ask the machine, because synthetic tests cannot
  tell you what Vision does to a real hand mid-swipe. Every threshold in
  `CustomGestureDetector` was tuned against such clips; retune the same way.
- `Pawvis --action-eval <kind> [argument…]` — perform one gesture action
  through the real `GestureActionRunner` and print the pill outcome.
  "Does desktopRight actually switch the desktop on this machine" is a
  question for the machine, not for reading the code.
- `VERSION=1.2.3 BUILD_NUMBER=42 make app` — stamp a version into the bundle
  (CI does this from the release tag; local builds show `0.0.0-dev`).

**Signing matters more than it looks.** macOS ties the Accessibility grant to
the app's *designated requirement*. Signed with a real identity, that
requirement is identity-based and stable:

    identifier "com.pawvis.Pawvis" and anchor apple generic and ... leaf[subject.OU] = KMZ785G889

Ad-hoc signed, it is a per-binary `cdhash` instead — so every build looks like
a different app, macOS silently ignores the existing grant *while still
showing Pawvis as enabled*, and the symptom is "the cursor moves but nothing
clicks, anywhere." Fix in that state: remove and re-add Pawvis in System
Settings → Privacy & Security → Accessibility.

`scripts/make_app.sh` therefore prefers `Developer ID Application` (adding
Hardened Runtime + `Resources/Pawvis.entitlements`, which notarization
requires and which give the camera/mic back under it), then
`Apple Development`, then ad-hoc with a warning. Local builds and CI releases
share one Developer ID, so a single Accessibility grant covers both and
survives every update — verified by comparing the two designated
requirements.

## Settings UI: never let text truncate

This has regressed several times, so it's now structural. macOS `Form` lays
controls out in two columns: a narrow leading label column and a trailing
control column. At any sane window width, long labels get truncated with a
leading ellipsis ("…age (ISO code, blank = auto)") and captions get clipped on
the right — both invisible in code review and obvious to the user.

**Rules for `SettingsView.swift`:**

1. Build every control with the helpers at the top of the file —
   `SettingRow`, `SettingToggle`, `LabeledSlider`, `CaptionText` — inside a
   `SettingsPage`. They lay the label *above* the control in a single
   full-width, leading-aligned column, so there is no column to squeeze and
   text can only wrap.
2. Never add a bare `Picker("Some long label", …)`, `TextField("Some long
   label", …)` or `LabeledContent` to a settings page. Wrap it in
   `SettingRow(title:)` and pass `""` as the control's own label.
3. Every explanatory `Text` needs
   `.fixedSize(horizontal: false, vertical: true)` — that's what allows
   multi-line growth instead of truncation. `CaptionText` does it for you.
4. Pages are inside a `ScrollView`, so adding rows can't clip the bottom.
5. After changing settings UI, actually open the window and look at every tab.
   There is no headless render: SwiftUI's `ImageRenderer` produces blank
   output for these views without a running app. But the window *can* be
   opened programmatically now — `PAWVIS_OPEN_SETTINGS=<tab>` (general,
   tracking, mouse, gestures, voice, about) opens Settings on that tab right after
   launch, so `make app` + launch + `screencapture` covers it without
   hand-clicking. Pay attention to the longest strings (the Voice control and
   Tracking tabs have them).

## Menu bar chips: hue means something

The `MenuBarExtra` dropdown sits on translucent menu material, which is the
constraint behind every rule here. `PawvisTheme.Chip` owns the colors and
`PawvisButtonStyle` draws them; the palette is save.page's (Tailwind violet /
sky / fuchsia).

1. **Chips are appearance-dynamic, not fixed.** Each one resolves a light and
   a dark value (`PawvisTheme.dynamic`). One fixed fill cannot clear contrast
   on both materials, which is what a fixed violet-500 and a fixed sky-300
   were doing badly at. `--selftest` fails the build if a chip's fill stops
   varying by appearance, or if its type drops under WCAG AA (4.5:1) against
   its own fill in either mode. Retune freely; keep the check green.
2. **One visual language per appearance.** Light mode: saturated fill, white
   type. Dark mode: the pale 300-shade, ink type. Mixing the two in one row
   (a pale chip with black type next to a saturated chip with white type) is
   what made the old footer look broken, more than any individual color did.
3. **Hue is meaning, not decoration.** Violet is the primary action, sky is
   navigation, fuchsia is attention (mic live, warnings needing a decision),
   and `chipQuiet` recedes. Quit wears the quiet chip on purpose: quitting is
   mundane, so it takes the least ink in the row. It was red-800 once and read
   as a hazard; it was near-white once and became the loudest thing on screen.
   Red is left for genuine errors, where it means what it says.
4. **Light fills sit a stop darker than save.page's 500s** (violet-600,
   sky-700, fuchsia-600). White on violet-500 is 4.2:1, just under AA at chip
   text size. The web can use the 500s because its buttons are larger.
5. **Nothing tinted-and-translucent.** A low-alpha wash over vibrancy washes
   out on a light desktop. Chips are opaque; the quiet chip earns its edge
   from a hairline border, not from transparency.

The claw in the header and the toggle both take `PawvisTheme.accent`, the same
violet-500/violet-300 pair, because violet-500 on the dark menu material is
~3.4:1 and effectively invisible. If you tint anything else in this menu, use
`accent` rather than `purpleUI` — `purpleUI` is the fixed overlay color, which
paints over arbitrary screen content and must not flip with the appearance.

## Launch at login

On by default (`general.launchAtLogin`), registered through
`SMAppService.mainApp` — no helper bundle, no `LSSharedFileList`. The decision
rules are pure and unit-tested in `PawvisCore/Config/LaunchAtLoginPolicy.swift`;
`Support/LoginItem.swift` only reads the real status and performs the action.

Measured on macOS 26, and easy to get wrong:

- **A never-registered app reports `.notFound`, not `.notRegistered`.**
  `.notRegistered` is what you get *after* an unregister. Treating `.notFound`
  as "unsupported" means the on-by-default first launch never registers
  anything.
- **`status` can't tell you whether registration is possible.** An unbundled
  binary also reports `.notFound`, and `register()` on it fails with
  `SMAppServiceErrorDomain 1` ("Operation not permitted"). The bundle check
  (`bundleIdentifier != nil` and a `.app` path) is the real gate.
- **Never re-register on every launch.** Once the default has been applied
  once, a missing login item means the user removed it in System Settings →
  General → Login Items; the app adopts that instead of putting it back, or it
  becomes impossible to switch off. The one-shot flag is
  `PawvisLoginItem.defaultApplied` in UserDefaults, and it is deliberately
  *not* set when a registration attempt fails, so transient failures retry.
- Register/unregister are idempotent — calling either twice succeeds.
- `PAWVIS_NO_AUTOSTART=1` skips the reconcile as well as the camera, so
  automated runs don't leave a login item behind pointing at a build directory.

## Energy and idle

With the defaults, the camera and per-frame Vision inference run from login
to shutdown, so the app owns two rest states (`PawvisController`):

- **The lock screen pauses tracking** (`com.apple.screenIsLocked` /
  `com.apple.screenIsUnlocked` over `DistributedNotificationCenter`). On
  lock: release anything held (the same release path `stopTracking` uses —
  synthetic events used to land on the lock screen itself), stop the camera,
  and keep `trackingActive` true; the menu's status line shows the published
  `pauseReason` ("Paused on the lock screen"). Unlock resumes with a fresh
  engine, and a session started while locked (a voice command can) comes up
  paused. Sleep/wake and capture-failure recovery are deliberately separate
  paths, not this one.
- **No hands for 10 s throttles Vision, never the camera** (`IdleThrottle`,
  pure PawvisCore and clock-free like the rest of it; `FrameThrottleBox` is
  its lock-guarded face at the camera tap). Frames skip inference before it
  runs — one in six processes, ~5 fps of the locked 30 — because skipping
  inference is free while reconfiguring the AVCaptureSession glitches. The
  first processed frame containing a hand exits the throttle at once. Low
  Power Mode shortens the no-hands delay to 3 s and sparsens the probe to
  one frame in fifteen (~2 fps). The thresholds are constants, chosen
  rather than measured; make them settings only if someone actually asks.
- **Skipped frames never reach the gesture engine**, whose only clock is
  the timestamps of the frames it is given — a delivery gap reads as a slow
  camera, which the tracking-loss grace already tolerates. A held button,
  an active scroll, or the open trainer exempts every frame explicitly:
  throttling mid-press must be impossible by construction, even though the
  no-hands clock could not be running then anyway.

## Gesture engine

`PawvisCore` is pure logic — no AppKit, no AVFoundation, no clocks. All timing
comes from frame timestamps passed in, which is why click chaining, drag
timing, hysteresis and tracking-loss behavior are all unit-testable. Keep it
that way: if you need "now", take it as a parameter.

Hard-won constraints, each of which broke something real:

- **Vision's hand pose is stateless** (one revision since 2020, not a
  `VNStatefulRequest`). There is no built-in temporal tracking, so smoothing
  (One Euro, per joint), hysteresis, debounce and confidence gating are ours
  to own. Don't remove them expecting the framework to compensate.
- **The cursor must ride a landmark the click gesture doesn't move.** Modes
  that gather or dip fingers anchor on the palm. A fingertip centroid shifted
  ~0.08 (screen-normalized) when a hand *opened to release*, which smeared
  every click into a drag.
- **Don't gate clicks on hand "openness."** People pinch with their other
  fingers half-curled; an openness guard silently blocked nearly every real
  click.
- **The open-hand control trigger gates *arming*, never clicks.** In
  `.openHand` mode an open hand arms cursor control; a fist (3+ fingers
  curled) parks it. *Arming* requires all four pose bands extended **and**
  `openness()` above `poseThresholds.openHandMinOpenness` (the strictness
  slider) **and** engage-grade joint confidence — the angle bands alone are
  fooled by fingers curled toward the camera (their 2D projection stays
  straight), which let closed hands seize the cursor. *Disarming* still uses
  the permissive pose bands only, and is blocked while any button is engaged
  or held, because a click closes part of the hand. The scroll pose folds
  only two fingers, so it never trips the three-finger disarm line.
  Arming belongs to the *hand*, never to the slot that survives it: when the
  armed hand goes missing while a bystander stays visible, primary holds
  through the tracking-loss grace (a one-frame Vision dropout must not hand
  the cursor — or a held drag — to a hand that never opted in), and past the
  grace the survivor inherits control only if it is showing the trigger at
  that moment. Otherwise any press the departed hand held lands where it
  was, once, and the ceremony starts over — which is what lets a returning
  open hand reclaim primary from the resting hand that inherited its slot.
- **Low-confidence frames hold state, never flap it.** A missing fingertip
  must not release a held button; only the tracking-loss grace window does.
- **Synthetic mouse events must be paced ≥ ~6 ms apart.** Two CGEvents posted
  back-to-back are intermittently dropped by macOS (measured: 20% of mouseUps
  at 0 ms), and a lost mouseUp wedges the target app into thinking the button
  is still down. `MouseController` posts through a serial pacing queue —
  don't bypass it.
- **The interaction box is a coordinate transform**, so it can never change
  mid-press (auto-reach freezes while a button is held).

## The gesture set (and how to grow it)

The click is the **index tap**, full stop. Three alternative click modes
(pinch, whole-hand pinch, thumb curl) shipped behind a picker through v6;
real-world testing settled on the mouse tap — the hand stays open and visible,
so tracking never guesses at overlapping fingers — and the picker was removed.
Their code lives in git history; the tolerant config decoders simply ignore
the retired `clickGesture` key, which is the whole retirement path (no
migrations needed).

**Scroll** is a fold-in pose: middle + ring folded in, index + little up
(thumb ignored). Its constraints, each deliberate:

- **Engage strict, hold loose.** Starting a scroll needs the folded fingers
  genuinely *curled* (`isScrollPose`); staying in one only needs them *not
  extended* (`isScrollPoseHeld`) — the neutral band between the pose bands is
  free hysteresis, same trick as the control trigger. Both directions still
  run the shared frame debounce.
- **The cursor parks while scrolling.** Wheel events land wherever the
  pointer already is; letting the cursor follow the scrolling hand would
  drag the scroll target out from under it.
- **Deltas are anchor-based with the drag jitter deadband**: shimmer emits
  nothing, slow travel accumulates against the unmoved anchor. Positive
  `.scroll` delta = scroll up (Quartz's positive axis-1); the invert setting
  flips it in the engine, and `MouseController` posts continuous pixel
  scroll events through the same pacing queue as everything else.
- **A press always wins**: scroll can't engage while a button is down, and an
  active scroll blocks both buttons' engage.
- **Right-click on middle or ring gets one extra engage guard** while scroll
  is on (`scrollPoseBlocksRightClick`): folding middle + ring together into
  the pose transiently reads as one of them dipping ahead of its reference,
  so that finger's dip only engages while the pose's *other* folding finger
  is still extended. A genuine dip keeps the rest of the hand up.

**The criss-cross tracking-off wave** (optional, on by default): both hands
up, open and splayed, then traded sides `crissCrossDisableCrossings` times
(default 2 — over and back). Its constraints, each deliberate:

- **Chirality, never slot identity, orders the palms.** Greedy slot matching
  swaps identities at exactly the moment the hands overlap — the moment this
  gesture is about — so a crossing is the *left/right-labeled* palms trading
  sides. Frames with unknown or duplicated chirality hold state.
- **Crossings only count outside a separation band** (±0.10 screen-normalized
  x) and after the shared debounce, so midline jitter and one-frame label
  glitches never count.
- **The cursor parks once the first crossing lands** (not on engage — two
  static open hands must not freeze the cursor), and both buttons' engage is
  blocked while the wave is engaged.
- **Two escape hatches**: a partner hand Vision drops mid-crossing gets the
  tracking-loss grace, and a wave that stalls for 2 s resets outright, so an
  idle double high-five can never park the cursor for good. A genuinely
  curled finger on either hand (debounced) is the deliberate exit.
- **Completion emits `.disableTracking`**, the one non-mouse `GestureEvent`:
  `PawvisController` intercepts it before `mouse.apply` and calls
  `stopTracking()` — the same full stop as the menu bar switch.

A new pose-triggered mode wants the same shape: a pose (or ratio) in
`HandFeatures`, strict-engage/loose-hold hysteresis, debounce both ways, an
explicit story for how it interacts with presses and the trigger, synthetic
poses in `SyntheticHands.swift`, and tests covering engage, release, the
band, tracking loss, and the guards. Copy lives in `SettingsView` and
`GestureGuideView` — and so does a picture: add the pose to
`scripts/make_gesture_glyphs.py` (see [Gesture art](#gesture-art)) rather than
reaching for an SF Symbol, because the symbols are what taught the wrong
gesture last time.

**The custom one-shot gestures** (`CustomGestureDetector`; every gesture
listed in Settings → Gestures, none live until given an action; the
Tracking tab's "custom gestures only" trigger keeps the mouse untouched
while these still fire) follow the
same rules plus a few that only real video could teach — every one below
was a measured failure first, and `--gesture-eval` over the clips in
question is how they were fixed. Do not retune these from intuition:

- **The grab is the fingertip bunch, not the palm's shape.** A real gather
  forms its bunch *in front of* the palm, so palm-relative measures
  (openness, extension bands, splay) all misread it at some orientation —
  each was tried and each silently vetoed a real grab. `isGathered` reads
  the mean spread of all five tips around their own centroid (the thumb
  being one of the five is what excludes every thumb-out look-alike:
  thumb signals, the shaka, open hands), with a closed-fist openness
  fallback for palm-on gathers; the fling is tracked at `gatherPoint()` —
  the bunch — not the palm. "Grab tightness" in the tuning row is the
  spread ceiling.
- **A grab closes from rest.** The engage stillness gate is what separates
  it from a relaxed closed hand travelling through the frame (the measured
  false-fling); the fling comes *after* the gather, not with it.
- **Unreadable geometry holds, like every other missing signal.** The first
  frames of a fling blur the fingertips into nothing; treating that as
  "opened" released a real grab right before its fling. `isGatherHeld`
  returns nil when neither measure is readable, and the caller holds.
- **The wiggle is two gestures, told apart by orientation.** Raised (palm
  to the camera) counts fingertip-extent oscillation; pointed (hand flat,
  fingers at the screen) counts fingertip *drop* below the knuckle line,
  normalized by the knuckle span because the wrist→knuckle scale collapses
  in exactly that pose (and openness, riding that scale, means nothing
  there — don't gate the pointed wiggle on it). One machine per hand with a
  dominant orientation: switching requires a debounced run of the opposite
  pose and restarts the buffers, and an opposed frame feeds *neither*
  machine — the measure swing of the pose change itself once completed the
  old machine's count. The pointed thresholds are geometry-derived
  defaults, newer than the rest of this list: retune them the same
  `--gesture-eval` way, not by intuition.
- **Thumb signals are cones with a gap.** Each of the four directions
  demands 1.5× axis dominance from the thumb-tip vector, so the in-between
  angles of a rotating (or resting) thumb match nothing.
- **The thumb-signal fist is read by its collapsed tips, not its angles.**
  The natural thumbs-up faces its knuckles at the camera, where the curled
  chains project as straight lines — the angle-band `isFist` never
  matches, and thumb signals simply didn't engage on real hands.
  `isClosedHand` (openness ≤ 0.15, thumb excluded) is the
  orientation-proof fist read; both engage and hold accept either. The
  *pointed* hand also collapses its tips while its thumb juts sideways —
  a phantom thumb signal — so the hold family stands down whenever
  `wiggleOrientation()` reads pointed.
- **A pointed hand parks the mouse.** Off-beat drumming swings the
  index-vs-middle tap differential exactly like index taps (measured: the
  pointed wiggle clicked on whatever was under the cursor), so the engine
  keeps a debounced pointed-pose park: cursor holds still, neither button
  may *engage*, in-flight presses still drag and release. Enter fast
  (2 frames), leave deliberately (4) — the first strikes of a drum land
  immediately, and a lift at the top of the beat must not unpark.
- **Hold poses show a countdown.** A pose that must dwell for a beat is
  invisible until it fires, and invisible reads as broken: the detector
  exposes `holdProgress` (gesture + seconds remaining), the engine
  surfaces it, and the pill paints a live countdown while the dwell runs.
- **A sweeping palm can't begin a press** (`pressEngageMaxSpeed`): fast
  motion blur fakes finger dips (two phantom clicks in one seven-second
  clip). Engage-only, like every such gate — a held press still drags and
  releases at any speed.
- **The open-palm swipes were retired.** Real sweeps blur into dropped
  frames, close mid-arc, and mirror themselves on the return stroke; even
  the endpoint model that finally fired on clean clips was never going to
  be trustworthy live. Their code lives in git history, and the tolerant
  decoders drop saved swipe bindings on sight — the standard retirement
  path. Re-introducing them means beating those failure modes on
  `--gesture-eval` clips first.

**User-trained gestures** (`GestureTrace`, `TakeRecorder`,
`TrainedGestureBuilder`, `TrainedGestureDetector` — all pure PawvisCore):
the trainer window records 3–10 takes; a take is segmented from the live
stream by motion (or captured as a held pose after a grace), reduced to
16 keyframes of palm-relative fingertip offsets plus scale-normalized
palm travel, and takes are averaged along DTW alignment to their medoid.
The matching threshold is calibrated from the takes' own spread; the
per-gesture sensitivity slider scales it (0.7×–1.6×). Live matching
DTW-scores a rolling window at three tempo scales and fires under the
threshold. Its constraints:

- **Matching runs in camera space.** Templates are recorded from raw
  camera hands, so the engine feeds the detector `TrackedHand.raw` — never
  the screen-space stream, which is mirrored and stretched through the
  interaction box, where a camera-space template can never match
  (measured: trained gestures fired in the trainer and never in use).
- **Training suspends control.** The trainer taps the camera stream ahead
  of the engine (`PawvisController.beginTraining`): nothing reaches the
  mouse or the other detectors while the window is open, because training
  must not fight the very motions it records.
- **Firing latches until the match visibly breaks** (distance 1.3× over
  threshold), so a *held* trained pose fires once per performance, not
  once per refractory — the custom hold-pose lesson, applied here.
- **Hold-to-confirm is per gesture** (`holdSeconds`, default 0): the match
  must hold continuously that long before firing, with a small hysteresis
  so a one-frame flicker doesn't reset the clock, and the pill counts the
  dwell down. Raise it for pose-like gestures.
- **The mouse-priority toggle decides who wins a finger curl**
  (`mouseOverride`, default on): matching keeps running through presses —
  a gesture that dips the index finger would otherwise click and cancel
  its own match every time — and while a match is dwelling, both buttons'
  *engage* is blocked. A dip that lands before recognition still clicks;
  the hold time is what shrinks that window. Off restores "a press always
  wins" in full. The criss-cross wave stands matching down either way,
  and a two-hand gesture matches only the ordered left-to-right pair
  stream: half the pair is not the gesture.
- **The representation is translation- and distance-invariant, not
  rotation-invariant.** A swipe left and a swipe right are different
  gestures — which is what you want from a trained library.
- **Templates persist, takes don't.** Settings hold the learned keyframes
  and calibration only (element-tolerant list, like the bindings);
  retraining means re-recording.
- **The badge is the icon.** A trained gesture draws its own learned
  motion — palm trail plus fingertip dots in `PawvisTheme.fingerDots` —
  instead of generated SVG art; the trainer's live overlay uses the same
  colors, so the badge reads as a replay of what you did.

## Gesture actions

How a bound gesture's action actually reaches macOS
(`GestureActionRunner`), all of it measured on macOS 26 — verify any change
with `--action-eval`, not by reading Apple's documentation, which describes
none of this:

- **Synthetic key chords need the fn flag and real modifier key events.**
  The system's own hotkeys are registered with the secondary-fn bit for
  fn-block keys (show desktop is literally fn+F11's mask, Mission Control
  control+fn+up), and synthetic presses without it are simply not matched;
  hardware always carries it. `TextTyper.press` adds the flag for fn-block
  keycodes and posts the modifiers as their own paced key events around the
  main key. F11 alone did nothing; F11+fn showed the desktop.
- **Spaces switching refuses ALL synthetic input — and SkyLight's setter
  is a phantom from outside Dock.** Every input recipe was tried:
  flags-only, real modifier events, flagsChanged-typed modifiers, fn/numpad
  flag combinations, held modifiers, System Events, posting to the Dock's
  pid, clicking Mission Control's spaces-bar thumbnails (whose AX frames are
  correct, whose window thumbnails DO respond to synthetic clicks, and whose
  AXPress is inert). Spotlight and Mission Control fire from the same
  recipes that Spaces ignores. `SLSManagedDisplaySetCurrentSpace` looked
  like the answer and shipped as one — wrongly: called from a normal
  process it updates the window server's *bookkeeping*, so
  `SLSGetActiveSpace` reports the new space, but the screen never moves;
  the visible switch also needs state private to Dock (yabai injects code
  into Dock to make that very call). Verifying the switch against
  `SLSGetActiveSpace` was an echo chamber — it read our own phantom write
  back, and `--action-eval` "passed" while no screen anywhere changed. The
  lesson for evals generally: verify against something the write path
  cannot touch — here, that meant human eyes on the screen at least once.
  What actually switches, SIP on, no injection, is the WindowServer's own
  gesture pipeline: a synthesized Dock-swipe CGEvent (undocumented gesture
  fields; one Began/Ended phase pair per ring step; the technique
  BetterTouchTool ships and yabai falls back to without its scripting
  addition), measured live — the screen moves. The swipe lands on the
  display under the pointer (the WindowServer's routing rule for space
  gestures), so ring, step count, and verification are all computed for
  that display — matched by UUID (`pointerDisplay`, selftest-covered),
  with a refusal rather than a guess when the match fails. SkyLight
  remains, read-only, in `SpaceSwitcher`: each display's ring and current
  space via dlsym, reporting
  honestly ("Desktop switching isn't available on this macOS") if a future
  macOS removes the symbols; the read-back verification is meaningful again
  precisely because nothing writes it anymore. Nothing else may grow a
  SkyLight dependency casually. The ring `SLSCopyManagedDisplaySpaces`
  returns mixes user desktops (type 0) with full-screen app spaces (type
  4); `neighborDesktop` steps across the full-screen ones — landing on
  someone's full-screen window reads as window shuffling, not desktop
  switching (measured: the reported symptom) — and exits *from* a
  full-screen space to the nearest desktop on that side. The swipe walks
  every ring entry, so a skipped full-screen space costs an extra swipe
  step (`swipeSteps`, selftest-covered).
- **Window placement is AX geometry** (`WindowPlacer` applying
  `WindowPlacement`'s unit-tested rect math), the same Accessibility
  permission the mouse already needs. Fire-and-forget actions (the desktop
  switch) report a follow-up line through `GestureActionRunner.onFollowUp`,
  which replaces the provisional pill text.

## Gesture art

The posed hands in the Gesture Guide and the site's gestures grid are drawn by
`scripts/make_gesture_glyphs.py` into `docs/assets/gestures/*.svg`. Run it by
hand after changing a pose (like `make_banner.sh`), and commit the SVGs:

```bash
python3 scripts/make_gesture_glyphs.py
```

- **One file set, two consumers.** The site loads them as `<img class="glyph">`
  and `make_app.sh` copies them into the bundle as `gesture-*.svg`, where
  `PawvisGlyph.gesture` loads them. A pose can't disagree between the app and
  the page because there is only one of it.
- **Two formats from one kit.** The 48×48 icons pose one hand (Settings
  rows, the site's grid); the 104×48 `full-*` panels draw the *whole*
  gesture — before-and-after frames, motion arrows — and lead every
  Gesture Guide row (`PawvisGlyph.guidePanel`). A new gesture adds both,
  and `--selftest` asserts each is in the bundle.
- **The app tints them, so the colors inside don't matter to it.** They are
  loaded as template images (`NSImage` renders SVG as a vector rep, and
  template rendering keys off alpha alone), which is also why the hand and the
  accent flatten into one color in the guide. The colors baked into the files
  are the site's own `--purple-light` / `--blue-light`.
- **Draw the gesture, not a metaphor.** Every glyph is the same hand with the
  fingers the gesture actually moves folded, and an arrow through the column
  they vacated. The SF Symbols this replaced were teaching poses the engine
  does not implement: a *pinch* for the click, a pointing finger for move.
- **Right-click follows its setting.** There is a glyph per finger the picker
  offers, and the guide shows the configured one.

## Voice control

Free-form commands descend an interpretation ladder, going only as far as
they must. The bottom rung drives the screen through on-device Apple
Intelligence, a small (~3B-parameter, 4096-token) model that's reliable at
translating one sentence and unreliable at sequencing a multi-step GUI task,
so anything answerable without looking at the screen must never reach it.
The regression that forced this: "Pawvis, open discord dot com in Chrome"
used to mis-parse as an app launch of an app literally named "discord dot
com in Chrome"; the failure then fell into the GUI autopilot loop, where the
model clicked Finder, opened Chrome's File menu, hovered "New Incognito
Window", and then claimed success. Two root causes: simple operations were
being routed to the least reliable layer, and completion was model-asserted
rather than verified.

1. **Deterministic grammar** (`VoiceControlParser`, pure `PawvisCore`,
   unit-tested): wake word + verb phrases. Understands URL-shaped targets
   after open/go-to verbs ("open discord dot com" → `goTo` discord.com) and
   a trailing app qualifier, `<target> in/with/using <app>` ("open discord
   dot com in Chrome" → `goTo(discord.com, app: Chrome)`). A non-URL payload
   with a known-browser qualifier becomes an address-bar search in that
   browser ("open discord in chrome"); browser-furniture payloads (tab,
   window, incognito) and pronouns are refused rather than turned into
   nonsense searches.
2. **One-shot intent translation** (new stage: `TranslationPolicy` in
   `PawvisCore`, plus a dedicated FoundationModels session in
   `AutopilotEngine`): one screen-free guided-generation round that
   translates the utterance into a single primitive, openApp / switchToApp /
   goToURL / webSearch / pressKey / quitApp, or `needsScreen`. Exists because
   the same small model that flails at sequencing a GUI task is reliable at
   constrained one-sentence translation. Compiled commands are validated
   through the same parsers that execute them
   (`TranslationPolicy.command(from:)`); anything unusable falls through to
   the loop, and a translated command that then fails execution reports that
   honestly rather than cascading into the loop.
3. **Visual autopilot loop** (last resort): only for goals genuinely about
   the screen, click-family goals, multi-clause goals ("open notes and start
   a new note"), or `needsScreen` translations.
   `AutopilotPolicy.goesStraightToLoop` is the routing predicate. The
   initial snapshot is now near-pointer only for click-family goals;
   everything else starts full-screen.

**Wake-word acceptance has tiers**, strictest first
(`VoiceControlParser.wakeMatch`):

1. Utterance-initial, edit distance ≤ 1 — the original bar.
2. After leading filler ("Um, Pawvis, open chrome") — filler is skipped, but
   the wake word must still match.
3. Glued mid-utterance (ambient speech joined to a command segment, ≤ 3 chunks
   deep) — accepted only when the remainder parses to a deterministic command
   ("she said Pawvis was busy" stays ambient).
4. Near tier (distance ≤ 2, filler-tolerant, never glue-tolerant) — acts only
   once `WakeRescuer` confirms the remainder reads as an instruction, now for
   the default on-device path too, not just agent mode.
5. Live-delta trust: a live hypothesis that matched the wake word, revised
   away by the final ("Pawvis" → "Paw this"), lets the near remainder act
   directly, no AI round-trip (`VoiceController.handleFinal`).

**Agent mode runs the ladder strict** (`VoiceControlConfig.strictWake`,
transient — never persisted; `VoiceController.setConfig` switches it on
whenever `agentExecutor` is non-empty, because an accept there hands the
utterance to a permissions-bypassed CLI): tier 3 is disabled outright, and
the utterance gate's capture window stops taking the next final verbatim — a
wake-less capture must itself parse deterministically
(`UtteranceGate.decide(strictCommandBar:)`; a final that carries the wake
word never consults the bar, so wake-led free-form speech still reaches the
agent). Tiers 1/2/4/5 stay. PawvisCore stays app-agnostic: the core takes
the flag, the app decides when it's on. Related hardening: "jarvis" left the
default aliases (a stock movie wake word made any TV audio a full-trust
accept; saved alias lists keep whatever they saved), the Settings wake-word
field trims on commit and snaps an emptied field back to the default, and a
wake word under `fuzzyMinCandidateLength` (six folded characters) shows a
"matches strictly" hint instead of silently losing edit-distance tolerance.

`Pawvis --wake-eval "<transcript as the recognizer wrote it>" …` prints the
tier verdict per transcript, no model — paste real mishearings to debug a
miss. New verbs must keep `.resolve` and the safety phrases out of a
sequence's member switch (below).

**Completion is verified, not asserted.** The model's `goalComplete` flag is
a hypothesis, checked against the world before a run is allowed to finish
(`AutopilotPolicy.completionCheck` + `AutopilotEngine.completionShortfall`):
`openApp`/`switchToApp` confirm the named app actually became frontmost
(`AppNameMatch`, the same fuzzy rules as resolution); `goToURL`/`webSearch`
confirm a browser is frontmost; click/scroll steps confirm the full-screen
accessibility signature changed at all, against a baseline snapshot taken
before the click. The signature covers element *values* as well as labels
and frames — a toggle flip is a value-only change (the switch's label and
frame are identical on both sides of the click), and a value-blind
signature read every successful toggle click as "nothing changed", so the
failed check made the loop click the switch again, undoing the user's
request until the failure cap aborted. Numeric values round to 2 decimals
in the hash so a slider's float noise never reads as change. A
verification failure becomes a failure-history line and
the loop keeps going: honest failure beats a fake success. `typeText` and
`pressKey` claims are still trusted as reported — an unverifiable false
negative would just mean blind, destructive repetition.

**Deterministic clause sequences.** Multi-clause utterances split at
standalone "and"/"then" and trailing commas
(`VoiceControlParser.clauseSequence`). When every clause parses to a plain
command, the utterance becomes `VoiceCommand.sequence` and runs in order with
focus verified between steps (`CommandExecutor.sequenceSettle`: an open/switch
step must see its app frontmost within 3 s or the chain stops honestly, no
model rescue mid-sequence). One unowned clause sends the whole utterance down
the ladder instead, and `.resolve`, `.sequence`, `.stopVoiceControl`,
`.cancelActivity` are excluded from membership, so safety phrases and
screen-needed goals can never join one.

Supporting grammar: "open up"/"pull up"/"bring up" verbs; "open a new tab" →
⌘T via `strippedChordPhrase`, never an app launch; "pause"/"play"/"resume" →
the hardware media key (`TextTyper.press(MediaKey)`), routed by macOS to
whatever's playing. Real example, now a selftest row: "pause this, open up a
new tab, and go to youtube dot com" → [media play-pause, ⌘T, `goTo`
youtube.com] — three verified steps, zero model.

**Focus discipline.** "open X"/"switch to X" mean X ends up frontmost,
verified: activate → `waitForFrontmost` → one retry; switch fails honestly
("Couldn't bring X to the front") rather than claiming success. `openApp` on
an already-running app falls through to an NSWorkspace re-launch when plain
`activate()` is ignored — deliberately the effect of ⌘Space+type+return via
the same call Spotlight uses, not synthetic keystrokes. The visual loop's
instructions now forbid `goToURL`/`webSearch` arguments taken from on-screen
text (a prompt rule, not a code guard): the model was copying the address bar
instead of the spoken destination.

**Keystroke delivery is a layer of its own, and it can lie.** Interpretation
was right for two releases while "go to youtube dot com" still opened the
CURRENT url in a background tab — a keystroke-layer bug no parse test could
see. Its constraints, each of which broke something real:

- **Every synthetic keyboard event states its modifiers explicitly.** A
  CGEvent created from a source inherits the source state's flags; after a
  flagged chord (⌘L), "unmodified" typing and the Return that followed
  intermittently went out ⌘-flagged — in Chrome's omnibox that is ignored
  text plus ⌘Return, which opens the still-selected current url in a
  background tab. `TextTyper` assigns `.flags` on every event, `[]` included;
  never rely on inheritance.
- **Return is gated on the field verifiably holding the typed text.**
  `driveAddressBar` waits for an editable focused element (the browser may
  still be becoming key), types, reads the value back over accessibility,
  retries once, and otherwise refuses to press Return — a Return into an
  unknown field state navigates to whatever is there.
- **Inline autocomplete is stripped before Return.** Omniboxes extend typed
  text with a selected completion ("youtube.com" → your most-visited channel
  page); a forward-delete removes it and is a no-op at end-of-text. The
  spoken words are the spec; land on exactly what was said.
- **`Pawvis --voice-exec "<utterance>" …` executes for real** — the same
  parser and executor as the voice path, step outcomes printed. It exists
  because `--voice-eval` can only prove interpretation; only a real
  execution catches delivery bugs. It controls the machine: no default
  corpus, explicit utterances only, deterministic commands only.

- **The logic is pure and lives in `PawvisCore`.** The parser and both
  policies (`VoiceControlParser`, `TranslationPolicy`, `AutopilotPolicy`) are
  plain Swift, model-free, and unit-tested; the app layer
  (`Sources/Pawvis/VoiceControl`) only owns the FoundationModels sessions and
  the side effects: opening apps, posting keys, driving the screen.
- **The browser-word list is vocabulary, not app resolution.** The static
  list in `VoiceControlParser` only recognizes that "Chrome" or "in Safari"
  names a browser; resolution stays in the executor (`AppCatalog`, in
  `CommandExecutor.swift`), which falls back to the default browser, saying
  so in the notice, when the named app doesn't resolve.
- **The selftest carries a voice-routing table.** `--selftest`
  (`Sources/Pawvis/App/SelfTest.swift`) asserts that the simple-operations
  class parses deterministically and never reaches the GUI loop. Extend that
  table when extending the grammar.
- **A seam for the next provider.** `PawvisCore` stays model-free, plain
  mirrors of the `@Generable` schemas; all FoundationModels usage is
  confined to `AutopilotEngine` behind two entry points, `translate` and
  `run`, so a different inference provider (OpenAI, etc.) can slot in behind
  the same seam later. Apple Intelligence is the only provider today.

## Secrets

Pawvis needs no API key and talks to no network service. Speech recognition is
Apple's on-device engine, visual commands go through on-device Apple
Intelligence, and icon art is derived from `claw.png` by
`scripts/process_claw.swift`, which calls nothing. Keep it that way — a feature
that wants a key is a design discussion, not an implementation detail. `.env`
stays git-ignored: never commit it, never print it, never bundle it.

## CI

`.github/workflows/ci.yml` runs `swift test`, `make app` and the bundle
self-test on every push and PR. The runner is pinned to **macos-26** because
the Apple speech engine compiles against the macOS 26 SDK
(`SpeechAnalyzer`); an older runner image will fail to build, not silently
degrade. If GitHub retires that label, move to the next macOS image that ships
Xcode 26+.

## Releases

**Merging a labelled pull request is the whole release procedure.** Every PR
carries exactly one of `major` / `minor` / `patch` saying how the version
moves, or `no-release` to merge without shipping — `.github/workflows/pr.yml`
fails the PR until it does, because the alternative is guessing, and a wrong
guess here ships a version number that can never be taken back. The labels
themselves come from `.github/workflows/labels.yml`, run once from the Actions
tab.

**Label the pull requests you open, at creation** — `gh pr create --label …`,
not as an afterthought for a human to fill in. Pick deliberately: the label
*is* the release decision, because merging is publishing.

**If the change reaches the app, it ships.** Anything that alters the built
`Pawvis.app` — `Sources/`, `Resources/`, `Package.swift`, the bundling in
`scripts/` — takes `major` / `minor` / `patch`, never `no-release`. A recolored
button, a swapped icon, a one-line copy fix in a settings pane: all of it is a
new build that users need a release to receive. Holding an app change back
under `no-release` strands it in `main`, where the next release silently
carries it out under someone else's version number and changelog.

- `patch` — fixes, small changes, and copy or asset tweaks inside the app
- `minor` — new features
- `major` — anything that breaks existing behavior
- `no-release` — **only** for changes that never reach the app: the splash page
  under `docs/`, the README, this file, and CI plumbing. Publishing a web page
  is not shipping an app version.

When a PR touches both the app and the site, it is an app PR: label it for the
bump the app change deserves.

On merge, `.github/workflows/release.yml` tests, stamps the version into
`Info.plist`, bundles, signs with Developer ID, notarizes, staples, zips, and
publishes a GitHub Release with `Pawvis.zip` plus its `.sha256`. Pushing a `v*`
tag by hand still works, and so does running the workflow manually with a bump
kind or an exact version.

There is no version file. The newest `v*` tag *is* the current version:
`scripts/next_version.sh` reads the tag list and does the arithmetic,
`scripts/select_bump.sh` turns the labels into a bump kind, and the tag is
created by the publish step at the very end — so a build that falls over leaves
no tag pointing at a release that is not coming. Both scripts run by hand:

```bash
LABELS='["minor"]' ./scripts/select_bump.sh   # minor
./scripts/next_version.sh minor               # 0.2.0
```

The merge path needs the PR to come from a branch in this repo: `GITHUB_TOKEN`
is read-only on fork pull requests and cannot publish. Release a fork's work by
pushing the tag once it has landed on main.

**Merging only ships if the PR targets `main`.** `release.yml` listens for PRs
closed against main — a PR merged into any other base branch produces no
release and its code never reaches main. This is how PR #2 was lost: it was
stacked on PR #3's head branch, #3 merged first, and merging #2 afterwards
just updated an orphaned branch. If you stack a PR, **retarget it to main once
the parent merges** — GitHub does this automatically when the parent's head
branch is deleted at merge time, so delete head branches when you merge (or
turn on "Automatically delete head branches" in the repo settings). The
`pr.yml` gate fails any PR whose base isn't main as the reminder.

**Keep the asset name fixed, not versioned.** It makes
`https://github.com/alexandriax/pawvis/releases/latest/download/Pawvis.zip` a
permanent download link (the README's button, which therefore never needs
editing per release), and leaves exactly one `.zip` per release so the
updater's asset pick is unambiguous.

The in-app updater reads `releases/latest` from the GitHub API, so the zip
asset must stay attached and keep that name; it verifies the download's
SHA-256 against the published checksum, checks the bundle identifier, and runs
`codesign --verify` before staging. Version comparison and the check-scheduling
rules live in `PawvisCore/Update` and are unit-tested.

A discovered release also posts a **system notification** (`UpdateNotifier`),
whose Install button opens Settings → About through `SettingsRouter`. Three
constraints worth keeping:

- **Once per version**, decided by `UpdatePolicy.shouldNotify` and remembered
  in `Pawvis.update.lastNotifiedVersion`. Every launch re-offers the same
  release until the user takes it; re-posting each time is nagging, and the
  menu bar row already carries the offer in the meantime. The mark is only
  written after the post actually succeeds.
- **Authorization is requested lazily**, at the moment there is finally
  something to announce. Asking at launch would put a permission prompt in
  front of every user, including everyone already up to date, and a denial is
  deliberately *not* recorded as "announced" so allowing it later still works.
- **`UNUserNotificationCenter.current()` is bundle-only.** From a bare
  `swift run` binary it traps on a nil bundle proxy (an ObjC exception no
  Swift `catch` can stop), so `UpdateNotifier` gates on the same
  `bundleIdentifier != nil && .app` check as `LoginItem`. The identifier
  check alone is NOT enough: under `swift test`, `Bundle.main` is Xcode's
  xctest tool — which *has* an identifier and still traps. Both halves are
  measured, keep both.

More measured notification behavior (macOS 26), for whoever touches this next:

- The permission prompt is a hover-to-expand *banner* (Allow hides in its
  "Options" dropdown), the `requestAuthorization` callback simply doesn't fire
  until the user answers — minutes, sometimes — and **killing the app while
  the prompt is pending records a denial**. That last one is easy to do from a
  dev loop; the only way back is System Settings → Notifications.
- `center.add` reports success even when denied (the item lands in the
  delivered list, invisibly), so posting is gated on authorization status, not
  on `add` failing.
- Notification permission keys off the **bundle identifier**, not the code
  signature — it survives re-signing, so `make_app.sh`'s ad-hoc warning about
  Accessibility does not extend to notifications.
- A bundle run from a temp directory gets `UNErrorDomain Code=1` with no
  prompt at all; the repo's `build/Pawvis.app` is a location LaunchServices
  accepts (verified).

`SettingsRouter` owns the `TabView` selection, which is also why the tab is
persisted by hand: SwiftUI only restores the last-viewed tab
(`com_apple_SwiftUI_Settings_selectedTabIndex`) while that selection is unbound.

Opening Settings from outside SwiftUI goes through `SettingsWindow`, and its
two rules are measured, not guessed (macOS 26): the folkloric
`NSApp.sendAction(Selector(("showSettingsWindow:")))` **returns true while
opening nothing**, so the real openers are an `OpenSettingsAction` captured at
launch from the `MenuBarExtra` label plus the app-menu "Settings…" item as
fallback; and the Settings window is identified by
`identifier == "com_apple_SwiftUI_Settings_window"`, never by title — macOS
titles it after the selected tab ("About"), so a title match quietly never
fronts anything.

Signing and notarization come from repository secrets, set by running
`scripts/setup_signing.sh` interactively (it never belongs in an automated
session — it handles a private key and passwords):

- `MACOS_CERT_P12`, `MACOS_CERT_PASSWORD` — the Developer ID certificate.
  **These are the ones that matter**: without them releases fall back to
  ad-hoc signing, and every update silently breaks Accessibility.
- Notarization, either `NOTARY_APPLE_ID` + `NOTARY_PASSWORD` (an
  app-specific password from account.apple.com — instant, no approval) +
  `NOTARY_TEAM_ID`, or `NOTARY_KEY_P8` + `NOTARY_KEY_ID` + `NOTARY_ISSUER_ID`
  (App Store Connect key; needs an access request Apple reviews). Without
  either, the build is signed but a fresh download needs right-click → Open.

With no secrets at all the workflow still succeeds (ad-hoc), so forks aren't
blocked. The notarize step asserts with `spctl` that a fresh download will
launch clean, so a broken signing setup fails the release rather than shipping
quietly.

## Website

`docs/` is the GitHub Pages site, <https://alexandriax.github.io/pawvis/>,
served straight from `main`'s `docs/` folder. Plain hand-written
`index.html` + `site.css` + `site.js`, no build step, no framework. Preview
with `python3 -m http.server` from `docs/` (or just open `index.html`).

**The site restates the README; the README stays the source of truth.** When
behavior changes (a gesture added or retired, a voice command, a permission, a
privacy claim, the macOS floor) update the matching section of
`docs/index.html` in the same PR. The gestures grid, the spoken-command chips,
the agent hand-off card and the permissions row are the places that go stale.

Rules that keep the site honest:

- **No em-dashes.** Not in `docs/`, not in the README. Rewrite the sentence:
  a comma, a colon, parentheses, or two sentences. This is a house style rule,
  so it applies to new copy as well as edits.
- **Say what leaves the machine, exactly.** The site's privacy section is the
  reason people trust the app, so it may only claim what is true in the
  shipped default: hand tracking, speech and Apple Intelligence really are
  on-device, and the optional agent hand-off really does send what you say to
  Claude Code or Codex. Any new feature that talks to a network gets named
  there before it gets marketed anywhere else on the page.
- **One third party, on purpose.** The page loads Google Analytics
  (`G-FPVSRRZQTY`) and nothing else: fonts are self-hosted woff2 in
  `docs/assets/fonts/`, the Product Hunt badge is a self-hosted SVG
  (`docs/assets/ph-badge.svg`, still linking out to producthunt.com), and
  there are no CDNs or other embeds. The analytics tag measures the
  *website*; it has no connection to the app, which still ships with no
  telemetry of any kind. Don't let the two get conflated in copy, and don't
  add a second external dependency casually.
- **The app screenshots and demo video are static, committed assets.**
  `docs/assets/app-*.png` (`app-gesture-guide.png`, `app-menu.png`,
  `app-settings-custom.png`, `app-settings-gestures.png`) are window captures
  of the running app, shot with alpha intact; retake them by hand after a UI
  change, keeping the same filenames. `docs/assets/demo.mp4` and its poster
  `demo-poster.jpg` are a generated demo film, made once with OpenAI's video
  API using the git-ignored `.env` key. The site itself needs no key, ever;
  the Secrets section above still holds. Regenerate only deliberately,
  keeping the same filenames.
- **The download button points at the permanent asset URL**
  (`releases/latest/download/Pawvis.zip`), same rule as the README button:
  never version it, and it never needs editing per release.
- **Icon art on the site derives from the committed sources.** Regenerate
  `docs/assets/icon-*.png` with `sips` from `icon.png` if it ever changes.
- **The gestures grid's hands are shared with the app.**
  `docs/assets/gestures/*.svg` are generated (see [Gesture art](#gesture-art))
  and copied into the app bundle at build time, so editing one by hand splits
  the page from the guide. Their colors are baked in rather than inherited
  from `.glyph`: if the palette moves, regenerate them.
- **The share card is derived, not drawn.** `docs/banner.png` (the Open Graph
  / Twitter image) renders from `scripts/banner.html` via
  `./scripts/make_banner.sh`, reusing the site's own fonts, palette and claw
  art. Restyle the splash page and re-run it rather than hand-editing a PNG;
  keep the 1200×630 Open Graph ratio and the filename, which the meta tags and
  every cached scrape point at.

Site-only pull requests take the `no-release` label: publishing a web page is
not shipping an app version. The moment a PR also touches the app, that stops
applying — see [Releases](#releases).
