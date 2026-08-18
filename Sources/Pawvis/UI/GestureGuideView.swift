import PawvisCore
import SwiftUI

/// A reference card for the whole gesture set.
///
/// Every gesture row leads with a drawn *panel* of the full gesture — the
/// before-and-after of a click, the gather-then-fling of a grab, the
/// drumming fingers of a wiggle — from the same generated art set as the
/// small posed-hand icons (`docs/assets/gestures`, via
/// `scripts/make_gesture_glyphs.py`). Panels replaced both the SF Symbols
/// (which taught poses the engine doesn't implement) and the single posed
/// hands (which showed the shape but not the motion).
///
/// The custom gestures are all listed, bound or not: the guide is where you
/// find out what the app can watch for, and a bound row also says what its
/// gesture is currently set to do. The old empty-state pitch box is gone —
/// the library itself is the pitch.
struct GestureGuideView: View {
    @ObservedObject var store: SettingsStore

    var body: some View {
        ScrollView {
            VStack(alignment: .leading, spacing: 18) {
                Text("Gesture Guide")
                    .font(.largeTitle.bold())
                Text("Face the camera with one hand up. The claw is your cursor; the dots are your fingertips.")
                    .foregroundStyle(.secondary)

                if store.settings.gestures.controlTrigger == .gesturesOnly {
                    pointingOffNote
                } else {
                    section("Pointing & Clicking", rows: pointingRows)
                }
                customGesturesSection
                section("Voice Control", rows: voiceRows)
            }
            .padding(24)
            .frame(maxWidth: .infinity, alignment: .leading)
        }
        .frame(minWidth: 560, minHeight: 480)
        .tint(PawvisTheme.accentUI)
    }

    private struct Row {
        let symbol: String
        /// The whole-gesture panel (`full-*`), when the gesture has one.
        /// `symbol` is the fallback: the bare binary has no bundle to load
        /// art from.
        var panel: String?
        let title: String
        let detail: String
        /// "This variant → what it's bound to" lines, for the custom rows.
        var bindings: [String] = []

        init(symbol: String, panel: String? = nil, title: String,
             detail: String, bindings: [String] = []) {
            self.symbol = symbol
            self.panel = panel
            self.title = title
            self.detail = detail
            self.bindings = bindings
        }
    }

