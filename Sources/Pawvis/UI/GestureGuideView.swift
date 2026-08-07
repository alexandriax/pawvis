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
                section("Voice Dictation", rows: dictationRows)
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
        let clickDetail: (move: String, click: String, letGo: String)
        switch store.settings.gestures.clickGesture {
        case .pinch:
            clickDetail = (
                move: "Move your hand — the claw cursor sits between your thumb and index fingertip.",
                click: "Touch your thumb and index fingertip together briefly.",
                letGo: "separate your fingers")
        case .wholeHandPinch:
            clickDetail = (
                move: "Move your hand — the claw cursor rides your palm.",
                click: "Gather all your fingertips onto your thumb briefly.",
                letGo: "open your hand")
        case .thumbCurl:
            clickDetail = (
                move: "Hold your hand open like a high-five and move it — the claw cursor rides your palm.",
                click: "Tuck your thumb in across your palm.",
                letGo: "swing your thumb back out")
        case .indexTap:
            clickDetail = (
                move: "Hold your hand open, fingers up, and move it — the claw cursor rides your palm.",
                click: "Dip your index finger down, like tapping a mouse button (keep your other fingers up).",
                letGo: "lift your index finger")
        }
        return [
            Row(symbol: "hand.point.up.left.fill",
                title: "Move",
                detail: clickDetail.move + " The ring around the claw tightens as the click gesture forms."),
            Row(symbol: "hand.pinch.fill",
                title: "Click",
                detail: clickDetail.click + " Release quickly for a clean click — small wobbles are ignored. Twice quickly = double-click, three times = triple."),
            Row(symbol: "hand.draw.fill",
                title: "Drag / hold",
                detail: "Hold the click gesture and move — grab a window title bar, select text, drag files. The button stays down until you \(clickDetail.letGo). (Deliberate movement starts the drag right away; otherwise it begins after the click-vs-grab delay.)"),
        ]
    }

    private var dictationRows: [Row] {
        let wakeWords = store.settings.dictation.wakeWords
            .prefix(3).map { "“\($0)”" }.joined(separator: ", ")
        return [
            Row(symbol: "mic.fill",
                title: "Arm dictation from the menu bar",
                detail: "Click the claw in the menu bar and press Start next to Dictation. While armed, start a sentence with \(wakeWords)… — everything after the wake word is typed into the focused app."),
            Row(symbol: "mic.slash.fill",
                title: "Stop typing",
                detail: "Say “\(store.settings.dictation.stopPhrases.first ?? "stop typing")”. You can also say “new line”, “new paragraph”, “press enter”, or “press tab” while dictating."),
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
