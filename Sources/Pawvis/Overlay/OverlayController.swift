import AppKit
import PawvisCore
import QuartzCore

/// What the dictation HUD (status pill) should show.
enum DictationHUD: Equatable {
    case hidden
    case connecting
    case listening            // armed, waiting for a wake word
    case dictating(String)    // typing; associated value = latest transcript snippet
    case error(String)
}

/// Owns one click-through overlay window per screen and renders the gesture
/// engine's overlay state: fingertip dots, the contracting pinch iris,
/// cursor halo, mode glyphs, dictation hold progress, and the status pill.
@MainActor
final class OverlayController {
    private var windows: [OverlayWindow] = []
    private var config = OverlayConfig()
    private var visible = false

    init() {
        rebuildWindows()
        NotificationCenter.default.addObserver(
            forName: NSApplication.didChangeScreenParametersNotification,
            object: nil, queue: .main
        ) { [weak self] _ in
            Task { @MainActor in self?.rebuildWindows() }
        }
    }

    func setConfig(_ config: OverlayConfig) {
        self.config = config
    }

    func show() {
        visible = true
        windows.forEach { $0.orderFrontRegardless() }
    }

    func hide() {
        visible = false
        windows.forEach { window in
            window.contentOverlayView.clear()
            window.orderOut(nil)
        }
    }

    private func rebuildWindows() {
        let wasVisible = visible
        windows.forEach { $0.orderOut(nil) }
        windows = NSScreen.screens.map { OverlayWindow(screen: $0) }
        if wasVisible { show() }
    }

    func render(overlay: OverlayState, dictation: DictationHUD, projector: ScreenProjector) {
        guard visible else { return }
        for window in windows {
            var model = OverlayRenderModel()
            let bounds = window.displayBoundsCG

            func localize(_ norm: Vec2) -> CGPoint? {
                let global = projector.toGlobal(norm)
                // Draw a little past the edge so dots slide off naturally.
                guard bounds.insetBy(dx: -80, dy: -80).contains(global) else { return nil }
                return CGPoint(x: global.x - bounds.minX, y: global.y - bounds.minY)
            }

            if config.showFingertipDots {
                for hand in overlay.hands {
                    let handAlpha: CGFloat = hand.isPrimary ? 1.0 : 0.55
                    for (joint, point) in hand.fingertips {
                        guard let local = localize(point) else { continue }
                        let (radius, color) = Self.dotStyle(for: joint)
                        model.dots.append(.init(
                            center: local,
                            radius: radius * config.dotScale,
                            color: color,
                            alpha: handAlpha))
                    }
                }
            }

            if config.showPinchRing, let primary = overlay.hands.first(where: { $0.isPrimary }) {
                // The sporecaster "pinch iris": visible from strength 0.15, ring
                // contracts and saturates as the pinch approaches the threshold.
                if primary.leftPinchStrength > 0.15, let p = primary.leftPinchPoint, let local = localize(p) {
                    model.rings.append(Self.iris(
                        at: local, strength: primary.leftPinchStrength,
                        engaged: overlay.leftEngaged, dragging: overlay.isDragging,
                        tint: PawvisTheme.purple))
                }
                if primary.rightPinchStrength > 0.15, let p = primary.rightPinchPoint, let local = localize(p) {
                    model.rings.append(Self.iris(
                        at: local, strength: primary.rightPinchStrength,
                        engaged: overlay.rightEngaged, dragging: overlay.isDragging,
                        tint: PawvisTheme.blue))
                }
            }

            if config.showCursorHalo, let cursor = overlay.cursor, let local = localize(cursor) {
                let tint: NSColor = overlay.leftEngaged ? PawvisTheme.purple
                    : overlay.rightEngaged ? PawvisTheme.blue : .white
                model.rings.append(.init(
                    center: local,
                    radius: overlay.isDragging ? 18 : 13,
                    lineWidth: overlay.isDragging ? 4 : 2.5,
                    strokeColor: tint,
                    fillColor: (overlay.leftEngaged || overlay.rightEngaged)
                        ? tint.withAlphaComponent(0.35) : nil,
                    alpha: 0.9))

                switch overlay.mode {
                case .scrolling:
                    model.glyphs.append(.init(center: local.offset(dx: 0, dy: -34), text: "⇅", size: 20))
                case .clutch:
                    model.glyphs.append(.init(center: local.offset(dx: 0, dy: -34), text: "✊", size: 18))
                default:
                    break
                }

                if let progress = overlay.dictationHoldProgress {
                    model.arcs.append(.init(center: local, radius: 26, progress: progress))
                }
            }

            if config.showStatusPill, window.isOnMainScreen {
                model.pill = Self.pill(for: dictation)
            }

            window.contentOverlayView.render(model)
        }
    }

    // MARK: - Styling

