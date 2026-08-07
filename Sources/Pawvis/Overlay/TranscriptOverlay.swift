import AppKit
import Foundation

/// A floating capsule at the top of the screen that shows what voice control
/// is hearing, live — white text on a rounded purple background. Independent
/// of the gesture overlay (which only renders while hand tracking runs).
///
/// Lifecycle: the text updates as an utterance streams in, then auto-hides a
/// configurable few seconds after the utterance completes — or stays until
/// clicked, in manual-dismiss mode. Clicking always dismisses.
@MainActor
final class TranscriptOverlay {
    /// Seconds to keep the text up after an utterance completes.
    var timeout: TimeInterval = 3.0
    /// Keep the text up until it's clicked.
    var manualDismiss = false
    /// Master switch (Settings → Voice).
    var enabled = true

    private var panel: NSPanel?
    private var background: NSView?
    private var label: NSTextField?
    private var hideTimer: Timer?

    /// Include the capsule in screenshots/recordings (mirrors the gesture
    /// overlay's privacy default).
    var showInScreenCapture = false {
        didSet { panel?.sharingType = showInScreenCapture ? .readOnly : .none }
    }

    // MARK: - API

    /// Live utterance text (streaming). Stays up while speech continues.
    func showLive(_ text: String) {
        guard enabled, !text.isEmpty else { return }
        hideTimer?.invalidate()
        hideTimer = nil
        display(text)
    }

    /// The utterance finished: keep the final text up, then auto-hide
    /// (unless manual dismissal is on).
    func complete(_ text: String? = nil) {
        guard enabled else { return }
        if let text, !text.isEmpty {
            display(text)
        }
        guard panel?.isVisible == true else { return }
        scheduleHide(after: timeout)
    }

    /// A transient status message ("→ reddit.com", "⚠️ …") using the same
    /// capsule; auto-hides even in manual mode (it's feedback, not a record).
    func flash(_ text: String) {
        guard enabled, !text.isEmpty else { return }
        display(text)
        hideTimer?.invalidate()
        hideTimer = Timer.scheduledTimer(withTimeInterval: max(2.0, timeout), repeats: false) { [weak self] _ in
            Task { @MainActor in self?.hide() }
        }
    }

    func hide() {
        hideTimer?.invalidate()
        hideTimer = nil
        guard let panel, panel.isVisible else { return }
        NSAnimationContext.runAnimationGroup({ context in
            context.duration = 0.18
            panel.animator().alphaValue = 0
        }, completionHandler: {
            Task { @MainActor [weak self] in
                self?.panel?.orderOut(nil)
            }
        })
    }

    // MARK: - Internals

    private func scheduleHide(after delay: TimeInterval) {
        hideTimer?.invalidate()
        hideTimer = nil
        guard !manualDismiss else { return }
        hideTimer = Timer.scheduledTimer(withTimeInterval: delay, repeats: false) { [weak self] _ in
            Task { @MainActor in self?.hide() }
        }
    }

    private func display(_ text: String) {
        let panel = ensurePanel()
        guard let label, let background else { return }
        label.stringValue = text
        layout(panel: panel, label: label, background: background)
        panel.alphaValue = 1
        if !panel.isVisible {
            panel.orderFrontRegardless()
        }
    }

    private func ensurePanel() -> NSPanel {
        if let panel { return panel }

        let panel = NSPanel(
            contentRect: NSRect(x: 0, y: 0, width: 400, height: 44),
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
        // Receives clicks (dismissal) but never steals focus (.nonactivating).
        panel.ignoresMouseEvents = false

        let background = NSView()
        background.wantsLayer = true
        background.layer?.backgroundColor = PawvisTheme.purple.withAlphaComponent(0.94).cgColor
        background.layer?.cornerRadius = 12

        let label = NSTextField(labelWithString: "")
        label.font = .systemFont(ofSize: 15, weight: .medium)
        label.textColor = .white
        label.alignment = .center
        label.lineBreakMode = .byWordWrapping
        label.maximumNumberOfLines = 3
        background.addSubview(label)

        let click = NSClickGestureRecognizer(target: self, action: #selector(clicked))
        background.addGestureRecognizer(click)

        panel.contentView = background
        self.panel = panel
        self.background = background
        self.label = label
        return panel
    }

    @objc private func clicked() {
        hide()
    }

    /// Size the capsule to its text and pin it top-center of the main screen,
    /// just below the menu bar.
    private func layout(panel: NSPanel, label: NSTextField, background: NSView) {
        guard let screen = NSScreen.main ?? NSScreen.screens.first else { return }
        let maxTextWidth = min(680, screen.visibleFrame.width * 0.7)
        let textSize = label.cell?.cellSize(
            forBounds: NSRect(x: 0, y: 0, width: maxTextWidth, height: 200))
            ?? NSSize(width: 200, height: 20)

        let hPad: CGFloat = 18, vPad: CGFloat = 10
        let width = ceil(textSize.width) + hPad * 2
        let height = ceil(textSize.height) + vPad * 2
        label.frame = NSRect(x: hPad, y: vPad, width: ceil(textSize.width), height: ceil(textSize.height))

        let x = screen.visibleFrame.midX - width / 2
        let y = screen.visibleFrame.maxY - height - 10
        panel.setFrame(NSRect(x: x, y: y, width: width, height: height), display: true)
        background.frame = NSRect(x: 0, y: 0, width: width, height: height)
    }
}
