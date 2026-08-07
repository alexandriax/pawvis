import AppKit
import Combine
import SwiftUI

/// The bottom-right activity panel that appears whenever an agent CLI run is
/// in flight: one card per session with the live output tail and a Cancel
/// button, staying up briefly to show the outcome. Mirrors CapsulePanel's
/// window discipline — borderless, `.nonactivating` (clicking Cancel never
/// steals focus from what the user is doing), status-bar level, on every
/// Space, excluded from screen capture by default.
@MainActor
final class AgentActivityOverlay {
    var showInScreenCapture = false {
        didSet { panel?.sharingType = showInScreenCapture ? .readOnly : .none }
    }

    private var panel: NSPanel?
    private var hosting: FirstMouseHostingView<AgentActivityList>?
    private var subscription: AnyCancellable?

    func bind(to manager: AgentSessionManager) {
        subscription = manager.$sessions
            .receive(on: DispatchQueue.main)
            .sink { [weak self, weak manager] sessions in
                guard let manager else { return }
                self?.render(manager: manager, hasSessions: !sessions.isEmpty)
            }
    }

    private func render(manager: AgentSessionManager, hasSessions: Bool) {
        guard hasSessions else {
            panel?.orderOut(nil)
            return
        }
        let panel = ensurePanel(manager: manager)
        layout(panel)
        if !panel.isVisible {
            panel.orderFrontRegardless()
        }
    }

    private func ensurePanel(manager: AgentSessionManager) -> NSPanel {
        if let panel { return panel }

        let panel = NSPanel(
            contentRect: NSRect(x: 0, y: 0, width: Self.width, height: 120),
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

        let hosting = FirstMouseHostingView(
            rootView: AgentActivityList(manager: manager))
        panel.contentView = hosting
        self.panel = panel
        self.hosting = hosting
        return panel
    }

    private static let width: CGFloat = 380
    private static let margin: CGFloat = 16

    /// Pin the panel to the bottom-right of the main screen, sized to fit.
    private func layout(_ panel: NSPanel) {
        guard let hosting, let screen = NSScreen.main ?? NSScreen.screens.first else { return }
        let height = hosting.fittingSize.height
        let frame = NSRect(
            x: screen.visibleFrame.maxX - Self.width - Self.margin,
            y: screen.visibleFrame.minY + Self.margin,
            width: Self.width,
            height: height)
        panel.setFrame(frame, display: true)
        hosting.frame = NSRect(x: 0, y: 0, width: Self.width, height: height)
    }
}

/// SwiftUI hosting view that accepts the first click. The panel belongs to an
/// app that is never frontmost, so without this the Cancel button would need
/// one click to "focus" and another to act (same lesson as CapsulePanel).
private final class FirstMouseHostingView<Content: View>: NSHostingView<Content> {
    override func acceptsFirstMouse(for event: NSEvent?) -> Bool { true }
}

// MARK: - Cards

private struct AgentActivityList: View {
    @ObservedObject var manager: AgentSessionManager

    var body: some View {
        VStack(alignment: .leading, spacing: 8) {
            ForEach(manager.sessions) { session in
                AgentSessionCard(session: session) {
                    manager.cancel(session.id)
                }
            }
        }
        .padding(.vertical, 2)
    }
}

struct AgentSessionCard: View {
    let session: AgentSessionSnapshot
    var onCancel: () -> Void

    var body: some View {
        VStack(alignment: .leading, spacing: 6) {
            HStack(alignment: .firstTextBaseline, spacing: 8) {
                phaseIndicator
                Text(session.tool.displayName)
                    .font(.system(size: 12, weight: .semibold))
                if session.phase.isRunning {
                    ElapsedText(since: session.startedAt)
                }
                Spacer(minLength: 8)
                if session.phase.isRunning {
                    Button("Cancel", action: onCancel)
                        .buttonStyle(.bordered)
                        .controlSize(.small)
                        .help("Kill this \(session.tool.displayName) run")
                }
            }
            Text("“\(session.instruction)”")
                .font(.system(size: 11))
                .foregroundStyle(.secondary)
                .lineLimit(2)

            switch session.phase {
            case .running:
                if session.tail.isEmpty {
                    Text("Starting…")
                        .font(.system(size: 10, design: .monospaced))
                        .foregroundStyle(.tertiary)
                } else {
                    VStack(alignment: .leading, spacing: 2) {
                        ForEach(Array(session.tail.suffix(5).enumerated()), id: \.offset) { _, line in
                            Text(line)
                                .font(.system(size: 10, design: .monospaced))
                                .foregroundStyle(.tertiary)
                                .lineLimit(1)
                        }
                    }
                }
            case .finished(_, let message):
                Text(message)
                    .font(.system(size: 11, weight: .medium))
                    .lineLimit(2)
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
    private var phaseIndicator: some View {
        switch session.phase {
        case .running:
            ProgressView()
                .controlSize(.small)
                .scaleEffect(0.6)
                .frame(width: 12, height: 12)
        case .finished(let success, _):
            Text(success ? "✅" : "⚠️")
                .font(.system(size: 11))
        }
    }
}

/// "0:07"-style live elapsed time, ticking once a second.
struct ElapsedText: View {
    let since: Date

    var body: some View {
        TimelineView(.periodic(from: .now, by: 1)) { context in
            let seconds = max(0, Int(context.date.timeIntervalSince(since)))
            Text(String(format: "%d:%02d", seconds / 60, seconds % 60))
                .font(.system(size: 11, design: .monospaced))
                .foregroundStyle(.secondary)
        }
    }
}
