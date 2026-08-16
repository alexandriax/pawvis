import PawvisCore
import SwiftUI

/// A reference card for the (deliberately small) gesture set.
///
/// Each pointing row is illustrated by a posed hand from
/// `docs/assets/gestures` rather than an SF Symbol, because the symbols were
/// quietly teaching the wrong gesture: the click wore `hand.pinch.fill` when
/// the click is an index *tap*, move wore a pointing finger when the cursor
/// rides an open palm, and right-click wore a sideways hand that said nothing
/// about which finger dips. The drawings show the actual pose, down to which
/// finger is folded — including the one the right-click setting picked.
struct GestureGuideView: View {
    @ObservedObject var store: SettingsStore

    var body: some View {
        ScrollView {
            VStack(alignment: .leading, spacing: 18) {
                Text("Gesture Guide")
                    .font(.largeTitle.bold())
                Text("Face the camera with one hand up. The claw is your cursor; the dots are your fingertips.")
                    .foregroundStyle(.secondary)

                section("Pointing & Clicking", rows: pointingRows)
                customGesturesSection
                section("Voice Control", rows: voiceRows)
            }
            .padding(24)
            .frame(maxWidth: .infinity, alignment: .leading)
        }
        .frame(minWidth: 520, minHeight: 480)
        .tint(PawvisTheme.accentUI)
    }

    private struct Row {
        let symbol: String
        /// The posed-hand glyph, when the gesture has one. `symbol` is the
        /// fallback: the bare binary has no bundle to load art from.
        var glyph: String?
        let title: String
        let detail: String

        init(symbol: String, glyph: String? = nil, title: String, detail: String) {
            self.symbol = symbol
            self.glyph = glyph
            self.title = title
            self.detail = detail
        }
    }

    private var pointingRows: [Row] {
        var rows: [Row] = []
        if store.settings.gestures.controlTrigger == .openHand {
            rows.append(Row(
                symbol: "hand.raised.fill",
                glyph: "take-control",
                title: "Take control",
                detail: "Show the camera an open hand — all four fingers up — and the claw brightens: you have the cursor. Pawvis keeps watching while you type or rest, but the cursor stays parked until you show the trigger. Make a brief fist to park it again."))
        }
        rows += [
            Row(symbol: "hand.raised.fill",
                glyph: "move",
                title: "Move",
                detail: "Hold your hand open, fingers up, and move it — the claw cursor rides your palm. The ring around the claw tightens as the click gesture forms."),
            Row(symbol: "hand.point.up.left.fill",
                glyph: "click",
                title: "Click",
                detail: "Dip your index finger down, like tapping a mouse button (keep your other fingers up). Release quickly for a clean click — small wobbles are ignored. Twice quickly = double-click, three times = triple."),
            Row(symbol: "hand.draw.fill",
                glyph: "drag",
                title: "Drag / hold",
                detail: "Hold the click gesture and move — grab a window title bar, select text, drag files. The button stays down until you lift your index finger. (Deliberate movement starts the drag right away; otherwise it begins after the click-vs-grab delay.)"),
        ]

        if store.settings.gestures.rightClickEnabled {
            let finger = store.settings.gestures.rightClickFinger
            let fingerName = finger == .little ? "pinky" : finger.rawValue
            rows.append(Row(
                symbol: "hand.point.right.fill",
                glyph: "right-click-\(finger.rawValue)",
                title: "Right-click",
                detail: "Dip your \(fingerName) finger the same way — the claw turns blue while it's down. Hold it to right-drag."))
        }

        if store.settings.gestures.scrollEnabled {
            let direction = store.settings.gestures.scrollInvert
                ? "Move your hand up to scroll down and down to scroll up (you inverted the direction in Settings)."
                : "Move your hand up to scroll up and down to scroll down."
            rows.append(Row(
                symbol: "arrow.up.arrow.down.circle.fill",
                glyph: "scroll",
                title: "Scroll",
                detail: "Fold your middle and ring fingers in — index and pinky stay up. \(direction) The cursor parks (with a light-blue ring) while the pose is held; relax your hand to let go."))
        }

        if store.settings.gestures.crissCrossDisableEnabled {
            let crossings = store.settings.gestures.crissCrossDisableCrossings
            rows.append(Row(
                symbol: "hand.raised.fingers.spread.fill",
                glyph: "stop-tracking",
                title: "Stop tracking",
                detail: "Hold up both hands open with fingers spread wide — a double high-five — and wave them across each other. Once they've traded sides \(crossings == 2 ? "twice (over and back)" : "\(crossings) times"), tracking switches off entirely. Turn it back on from the menu bar."))
        }
        return rows
    }