    private static func dotStyle(for joint: HandJoint) -> (CGFloat, NSColor) {
        switch joint {
        case .indexTip: return (7, PawvisTheme.purpleLight)
        case .thumbTip: return (7, PawvisTheme.blueLight)
        default: return (4.5, NSColor.white.withAlphaComponent(0.6))
        }
    }

    private static func iris(
        at point: CGPoint, strength: Double, engaged: Bool, dragging: Bool, tint: NSColor
    ) -> OverlayRenderModel.Ring {
        if engaged {
            return .init(
                center: point, radius: dragging ? 16 : 12, lineWidth: 3,
                strokeColor: tint, fillColor: tint.withAlphaComponent(0.5), alpha: 1)
        }
        let radius = 30 - 18 * strength // contracts as the pinch closes
        let color = NSColor.white.blended(withFraction: strength, of: tint) ?? tint
        return .init(
            center: point, radius: radius, lineWidth: 3,
            strokeColor: color, fillColor: nil, alpha: 0.35 + 0.6 * strength)
    }

    private static func pill(for dictation: DictationHUD) -> OverlayRenderModel.Pill? {
        switch dictation {
        case .hidden:
            return nil
        case .connecting:
            return .init(text: "🎤 Connecting…", background: NSColor.systemGray.withAlphaComponent(0.85))
        case .listening:
            return .init(text: "🎤 Say a wake word (“type…”) to dictate",
                         background: PawvisTheme.blue.withAlphaComponent(0.88))
        case .dictating(let snippet):
            let text = snippet.isEmpty ? "⌨️ Dictating — say “stop typing” to end"
                : "⌨️ \(snippet)"
            return .init(text: text, background: PawvisTheme.purple.withAlphaComponent(0.9))
        case .error(let message):
            return .init(text: "⚠️ \(message)", background: NSColor.systemRed.withAlphaComponent(0.9))
        }
    }
}

private extension CGPoint {
    func offset(dx: CGFloat, dy: CGFloat) -> CGPoint {
        CGPoint(x: x + dx, y: y + dy)
    }
}

// MARK: - Render model

struct OverlayRenderModel {
    struct Dot {
        var center: CGPoint
        var radius: CGFloat
        var color: NSColor
        var alpha: CGFloat
    }

    struct Ring {
        var center: CGPoint
        var radius: CGFloat
        var lineWidth: CGFloat
        var strokeColor: NSColor
        var fillColor: NSColor?
        var alpha: CGFloat
    }

    struct Arc {
        var center: CGPoint
        var radius: CGFloat
        var progress: Double
    }

    struct Glyph {
        var center: CGPoint
        var text: String
        var size: CGFloat
    }

    struct Pill: Equatable {
        var text: String
        var background: NSColor
    }

    var dots: [Dot] = []
    var rings: [Ring] = []
    var arcs: [Arc] = []
    var glyphs: [Glyph] = []
    var pill: Pill?
}

// MARK: - Window

final class OverlayWindow: NSWindow {
    let contentOverlayView = OverlayContentView()
    let displayBoundsCG: CGRect
    let isOnMainScreen: Bool

    init(screen: NSScreen) {
        let displayID = (screen.deviceDescription[
            NSDeviceDescriptionKey("NSScreenNumber")] as? NSNumber)
            .map { CGDirectDisplayID($0.uint32Value) } ?? CGMainDisplayID()
        displayBoundsCG = CGDisplayBounds(displayID)
        isOnMainScreen = displayID == CGMainDisplayID()

        super.init(
            contentRect: screen.frame,
            styleMask: .borderless,
            backing: .buffered,
            defer: false)

        level = .screenSaver
        isOpaque = false
        backgroundColor = .clear
        hasShadow = false
        ignoresMouseEvents = true
        isReleasedWhenClosed = false
        collectionBehavior = [.canJoinAllSpaces, .stationary, .fullScreenAuxiliary, .ignoresCycle]
        // Keep the overlay out of screenshots and screen recordings.
        sharingType = .none
        contentView = contentOverlayView
    }
}

// MARK: - View (layer pools, updated per frame without implicit animation)

final class OverlayContentView: NSView {
    override var isFlipped: Bool { true } // top-left origin, matching CG space

    private var dotLayers: [CAShapeLayer] = []
    private var ringLayers: [CAShapeLayer] = []
    private var arcLayers: [CAShapeLayer] = []
    private var glyphLayers: [CATextLayer] = []
    private let pillBackground = CALayer()
    private let pillText = CATextLayer()

    init() {
        super.init(frame: .zero)
        wantsLayer = true
        layerContentsRedrawPolicy = .never

        pillBackground.cornerRadius = 14
        pillBackground.isHidden = true
        pillText.fontSize = 13
        pillText.font = NSFont.systemFont(ofSize: 13, weight: .semibold)
        pillText.foregroundColor = NSColor.white.cgColor
        pillText.alignmentMode = .center
        pillText.contentsScale = 2
        pillBackground.addSublayer(pillText)
    }

