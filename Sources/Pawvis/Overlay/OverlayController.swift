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

    private var prevGrabbed = false

    func render(
        overlay: OverlayState,
        dictation: DictationHUD,
        projector: ScreenProjector,
        accessibilityBlocked: Bool = false
    ) {
        guard visible else { return }
        let grabRose = overlay.grabbed && !prevGrabbed
        prevGrabbed = overlay.grabbed

        for window in windows {
            var model = OverlayRenderModel()
            let bounds = window.displayBoundsCG

            func localize(_ norm: Vec2) -> CGPoint? {
                let global = projector.toGlobal(norm)
                // Draw a little past the edge so dots slide off naturally.
                guard bounds.insetBy(dx: -80, dy: -80).contains(global) else { return nil }
                return CGPoint(x: global.x - bounds.minX, y: global.y - bounds.minY)
            }

            // Small dots for every detected fingertip.
            if config.showFingertipDots {
                for hand in overlay.hands {
                    let handAlpha: CGFloat = hand.isPrimary ? 0.8 : 0.4
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

            // The claw IS the cursor: open paw while pointing, closed paw
            // while the hand is closed (button down). The ring around it
            // tightens as the hand closes and fills while grabbed.
            if config.showCursorHalo, let cursor = overlay.cursor, let local = localize(cursor) {
                model.clawCursor = .init(center: local, closed: overlay.grabbed)

                if config.showPinchRing {
                    let progress = overlay.closingProgress
                    let ringRadius: CGFloat = overlay.grabbed
                        ? (overlay.isDragging ? 26 : 20)
                        : 30 - 12 * progress
                    let ringColor = overlay.grabbed
                        ? PawvisTheme.purple
                        : (NSColor.white.blended(withFraction: progress, of: PawvisTheme.purple)
                            ?? PawvisTheme.purple)
                    model.rings.append(.init(
                        center: local,
                        radius: ringRadius,
                        lineWidth: overlay.grabbed ? 3.5 : 2.5,
                        strokeColor: ringColor,
                        fillColor: overlay.grabbed
                            ? PawvisTheme.purple.withAlphaComponent(0.35) : nil,
                        alpha: overlay.grabbed ? 1 : 0.5 + 0.5 * progress))
                }

                if grabRose {
                    window.contentOverlayView.flash(at: local, color: PawvisTheme.purple)
                }
            }

            if config.showStatusPill, window.isOnMainScreen {
                model.pill = Self.pill(for: dictation, accessibilityBlocked: accessibilityBlocked)
            }

            window.contentOverlayView.render(model)
        }
    }

    // MARK: - Styling

    private static func dotStyle(for joint: HandJoint) -> (CGFloat, NSColor) {
        switch joint {
        case .indexTip: return (4, PawvisTheme.purpleLight)
        case .thumbTip: return (4, PawvisTheme.blueLight)
        default: return (3.5, NSColor.white.withAlphaComponent(0.6))
        }
    }

    private static func pill(
        for dictation: DictationHUD, accessibilityBlocked: Bool
    ) -> OverlayRenderModel.Pill? {
        // An Accessibility problem beats everything except a dictation error:
        // without it, clicks silently do nothing, which looks like total
        // breakage. Make it impossible to miss.
        if accessibilityBlocked {
            if case .error = dictation {} else {
                return .init(
                    text: "⚠️ Clicks blocked — grant Accessibility (after rebuilds: remove & re-add Pawvis)",
                    background: NSColor.systemRed.withAlphaComponent(0.92))
            }
        }
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

    struct Pill: Equatable {
        var text: String
        var background: NSColor
    }

    struct ClawCursor {
        var center: CGPoint
        /// Closed = hand is gripping (button down): the retracted-claw glyph,
        /// tinted purple. Open = pointing: full claw, white.
        var closed: Bool
    }

    var dots: [Dot] = []
    var rings: [Ring] = []
    var clawCursor: ClawCursor?
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
    private let pillBackground = CALayer()
    private let pillText = CATextLayer()

    // The claw cursor: a tinted glyph over a dark offset copy for contrast on
    // any background. Sized like a real macOS cursor (~24 pt).
    private let clawShadowLayer = CALayer()
    private let clawFillLayer = CALayer()
    private let clawFallbackDot = CAShapeLayer()
    private var clawTintCache: [String: CGImage] = [:]

    private static let clawSize = CGSize(width: 24, height: 24)

    private static func loadGlyph(_ name: String) -> CGImage? {
        guard let url = Bundle.main.url(forResource: name, withExtension: "png"),
              let source = CGImageSourceCreateWithURL(url as CFURL, nil),
              let image = CGImageSourceCreateImageAtIndex(source, 0, nil) else { return nil }
        return image
    }

    /// Open paw = pointing; closed paw (claws retracted) = button down.
    private static let clawOpenGlyph: CGImage? = loadGlyph("menubar-claw")
    private static let clawClosedGlyph: CGImage? = loadGlyph("claw-closed") ?? loadGlyph("menubar-claw")

    private func tintedClaw(_ key: String, glyph: CGImage?, color: NSColor) -> CGImage? {
        if let cached = clawTintCache[key] { return cached }
        guard let glyph,
              let ctx = CGContext(
                data: nil, width: glyph.width, height: glyph.height,
                bitsPerComponent: 8, bytesPerRow: glyph.width * 4,
                space: CGColorSpace(name: CGColorSpace.sRGB)!,
                bitmapInfo: CGImageAlphaInfo.premultipliedLast.rawValue) else { return nil }
        let rect = CGRect(x: 0, y: 0, width: glyph.width, height: glyph.height)
        ctx.clip(to: rect, mask: glyph)
        ctx.setFillColor(color.usingColorSpace(.sRGB)?.cgColor ?? color.cgColor)
        ctx.fill(rect)
        let image = ctx.makeImage()
        clawTintCache[key] = image
        return image
    }

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

    /// One-shot expanding-ring pulse confirming a click was registered — makes
    /// "Pawvis saw the pinch" visibly distinct from "the click reached the app".
    func flash(at point: CGPoint, color: NSColor) {
        let ring = CAShapeLayer()
        let r: CGFloat = 13
        ring.bounds = CGRect(x: 0, y: 0, width: r * 2, height: r * 2)
        ring.position = point
        ring.path = CGPath(ellipseIn: ring.bounds, transform: nil)
        ring.strokeColor = color.cgColor
        ring.fillColor = NSColor.clear.cgColor
        ring.lineWidth = 3
        layer?.addSublayer(ring)

        let scale = CABasicAnimation(keyPath: "transform.scale")
        scale.fromValue = 1.0
        scale.toValue = 2.3
        let fade = CABasicAnimation(keyPath: "opacity")
        fade.fromValue = 0.9
        fade.toValue = 0.0
        let group = CAAnimationGroup()
        group.animations = [scale, fade]
        group.duration = 0.35
        group.timingFunction = CAMediaTimingFunction(name: .easeOut)
        group.isRemovedOnCompletion = false
        group.fillMode = .forwards
        ring.add(group, forKey: "clickFlash")
        DispatchQueue.main.asyncAfter(deadline: .now() + 0.4) {
            ring.removeFromSuperlayer()
        }
    }

    func render(_ model: OverlayRenderModel) {
        CATransaction.begin()
        CATransaction.setDisableActions(true)
        defer { CATransaction.commit() }

        renderDots(model.dots)
        renderRings(model.rings)
        renderClawCursor(model.clawCursor)
        renderPill(model.pill)
    }

    private func renderClawCursor(_ claw: OverlayRenderModel.ClawCursor?) {
        if clawFillLayer.superlayer == nil, let layer {
            clawShadowLayer.bounds = CGRect(origin: .zero, size: Self.clawSize)
            clawFillLayer.bounds = CGRect(origin: .zero, size: Self.clawSize)
            clawShadowLayer.contentsGravity = .resizeAspect
            clawFillLayer.contentsGravity = .resizeAspect
            clawShadowLayer.opacity = 0.55
            layer.addSublayer(clawShadowLayer)
            layer.addSublayer(clawFillLayer)
            layer.addSublayer(clawFallbackDot)
        }

        guard let claw else {
            clawShadowLayer.isHidden = true
            clawFillLayer.isHidden = true
            clawFallbackDot.isHidden = true
            return
        }

        let glyph = claw.closed ? Self.clawClosedGlyph : Self.clawOpenGlyph
        if glyph != nil {
            let stateKey = claw.closed ? "closed" : "open"
            let fillColor: NSColor = claw.closed ? PawvisTheme.purple : .white
            clawShadowLayer.isHidden = false
            clawFillLayer.isHidden = false
            clawFallbackDot.isHidden = true
            clawShadowLayer.contents = tintedClaw("\(stateKey)-shadow", glyph: glyph, color: .black)
            clawFillLayer.contents = tintedClaw("\(stateKey)-fill", glyph: glyph, color: fillColor)
            // The closed paw reads slightly smaller — like a squeeze.
            let scale: CGFloat = claw.closed ? 0.85 : 1.0
            clawShadowLayer.position = CGPoint(x: claw.center.x + 1, y: claw.center.y + 1.5)
            clawShadowLayer.transform = CATransform3DMakeScale(1.08 * scale, 1.08 * scale, 1)
            clawFillLayer.transform = CATransform3DMakeScale(scale, scale, 1)
            clawFillLayer.position = claw.center
        } else {
            // No glyph asset (bare binary): a filled dot marks the cursor.
            clawShadowLayer.isHidden = true
            clawFillLayer.isHidden = true
            clawFallbackDot.isHidden = false
            clawFallbackDot.path = CGPath(
                ellipseIn: CGRect(x: claw.center.x - 4.5, y: claw.center.y - 4.5, width: 9, height: 9),
                transform: nil)
            clawFallbackDot.fillColor = (claw.closed ? PawvisTheme.purple : .white).cgColor
        }
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
