import PawvisCore
import SwiftUI

/// A reference card for every gesture, reflecting the user's current
/// configuration (right-click finger, wake words, dictation gesture).
struct GestureGuideView: View {
    @ObservedObject var store: SettingsStore

    var body: some View {
        ScrollView {
            VStack(alignment: .leading, spacing: 18) {
                Text("Gesture Guide")
                    .font(.largeTitle.bold())
                Text("Face the camera with one hand up. The colored dots follow your fingertips; the ring shows your pinch.")
                    .foregroundStyle(.secondary)

                section("Pointing & Clicking", rows: pointingRows)
                section("Modes", rows: modeRows)
                section("Voice Dictation", rows: dictationRows)
            }
            .padding(24)
            .frame(maxWidth: .infinity, alignment: .leading)
        }
        .frame(minWidth: 520, minHeight: 560)
        .tint(PawvisTheme.purpleUI)
    }

    private struct Row {
        let symbol: String
        let title: String
        let detail: String
    }

    private var rightFingerName: String {
        store.settings.gestures.rightClickFinger.rawValue
    }

    private var pointingRows: [Row] {
        [
            Row(symbol: "hand.point.up.left.fill",
                title: "Move the cursor",
                detail: "Point with your index finger — the claw marker is your cursor. When you pinch, the click lands where you were pointing just before your fingers moved, so aiming feels natural. The ring around the claw tightens as thumb and index close, fills while you hold a click, and pulses to confirm each one."),
            Row(symbol: "hand.pinch.fill",
                title: "Left click",
                detail: "Quickly pinch your thumb and index fingertip together, then release. Pinch twice quickly for a double-click, three times for a triple-click."),
            Row(symbol: "hand.pinch",
                title: "Right click",
                detail: "Pinch your thumb and \(rightFingerName) fingertip together, then release."),
            Row(symbol: "hand.draw.fill",
                title: "Drag / hold a button",
                detail: "Pinch and keep holding while you move — grab a window title bar, select text, drag files. The button stays down as long as you hold the pinch. Works with the right-click pinch too."),
        ]
    }

    private var modeRows: [Row] {
        var rows: [Row] = []
        if store.settings.gestures.scrollEnabled {
            rows.append(Row(
                symbol: "hand.point.up.braille.fill",
                title: "Scroll",
                detail: "Extend index + middle fingers together (fold the others), then move your hand up or down. The cursor stays put while content scrolls."))
        }
        if store.settings.gestures.clutchEnabled {
            rows.append(Row(
                symbol: "pause.circle.fill",
                title: "Clutch (park the cursor)",
                detail: "Make a fist to freeze the cursor — like lifting a mouse. Move your hand somewhere comfortable, reopen it, and keep pointing from there."))
        }
        return rows
    }

    private var dictationRows: [Row] {
        let wakeWords = store.settings.dictation.wakeWords
            .prefix(3).map { "“\($0)”" }.joined(separator: ", ")
        var rows: [Row] = []
        if store.settings.gestures.dictationToggle != .off {
            rows.append(Row(
                symbol: dictationSymbol,
                title: "Arm / disarm dictation",
                detail: "\(dictationGestureDetail) An orange pill appears when Pawvis is listening."))
        }
        rows.append(Row(
            symbol: "mic.fill",
            title: "Start typing with a wake word",
            detail: "While listening, start a sentence with \(wakeWords)… — everything after the wake word is typed into the focused app."))
        rows.append(Row(
            symbol: "mic.slash.fill",
            title: "Stop typing",
            detail: "Say “\(store.settings.dictation.stopPhrases.first ?? "stop typing")”. You can also say “new line”, “new paragraph”, “press enter”, or “press tab” while dictating."))
        return rows
    }

    private var dictationSymbol: String {
        switch store.settings.gestures.dictationToggle {
        case .twoHandSplay: return "hands.and.sparkles.fill"
        case .shakaHold: return "hand.wave.fill"
        default: return "hand.raised.fingers.spread.fill"
        }
    }

    private var dictationGestureDetail: String {
        let seconds = String(format: "%.1f", store.settings.gestures.dictationHoldSeconds)
        switch store.settings.gestures.dictationToggle {
        case .oneHandSplayHold:
            return "Splay one hand wide open (fingers spread) and hold it still for \(seconds)s."
        case .twoHandSplay:
            return "Show both hands wide open to the camera for \(seconds)s."
        case .shakaHold:
            return "Make a shaka 🤙 (thumb + pinky out) and hold it for \(seconds)s."
        case .off:
            return ""
        }
    }

    private func section(_ title: String, rows: [Row]) -> some View {
        VStack(alignment: .leading, spacing: 10) {
            Text(title).font(.title3.bold())
            ForEach(rows, id: \.title) { row in
                HStack(alignment: .top, spacing: 12) {
                    Image(systemName: row.symbol)
                        .font(.title2)
                        .foregroundStyle(.tint)
                        .frame(width: 34)
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
}