    private var pointingRows: [Row] {
        var rows: [Row] = []
        if store.settings.gestures.controlTrigger == .openHand {
            rows.append(Row(
                symbol: "hand.raised.fill",
                panel: "full-take-control",
                title: "Take control",
                detail: "Show the camera an open hand — all four fingers up — and the claw brightens: you have the cursor. Pawvis keeps watching while you type or rest, but the cursor stays parked until you show the trigger. Make a brief fist to park it again."))
        }
        rows += [
            Row(symbol: "hand.raised.fill",
                panel: "full-move",
                title: "Move",
                detail: "Hold your hand open, fingers up, and move it — the claw cursor rides your \(store.settings.gestures.pointerSource.inlineName). The ring around the claw tightens as the click gesture forms."),
            Row(symbol: "hand.point.up.left.fill",
                panel: "full-click",
                title: "Click",
                detail: "Dip your index finger down, like tapping a mouse button (keep your other fingers up). Release quickly for a clean click — small wobbles are ignored. Twice quickly = double-click, three times = triple."),
            Row(symbol: "hand.draw.fill",
                panel: "full-drag",
                title: "Drag / hold",
                detail: "Hold the click gesture and move — grab a window title bar, select text, drag files. The button stays down until you lift your index finger. (Deliberate movement starts the drag right away; otherwise it begins after the click-vs-grab delay.)"),
        ]

        if store.settings.gestures.dwellClickEnabled {
            rows.append(Row(
                symbol: "timer",
                title: "Dwell click",
                detail: "Hold the cursor still on a target and the ring tightens; after \(String(format: "%.1f", store.settings.gestures.dwellSeconds)) s of stillness a left click fires on its own. Move the cursor away, then settle again, for the next one. Holding a button, scrolling, or a parked cursor never dwells."))
        }

        if store.settings.gestures.rightClickEnabled {
            let finger = store.settings.gestures.rightClickFinger
            let fingerName = finger == .little ? "pinky" : finger.rawValue
            rows.append(Row(
                symbol: "hand.point.right.fill",
                panel: "full-right-click-\(finger.rawValue)",
                title: "Right-click",
                detail: "Dip your \(fingerName) finger the same way — the claw turns blue while it's down. Hold it to right-drag."))
        }

        if store.settings.gestures.middleClickEnabled {
            let finger = store.settings.gestures.middleClickFinger
            let fingerName = finger == .little ? "pinky" : finger.rawValue
            rows.append(Row(
                symbol: "hand.point.up.braille.fill",
                panel: "full-right-click-\(finger.rawValue)",
                title: "Middle-click",
                detail: "Dip your \(fingerName) finger the same way — the claw turns pink while it's down. Hold it to middle-drag."))
        }

        if store.settings.gestures.scrollEnabled {
            let direction = store.settings.gestures.scrollInvert
                ? "Move your hand up to scroll down and down to scroll up (you inverted the direction in Settings)."
                : "Move your hand up to scroll up and down to scroll down."
            let sideways = store.settings.gestures.scrollAxes == .both
                ? " Sideways movement scrolls sideways."
                : ""
            rows.append(Row(
                symbol: "arrow.up.arrow.down.circle.fill",
                panel: "full-scroll",
                title: "Scroll",
                detail: "Fold your middle and ring fingers in — index and pinky stay up. \(direction)\(sideways) The cursor parks (with a light-blue ring) while the pose is held; relax your hand to let go."))
        }

        if store.settings.gestures.crissCrossDisableEnabled {
            let crossings = store.settings.gestures.crissCrossDisableCrossings
            rows.append(Row(
                symbol: "hand.raised.fingers.spread.fill",
                panel: "full-stop-tracking",
                title: "Stop tracking",
                detail: "Hold up both hands open with fingers spread wide — a double high-five — and wave them across each other. Once they've traded sides \(crossings == 2 ? "twice (over and back)" : "\(crossings) times"), tracking switches off entirely. Turn it back on from the menu bar."))
        }
        return rows
    }

    /// Gestures-only mode: the mouse set is off, and saying so beats listing
    /// gestures that would do nothing.
    private var pointingOffNote: some View {
        VStack(alignment: .leading, spacing: 10) {
            Text("Pointing & Clicking").font(.title3.bold())
            VStack(alignment: .leading, spacing: 6) {
                Text("Mouse control is off: you chose “custom gestures only” under Settings → Tracking. Your hands never move the cursor — they only trigger the gestures below (and the stop-tracking wave).")
                    .font(.callout)
                    .foregroundStyle(.secondary)
                    .fixedSize(horizontal: false, vertical: true)
                Button("Change in Settings…") {
                    SettingsRouter.shared.open(.tracking)
                }
            }
            .padding(10)
            .frame(maxWidth: .infinity, alignment: .leading)
            .background(RoundedRectangle(cornerRadius: 10).fill(.quaternary.opacity(0.5)))
        }
    }

    /// The custom-gesture library, every motion illustrated whether bound
    /// or not, with each variant's current action listed on its row.
    private var customGesturesSection: some View {
        VStack(alignment: .leading, spacing: 10) {
            Text("Custom Gestures").font(.title3.bold())
            VStack(alignment: .leading, spacing: 6) {
                Text("Each of these can run an action of your choosing: switch desktops, snap windows, press shortcuts, open apps, run commands. A gesture without an action is ignored entirely.")
                    .font(.callout)
                    .foregroundStyle(.secondary)
                    .fixedSize(horizontal: false, vertical: true)
                Button("Assign actions in Settings…") {
                    SettingsRouter.shared.open(.gestures)
                }
                if !store.settings.customGestures.enabled {
                    Text("Custom gestures are currently switched off in Settings → Gestures.")
                        .font(.caption)
                        .foregroundStyle(.secondary)
                        .fixedSize(horizontal: false, vertical: true)
                }
            }
            ForEach(customRows, id: \.title) { row in
                rowView(row)
            }
            ForEach(store.settings.trainedGestures.gestures) { gesture in
                trainedRowView(gesture)
            }
        }
    }

