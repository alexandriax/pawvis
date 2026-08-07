import AppKit

/// A floating rounded capsule near the top of the main screen — the shape
/// shared by the live transcript and the status notices.
///
/// Everything shown in one is dismissible: an ✕ sits at the trailing edge, and
/// a click anywhere on the capsule hides it and calls `onDismiss` (the owner
/// needs to know, or a capsule driven by a per-frame render loop would be back
/// before the mouse button came up).
///
/// The panel is `.nonactivating`, so dismissing never pulls focus out of
/// whatever the user is working in, and it lives outside the gesture overlay:
/// that window is click-through by design, and a click-through window cannot
/// offer a close button.
@MainActor
final class CapsulePanel {
    /// Called when the user clicks the capsule (or its ✕).
    var onDismiss: (() -> Void)?

    /// Include the capsule in screenshots/recordings (mirrors the gesture
    /// overlay's privacy default).
    var showInScreenCapture = false {
        didSet { panel?.sharingType = showInScreenCapture ? .readOnly : .none }
    }

    var isVisible: Bool { panel?.isVisible == true }

    private let font: NSFont
    /// Points below the top of the screen's visible frame.
    private let topInset: CGFloat
    private let maxLines: Int

    private var panel: NSPanel?
    private var background: NSView?
    private var label: NSTextField?
    private var closeGlyph: NSTextField?

    private var shownText: String?
    private var shownColor: NSColor?
    /// Bumped by every show/hide so a fade that's already running can tell it
    /// has been superseded and must not order out the new content.
    private var hideGeneration = 0
    private var fading = false

    init(font: NSFont, topInset: CGFloat, maxLines: Int = 3) {
        self.font = font
        self.topInset = topInset
        self.maxLines = maxLines
    }

    // MARK: - API

    /// Show `text` (idempotent: re-showing what's already up costs nothing, so
    /// a caller may drive this from a render loop).
    func show(_ text: String, background color: NSColor) {
        guard !text.isEmpty else { return hide() }
        let panel = ensurePanel()
        guard let label, let background, let closeGlyph else { return }

        if isVisible, text == shownText, color == shownColor { return }
        shownText = text
        shownColor = color

        label.stringValue = text
        background.layer?.backgroundColor = color.cgColor
        layout(panel: panel, label: label, background: background, closeGlyph: closeGlyph)

        hideGeneration &+= 1
        if fading {
            // Cancel the in-flight fade rather than fighting it.
            NSAnimationContext.runAnimationGroup { context in
                context.duration = 0
                panel.animator().alphaValue = 1
            }
            fading = false
        } else {
            panel.alphaValue = 1
        }
        if !panel.isVisible {
            panel.orderFrontRegardless()
        }
    }

    func hide() {
        shownText = nil
        shownColor = nil
        // `!fading` matters: callers hide from a render loop, and restarting the
        // fade thirty times a second means it never reaches its completion —
        // the capsule hangs on screen forever, which is the whole bug here.
        guard let panel, panel.isVisible, !fading else { return }
        hideGeneration &+= 1
        let generation = hideGeneration
        fading = true
        NSAnimationContext.runAnimationGroup({ context in
            context.duration = 0.18
            panel.animator().alphaValue = 0
        }, completionHandler: {
            Task { @MainActor [weak self] in
                guard let self, self.hideGeneration == generation else { return }
                self.fading = false
                self.panel?.orderOut(nil)
            }
        })
    }

    // MARK: - Internals

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

        let background = CapsuleBackgroundView()
        background.wantsLayer = true
        background.layer?.cornerRadius = 12
        background.onClick = { [weak self] in self?.clicked() }

        let label = NSTextField(labelWithString: "")
        label.font = font
        label.textColor = .white
        label.alignment = .center
        label.lineBreakMode = .byWordWrapping
        label.maximumNumberOfLines = maxLines
        background.addSubview(label)

        // The dismiss affordance is a label, not a control: the whole capsule
        // is the click target, so a 14-point ✕ never has to be hit precisely.
        let closeGlyph = NSTextField(labelWithString: "✕")
        closeGlyph.font = .systemFont(ofSize: 12, weight: .bold)
        closeGlyph.textColor = NSColor.white.withAlphaComponent(0.85)
        closeGlyph.alignment = .center
        closeGlyph.toolTip = "Dismiss"
        background.addSubview(closeGlyph)

        panel.contentView = background
        self.panel = panel
        self.background = background
        self.label = label
        self.closeGlyph = closeGlyph
        return panel
    }

    private func clicked() {
        hide()
        onDismiss?()
    }

    /// Size the capsule to its text (plus room for the ✕) and pin it
    /// top-center of the main screen.
    private func layout(
        panel: NSPanel, label: NSTextField, background: NSView, closeGlyph: NSTextField
    ) {
        guard let screen = NSScreen.main ?? NSScreen.screens.first else { return }
        let hPad: CGFloat = 18, vPad: CGFloat = 10
        let closeWidth: CGFloat = 14, closeGap: CGFloat = 10, closePad: CGFloat = 12

        let maxTextWidth = min(680, screen.visibleFrame.width * 0.7) - closeGap - closeWidth - closePad
        let textSize = label.cell?.cellSize(
            forBounds: NSRect(x: 0, y: 0, width: maxTextWidth, height: 200))
            ?? NSSize(width: 200, height: 20)
        let textWidth = ceil(min(textSize.width, maxTextWidth))
        let textHeight = ceil(textSize.height)

        let width = hPad + textWidth + closeGap + closeWidth + closePad
        let height = max(34, textHeight + vPad * 2)
        label.frame = NSRect(
            x: hPad, y: (height - textHeight) / 2, width: textWidth, height: textHeight)
        closeGlyph.frame = NSRect(
            x: width - closePad - closeWidth, y: (height - 16) / 2, width: closeWidth, height: 16)

        let x = screen.visibleFrame.midX - width / 2
        let y = screen.visibleFrame.maxY - height - topInset
        panel.setFrame(NSRect(x: x, y: y, width: width, height: height), display: true)
        background.frame = NSRect(x: 0, y: 0, width: width, height: height)
    }
}

/// The capsule's click target.
///
/// `mouseDown` rather than an `NSClickGestureRecognizer`: the capsule lives in
/// a borderless, non-key panel, where the recognizer never fires — the ✕ looked
/// like a button and did nothing. `acceptsFirstMouse` is what lets the click
/// land at all, since the panel belongs to an app that is never frontmost.
private final class CapsuleBackgroundView: NSView {
    var onClick: (() -> Void)?

    override func acceptsFirstMouse(for event: NSEvent?) -> Bool { true }

    override func mouseDown(with event: NSEvent) {
        onClick?()
    }
}
