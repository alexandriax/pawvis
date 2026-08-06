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
        [
            Row(symbol: "hand.raised.fill",
                title: "Move",
                detail: "Hold your hand open and move it — the claw cursor follows your hand. The ring around it tightens as your hand starts to close."),
            Row(symbol: "hand.raised.fingers.spread.fill",
                title: "Click",
                detail: "Close your hand briefly, like grabbing. The claw retracts and turns purple while your hand is closed. Close twice quickly for a double-click, three times for a triple."),
            Row(symbol: "hand.draw.fill",
                title: "Drag / hold",
                detail: "Close your hand and keep it closed while you move — grab a window title bar, select text, drag files. Open your hand to let go."),
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