    /// A trained gesture's guide row: the animated badge replaying its own
    /// recorded motion, in place of generated art.
    private func trainedRowView(_ gesture: TrainedGesture) -> some View {
        HStack(alignment: .top, spacing: 14) {
            TrainedGestureBadge(gesture: gesture, size: 48)
                .frame(width: GestureArt.panelWidth)
            VStack(alignment: .leading, spacing: 2) {
                Text(gesture.name).font(.headline)
                Text("You taught Pawvis this one — \(gesture.handCount == 2 ? "both hands" : "one hand"), about \(String(format: "%.1f", max(gesture.duration, 0.3))) s. The badge replays the motion it learned.")
                    .font(.callout)
                    .foregroundStyle(.secondary)
                    .fixedSize(horizontal: false, vertical: true)
                if let line = trainedBindingLine(gesture) {
                    Text(line)
                        .font(.callout.weight(.medium))
                        .fixedSize(horizontal: false, vertical: true)
                        .padding(.top, 2)
                } else {
                    Text("Not assigned yet.")
                        .font(.callout)
                        .foregroundStyle(.tertiary)
                        .padding(.top, 2)
                }
            }
        }
        .padding(10)
        .frame(maxWidth: .infinity, alignment: .leading)
        .background(RoundedRectangle(cornerRadius: 10).fill(.quaternary.opacity(0.5)))
    }

    /// "→ what it does", with the compact per-app suffix when overrides
    /// exist — same treatment as the built-in rows. nil means unassigned.
    private func trainedBindingLine(_ gesture: TrainedGesture) -> String? {
        let perApp = gesture.overrides.filter { $0.action != nil }.count
        if let summary = gesture.action?.summary {
            let suffix = perApp > 0 ? " (+\(perApp) per-app)" : ""
            return "→ \(summary)\(suffix)"
        }
        guard perApp > 0 else { return nil }
        return "→ per-app actions in \(perApp) app\(perApp == 1 ? "" : "s")"
    }

    private var customRows: [Row] {
        let custom = store.settings.customGestures
        func bound(_ pairs: [(String, CustomGesture)]) -> [String] {
            pairs.compactMap { label, gesture in
                guard let binding = custom.binding(for: gesture) else { return nil }
                let perApp = binding.overrides.filter { $0.action != nil }.count
                if let summary = binding.action?.summary {
                    let suffix = perApp > 0 ? " (+\(perApp) per-app)" : ""
                    return "\(label) → \(summary)\(suffix)"
                }
                guard perApp > 0 else { return nil }
                return "\(label) → per-app actions in \(perApp) app\(perApp == 1 ? "" : "s")"
            }
        }
        return [
            Row(symbol: "hand.raised.fingers.spread.fill",
                panel: "full-wiggle",
                title: "Raised finger wiggle",
                detail: CustomGesture.fingerWiggle.howTo + " Both hands at once is its own gesture.",
                bindings: bound([("One hand", .fingerWiggle),
                                 ("Both hands", .twoHandFingerWiggle)])),
            Row(symbol: "hand.point.left.fill",
                panel: "full-wiggle-pointed",
                title: "Pointed finger wiggle",
                detail: CustomGesture.pointedWiggle.howTo + " Both hands at once is its own gesture.",
                bindings: bound([("One hand", .pointedWiggle),
                                 ("Both hands", .twoHandPointedWiggle)])),
            Row(symbol: "hand.thumbsup.fill",
                panel: "full-thumbs",
                title: "Thumb signals",
                detail: "Make a fist with your thumb out — up, down, or tilted to point straight left or right — and hold it for a beat. Each direction is its own gesture.",
                bindings: bound([("Thumbs up", .thumbsUp), ("Thumbs down", .thumbsDown),
                                 ("Thumb left", .thumbsLeft), ("Thumb right", .thumbsRight)])),
            Row(symbol: "hands.and.sparkles.fill",
                panel: "full-shaka",
                title: "Shaka",
                detail: CustomGesture.shaka.howTo,
                bindings: bound([("Shaka", .shaka)])),
            Row(symbol: "hand.pinch.fill",
                panel: "full-grab",
                title: "Grab & fling",
                detail: "Bunch all your fingertips onto your thumb, then fling the bunch toward any edge or corner — eight directions, each its own gesture. The cursor parks while you hold the grab.",
                bindings: bound([("Left", .grabFlingLeft), ("Right", .grabFlingRight),
                                 ("Up", .grabFlingUp), ("Down", .grabFlingDown),
                                 ("Up-left", .grabFlingUpLeft), ("Up-right", .grabFlingUpRight),
                                 ("Down-left", .grabFlingDownLeft), ("Down-right", .grabFlingDownRight)])),
        ]
    }

