import PawvisCore
import SwiftUI

/// A reference card for the (deliberately small) gesture set.
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
                section("Voice Control", rows: voiceRows)
            }
            .padding(24)
            .frame(maxWidth: .infinity, alignment: .leading)
        }
        .frame(minWidth: 520, minHeight: 480)
        .tint(PawvisTheme.purpleUI)
    }

    private struct Row {
        let symbol: String
        let title: String
        let detail: String
    }

    private var pointingRows: [Row] {
        var rows: [Row] = []
        if store.settings.gestures.controlTrigger == .openHand {
            rows.append(Row(
                symbol: "hand.raised.fill",
                title: "Take control",
                detail: "Show the camera an open hand — all four fingers up — and the claw brightens: you have the cursor. Pawvis keeps watching while you type or rest, but the cursor stays parked until you show the trigger. Make a brief fist to park it again."))
        }
        rows += [
            Row(symbol: "hand.point.up.left.fill",
                title: "Move",
                detail: "Hold your hand open, fingers up, and move it — the claw cursor rides your palm. The ring around the claw tightens as the click gesture forms."),
            Row(symbol: "hand.pinch.fill",
                title: "Click",
                detail: "Dip your index finger down, like tapping a mouse button (keep your other fingers up). Release quickly for a clean click — small wobbles are ignored. Twice quickly = double-click, three times = triple."),
            Row(symbol: "hand.draw.fill",
                title: "Drag / hold",
                detail: "Hold the click gesture and move — grab a window title bar, select text, drag files. The button stays down until you lift your index finger. (Deliberate movement starts the drag right away; otherwise it begins after the click-vs-grab delay.)"),
        ]

        if store.settings.gestures.rightClickEnabled {
            let fingerName = store.settings.gestures.rightClickFinger == .little
                ? "pinky" : store.settings.gestures.rightClickFinger.rawValue
            rows.append(Row(
                symbol: "hand.point.right.fill",
                title: "Right-click",
                detail: "Dip your \(fingerName) finger the same way — the claw turns blue while it's down. Hold it to right-drag."))
        }

        if store.settings.gestures.scrollEnabled {
            let direction = store.settings.gestures.scrollInvert
                ? "Move your hand up to scroll down and down to scroll up (you inverted the direction in Settings)."
                : "Move your hand up to scroll up and down to scroll down."
            rows.append(Row(
                symbol: "arrow.up.arrow.down.circle.fill",
                title: "Scroll",
                detail: "Fold your middle and ring fingers in — index and pinky stay up. \(direction) The cursor parks (with a light-blue ring) while the pose is held; relax your hand to let go."))
        }
        return rows
    }

    private var voiceRows: [Row] {
        let wake = store.settings.voiceControl.wakeWord
        return [
            Row(symbol: "mic.fill",
                title: "Start voice control from the menu bar",
                detail: "Click the claw in the menu bar and press Start next to Voice control. Address it by name: “\(wake) go to github.com”, “\(wake) open Safari”, “\(wake) switch to Notes”, “\(wake) press command T”, “\(wake) scroll down”."),
            Row(symbol: "keyboard.fill",
                title: "Type by voice",
                detail: "Say “\(wake) type …” and keep talking — everything is typed into the focused app. A pause (or “\(store.settings.voiceControl.stopPhrases.first ?? "stop typing")”) ends typing. While typing you can say “new line” or “press enter”."),
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
