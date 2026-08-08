import AppKit
import SwiftUI

/// The bottom-right card that appears while the voice autopilot works
/// through a multi-step command: the goal, a live elapsed clock, the last
/// few completed steps, and a Cancel button. Mirrors AgentActivityOverlay's
/// window discipline — borderless, `.nonactivating` (Cancel never steals
/// focus from the app being driven), status-bar level, on every Space,
/// excluded from screen capture by default. The two panels share a screen
/// corner but never an era: the agent panel exists only in agent mode, this
/// one only on the on-device path.
@MainActor
final class AutopilotPanel {
    var showInScreenCapture = false {
        didSet { panel?.sharingType = showInScreenCapture ? .readOnly : .none }
    }

    /// How long the finished card lingers so the outcome is seen.
    private static let lingerSeconds: TimeInterval = 4
    private static let width: CGFloat = 380
    private static let margin: CGFloat = 16
    /// Steps shown at once; older ones scroll off.
    private static let visibleLines = 4

    private final class Model: ObservableObject {
        @Published var goal = ""
        @Published var startedAt = Date()
        @Published var lines: [String] = []
        @Published var finished: Bool? // nil = running; else success
        var onCancel: () -> Void = {}
    }

    private let model = Model()
    private var panel: NSPanel?
    private var hosting: AutopilotHostingView<AutopilotCard>?
    private var lingerTimer: Timer?

    func begin(goal: String, onCancel: @escaping () -> Void) {
        lingerTimer?.invalidate()
        lingerTimer = nil
        model.goal = goal
        model.startedAt = Date()
        model.lines = []
        model.finished = nil
        model.onCancel = onCancel
        present()
    }

    func append(line: String) {
        model.lines.append(line)
        if model.lines.count > Self.visibleLines {
            model.lines.removeFirst(model.lines.count - Self.visibleLines)
        }
        relayout()
    }

    /// Marks the run over and lets the card linger briefly with the outcome.
    func finish(success: Bool) {
        model.finished = success
        relayout()
        lingerTimer?.invalidate()
        lingerTimer = Timer.scheduledTimer(
            withTimeInterval: Self.lingerSeconds, repeats: false
        ) { [weak self] _ in
            Task { @MainActor in self?.hide() }
        }
    }

    func hide() {
        lingerTimer?.invalidate()
        lingerTimer = nil
        panel?.orderOut(nil)
    }

    // MARK: - Panel

    private func present() {
        let panel = ensurePanel()
        relayout()
        if !panel.isVisible {
            panel.orderFrontRegardless()
        }
    }

    private func ensurePanel() -> NSPanel {
        if let panel { return panel }

        let panel = NSPanel(
            contentRect: NSRect(x: 0, y: 0, width: Self.width, height: 100),
            styleMask: [.borderless, .nonactivatingPanel],
            backing: .buffered,
            defer: false)
        panel.level = .statusBar
        panel.isOpaque = false
        panel.backgroundColor = .clear
        panel.hasShadow = true
        panel.hidesOnDeactivate = false
        panel.isMovable = false
        panel.collectionBehavior = [.canJoinAllSpaces, .fullScreenAuxiliary]
        panel.sharingType = showInScreenCapture ? .readOnly : .none
        panel.becomesKeyOnlyIfNeeded = true

        let hosting = AutopilotHostingView(rootView: AutopilotCard(model: model))
        panel.contentView = hosting
        self.panel = panel
        self.hosting = hosting
        return panel
    }

    /// Pin to the bottom-right of the main screen, sized to fit.
    private func relayout() {
        guard let panel, let hosting,
              let screen = NSScreen.main ?? NSScreen.screens.first else { return }
        let height = hosting.fittingSize.height
        let frame = NSRect(
            x: screen.visibleFrame.maxX - Self.width - Self.margin,
            y: screen.visibleFrame.minY + Self.margin,
            width: Self.width,
            height: height)
        panel.setFrame(frame, display: true)
        hosting.frame = NSRect(x: 0, y: 0, width: Self.width, height: height)
    }

    // MARK: - Card

    private struct AutopilotCard: View {
        @ObservedObject var model: Model

        var body: some View {
            VStack(alignment: .leading, spacing: 6) {
                HStack(alignment: .firstTextBaseline, spacing: 8) {
                    indicator
                    Text("Autopilot")
                        .font(.system(size: 12, weight: .semibold))
                    if model.finished == nil {
                        ElapsedText(since: model.startedAt)
                    }
                    Spacer(minLength: 8)
                    if model.finished == nil {
                        Button("Cancel") { model.onCancel() }
                            .buttonStyle(.bordered)
                            .controlSize(.small)
                            .help("Stop working on this command")
                    }
                }
                Text("“\(model.goal)”")
                    .font(.system(size: 11))
                    .foregroundStyle(.secondary)
                    .lineLimit(2)

                if model.lines.isEmpty, model.finished == nil {
                    Text("Looking at the screen…")
                        .font(.system(size: 10, design: .monospaced))
                        .foregroundStyle(.tertiary)
                } else if !model.lines.isEmpty {
                    VStack(alignment: .leading, spacing: 2) {
                        ForEach(Array(model.lines.enumerated()), id: \.offset) { _, line in
                            Text(line)
                                .font(.system(size: 10, design: .monospaced))
                                .foregroundStyle(.tertiary)
                                .lineLimit(1)
                        }
                    }
                }
            }
            .padding(10)
            .frame(width: 360, alignment: .leading)
            .background(
                RoundedRectangle(cornerRadius: 10)
                    .fill(Color(nsColor: PawvisTheme.purple).opacity(0.94)))
            .colorScheme(.dark)
        }

        @ViewBuilder
        private var indicator: some View {
            switch model.finished {
            case nil:
                ProgressView()
                    .controlSize(.small)
                    .scaleEffect(0.6)
                    .frame(width: 12, height: 12)
            case true?:
                Text("✅").font(.system(size: 11))
            case false?:
                Text("⚠️").font(.system(size: 11))
            }
        }
    }
}

/// SwiftUI hosting view that accepts the first click, so Cancel works
/// without a focusing click first (same lesson as the other panels).
private final class AutopilotHostingView<Content: View>: NSHostingView<Content> {
    override func acceptsFirstMouse(for event: NSEvent?) -> Bool { true }
}
