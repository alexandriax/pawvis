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
   tracking, gestures, voice, about) opens Settings on that tab right after
   launch, so `make app` + launch + `screencapture` covers it without
   hand-clicking. Pay attention to the longest strings (the Voice control and
   Tracking tabs have them).

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
  `docs/assets/fonts/`, and there are no CDNs, badge images or other embeds.
  The analytics tag measures the *website*; it has no connection to the app,
  which still ships with no telemetry of any kind. Don't let the two get
  conflated in copy, and don't add a second external dependency casually.
- **The photography and demo video are static, committed assets**
  (`docs/assets/*.jpg`, `demo.mp4`), generated once with OpenAI's image/video
  APIs using the git-ignored `.env` key. The site itself needs no key, ever;
  the Secrets section above still holds. Regenerate only deliberately, keeping
  the same filenames (`hero-office.jpg`, `gesture-closeup.jpg`,
  `voice-command.jpg`, `demo.mp4`).
- **The download button points at the permanent asset URL**
  (`releases/latest/download/Pawvis.zip`), same rule as the README button:
  never version it, and it never needs editing per release.
- **Icon art on the site derives from the committed sources.** Regenerate
  `docs/assets/icon-*.png` with `sips` from `icon.png` if it ever changes.
- **The share card is derived, not drawn.** `docs/banner.png` (the Open Graph
  / Twitter image) renders from `scripts/banner.html` via
  `./scripts/make_banner.sh`, reusing the site's own fonts, palette and claw
  art. Restyle the splash page and re-run it rather than hand-editing a PNG;
  keep the 1200×630 Open Graph ratio and the filename, which the meta tags and
  every cached scrape point at.

Site-only pull requests take the `no-release` label: publishing a web page is
not shipping an app version. The moment a PR also touches the app, that stops
applying — see [Releases](#releases).