    private var voiceRows: [Row] {
        let wake = store.settings.voiceControl.wakeWord
        return [
            Row(symbol: "mic.fill",
                title: "Start voice control from the menu bar",
                detail: "Click the claw in the menu bar and press Start next to Voice control. Address it by name: “\(wake) go to github.com”, “\(wake) open Safari”, “\(wake) switch to Notes”, “\(wake) press command T”, “\(wake) scroll down”."),
            Row(symbol: "keyboard.fill",
                title: "Type by voice",
                detail: "Say \u{201c}\(wake) type good morning\u{201d} and exactly that text is typed into the focused app. Every command starts with the wake word \u{2014} speech without it is ignored."),
            Row(symbol: "sparkles",
                title: "Visual commands",
                detail: "Anything else — “\(wake) click sign in” — is resolved against the screen near your pointer with on-device Apple Intelligence."),
        ]
    }

    private func section(_ title: String, rows: [Row]) -> some View {
        VStack(alignment: .leading, spacing: 10) {
            Text(title).font(.title3.bold())
            ForEach(rows, id: \.title) { row in
                rowView(row)
            }
        }
    }

    private func rowView(_ row: Row) -> some View {
        HStack(alignment: .top, spacing: 14) {
            art(for: row)
            VStack(alignment: .leading, spacing: 2) {
                Text(row.title).font(.headline)
                Text(row.detail)
                    .font(.callout)
                    .foregroundStyle(.secondary)
                    .fixedSize(horizontal: false, vertical: true)
                ForEach(row.bindings, id: \.self) { line in
                    Text(line)
                        .font(.callout.weight(.medium))
                        .fixedSize(horizontal: false, vertical: true)
                        .padding(.top, 2)
                }
            }
        }
        .padding(10)
        .frame(maxWidth: .infinity, alignment: .leading)
        .background(RoundedRectangle(cornerRadius: 10).fill(.quaternary.opacity(0.5)))
    }

    /// The whole-gesture panel when the bundle has it, the SF Symbol when
    /// not (bare `swift run`). Voice rows have no panel and keep the symbol.
    @ViewBuilder
    private func art(for row: Row) -> some View {
        if let panel = row.panel, let image = GestureArt.panel(panel) {
            Image(nsImage: image)
                .renderingMode(.template)
                .foregroundStyle(.tint)
                .frame(width: GestureArt.panelWidth, alignment: .leading)
        } else {
            Image(systemName: row.symbol)
                .font(.title2)
                .foregroundStyle(.tint)
                .frame(width: 44)
        }
    }
}

/// Opening the guide from code with no SwiftUI environment. Same shape (and
/// same reason) as `SettingsWindow`: the opener is captured at launch from the
/// `MenuBarExtra` label, the one view a menu-bar app always instantiates.
@MainActor
enum GuideWindow {
    static let id = "gesture-guide"

    static var opener: OpenWindowAction?

    static func show() {
        opener?(id: id)
        // LSUIElement, so opening a window doesn't bring the app forward on
        // its own — see SettingsWindow for why activation happens twice.
        NSApp.activate(ignoringOtherApps: true)
        DispatchQueue.main.asyncAfter(deadline: .now() + 0.15) {
            NSApp.activate(ignoringOtherApps: true)
        }
    }
}

/// The guide panels, loaded once each. `PawvisGlyph` hands out fresh images
/// on purpose (callers resize them), but every row here draws at one size,
/// and the guide's body re-runs on each settings change — no reason to
/// re-read the files every time a slider moves.
@MainActor
private enum GestureArt {
    static let panelWidth: CGFloat = 108
    private static var cache: [String: NSImage?] = [:]

    static func panel(_ name: String) -> NSImage? {
        if let cached = cache[name] { return cached }
        let image = PawvisGlyph.guidePanel(name, width: panelWidth)
        cache[name] = image
        return image
    }
}
