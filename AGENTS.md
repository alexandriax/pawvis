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
  (engine, settings round-trip, realtime protocol, dictation parser, keychain).
- `PAWVIS_NO_AUTOSTART=1` — launch without starting tracking, so automated
  runs don't trip the camera permission prompt.
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
   There is no headless shortcut: SwiftUI's `ImageRenderer` produces blank
   output for these views without a running app, and the `Settings` scene
   can't be opened programmatically from a launch hook in a menu-bar-only
   app. Run `make app`, open Pawvis, and check the tabs — paying attention to
   the longest strings (the OpenAI dictation section has them).

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

A new pose-triggered mode wants the same shape: a pose (or ratio) in
`HandFeatures`, strict-engage/loose-hold hysteresis, debounce both ways, an
explicit story for how it interacts with presses and the trigger, synthetic
poses in `SyntheticHands.swift`, and tests covering engage, release, the
band, tracking loss, and the guards. Copy lives in `SettingsView` and
`GestureGuideView`.

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
the Apple dictation engine compiles against the macOS 26 SDK
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
not as an afterthought for a human to fill in. `patch` for fixes, docs and
chores; `minor` for features; `major` for anything that breaks existing
behavior; `no-release` when the change should not ship on its own (CI
plumbing, this file). Pick deliberately: the label *is* the release decision,
because merging is publishing.

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