    @available(*, unavailable)
    required init?(coder: NSCoder) { fatalError("unused") }

    func clear() {
        render(OverlayRenderModel())
    }

    func render(_ model: OverlayRenderModel) {
        CATransaction.begin()
        CATransaction.setDisableActions(true)
        defer { CATransaction.commit() }

        renderDots(model.dots)
        renderRings(model.rings)
        renderArcs(model.arcs)
        renderGlyphs(model.glyphs)
        renderPill(model.pill)
    }

    private func pooled<L: CALayer>(_ pool: inout [L], count: Int, make: () -> L) {
        while pool.count < count {
            let l = make()
            layer?.addSublayer(l)
            pool.append(l)
        }
        for (i, l) in pool.enumerated() {
            l.isHidden = i >= count
        }
    }

    private func renderDots(_ dots: [OverlayRenderModel.Dot]) {
        pooled(&dotLayers, count: dots.count) { CAShapeLayer() }
        for (i, dot) in dots.enumerated() {
            let l = dotLayers[i]
            l.path = CGPath(
                ellipseIn: CGRect(
                    x: dot.center.x - dot.radius, y: dot.center.y - dot.radius,
                    width: dot.radius * 2, height: dot.radius * 2),
                transform: nil)
            l.fillColor = dot.color.cgColor
            l.opacity = Float(dot.alpha)
            l.strokeColor = NSColor.black.withAlphaComponent(0.35).cgColor
            l.lineWidth = 1
        }
    }

    private func renderRings(_ rings: [OverlayRenderModel.Ring]) {
        pooled(&ringLayers, count: rings.count) { CAShapeLayer() }
        for (i, ring) in rings.enumerated() {
            let l = ringLayers[i]
            l.path = CGPath(
                ellipseIn: CGRect(
                    x: ring.center.x - ring.radius, y: ring.center.y - ring.radius,
                    width: ring.radius * 2, height: ring.radius * 2),
                transform: nil)
            l.strokeColor = ring.strokeColor.cgColor
            l.fillColor = ring.fillColor?.cgColor ?? NSColor.clear.cgColor
            l.lineWidth = ring.lineWidth
            l.opacity = Float(ring.alpha)
        }
    }

    private func renderArcs(_ arcs: [OverlayRenderModel.Arc]) {
        pooled(&arcLayers, count: arcs.count) { CAShapeLayer() }
        for (i, arc) in arcs.enumerated() {
            let l = arcLayers[i]
            let path = CGMutablePath()
            path.addArc(
                center: arc.center, radius: arc.radius,
                startAngle: -.pi / 2, endAngle: -.pi / 2 + 2 * .pi * arc.progress,
                clockwise: false)
            l.path = path
            l.strokeColor = PawvisTheme.purple.cgColor
            l.fillColor = NSColor.clear.cgColor
            l.lineWidth = 4
            l.lineCap = .round
            l.opacity = 0.95
        }
    }

    private func renderGlyphs(_ glyphs: [OverlayRenderModel.Glyph]) {
        pooled(&glyphLayers, count: glyphs.count) {
            let t = CATextLayer()
            t.alignmentMode = .center
            t.contentsScale = 2
            return t
        }
        for (i, glyph) in glyphs.enumerated() {
            let l = glyphLayers[i]
            l.string = glyph.text
            l.fontSize = glyph.size
            l.foregroundColor = NSColor.white.cgColor
            l.frame = CGRect(
                x: glyph.center.x - 20, y: glyph.center.y - glyph.size / 2,
                width: 40, height: glyph.size + 8)
        }
    }

    private var lastPill: OverlayRenderModel.Pill?

    private func renderPill(_ pill: OverlayRenderModel.Pill?) {
        if pillBackground.superlayer == nil {
            layer?.addSublayer(pillBackground)
        }
        guard pill != lastPill else { return }
        lastPill = pill
        guard let pill else {
            pillBackground.isHidden = true
            return
        }
        let attributes: [NSAttributedString.Key: Any] = [
            .font: NSFont.systemFont(ofSize: 13, weight: .semibold)
        ]
        let textSize = (pill.text as NSString).size(withAttributes: attributes)
        let width = min(textSize.width + 36, bounds.width - 40)
        let height: CGFloat = 28
        pillBackground.isHidden = false
        pillBackground.backgroundColor = pill.background.cgColor
        pillBackground.frame = CGRect(
            x: (bounds.width - width) / 2, y: 48, width: width, height: height)
        pillText.string = pill.text
        pillText.frame = CGRect(x: 8, y: (height - 17) / 2, width: width - 16, height: 17)
    }
}