    /// The user's bound custom gestures, illustrated like the built-ins —
    /// or, before any exist, a pointer at where to add them.
    @ViewBuilder
    private var customGesturesSection: some View {
        let bound = store.settings.customGestures.bindings.filter { $0.action != nil }
        if bound.isEmpty {
            VStack(alignment: .leading, spacing: 10) {
                Text("Custom Gestures").font(.title3.bold())
                HStack(alignment: .top, spacing: 12) {
                    VStack(alignment: .leading, spacing: 6) {
                        Text("Swipes, finger wiggles, thumbs and grab & fling can each run an action of your choosing: switch desktops, snap windows, press shortcuts, open apps, run commands.")
                            .font(.callout)
                            .foregroundStyle(.secondary)
                            .fixedSize(horizontal: false, vertical: true)
                        Button("Add gestures in Settings…") {
                            SettingsRouter.shared.open(.custom)
                        }
                    }
                }
                .padding(10)
                .frame(maxWidth: .infinity, alignment: .leading)
                .background(RoundedRectangle(cornerRadius: 10).fill(.quaternary.opacity(0.5)))
            }
        } else {
            VStack(alignment: .leading, spacing: 10) {
                section("Custom Gestures", rows: bound.map { binding in
                    Row(symbol: binding.gesture.symbolName,
                        glyph: binding.gesture.glyphName,
                        title: binding.gesture.displayName,
                        detail: "\(binding.gesture.howTo) → \(binding.action?.summary ?? "")")
                })
                if !store.settings.customGestures.enabled {
                    Text("Custom gestures are currently switched off in Settings → Custom.")
                        .font(.caption)
                        .foregroundStyle(.secondary)
                        .fixedSize(horizontal: false, vertical: true)
                }
            }
        }
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
                HStack(alignment: .top, spacing: 12) {
                    icon(for: row)
                        .foregroundStyle(.tint)
                        .frame(width: 44)
                    VStack(alignment: .leading, spacing: 2) {
                        Text(row.title).font(.headline)
                        Text(row.detail)
                            .font(.callout)
                            .foregroundStyle(.secondary)
                            .fixedSize(horizontal: false, vertical: true)
                    }
                }
                .padding(10)
                .background(RoundedRectangle(cornerRadius: 10).fill(.quaternary.opacity(0.5)))
            }
        }
    }

    @ViewBuilder
    private func icon(for row: Row) -> some View {
        if let glyph = row.glyph, let art = GestureArt.image(glyph) {
            Image(nsImage: art)
                .renderingMode(.template)
        } else {
            Image(systemName: row.symbol)
                .font(.title2)
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

/// The posed hands, loaded once each. `PawvisGlyph` hands out fresh images on
/// purpose (callers resize them), but every row here draws at one size, and
/// the guide's body re-runs on each settings change — no reason to re-read
/// the files every time a slider moves.
@MainActor
private enum GestureArt {
    private static let size: CGFloat = 40
    private static var cache: [String: NSImage?] = [:]

    static func image(_ name: String) -> NSImage? {
        if let cached = cache[name] { return cached }
        let image = PawvisGlyph.gesture(name, size: size)
        cache[name] = image
        return image
    }
}
