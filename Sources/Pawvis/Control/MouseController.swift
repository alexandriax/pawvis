import CoreGraphics
import Foundation
import PawvisCore
import QuartzCore

/// Posts synthetic mouse events for gesture-engine output. Requires the
/// Accessibility permission; events go to the HID tap so every app sees them.
///
/// Delivery pacing is load-bearing: two mouse CGEvents posted back-to-back
/// are intermittently dropped by the system (measured: 20% of mouseUps lost
/// at 0 ms spacing, 0% at ≥4 ms — and a lost mouseUp wedges the target app,
/// which then ignores every later click). All posts therefore run on a serial
/// queue that enforces a minimum inter-event gap.
final class MouseController {
    private(set) var projector: ScreenProjector
    private var leftDown = false
    private var rightDown = false
    private var lastPoint: CGPoint = .zero

    private let source = CGEventSource(stateID: .hidSystemState)
    private static let minPostInterval: TimeInterval = 0.006
    private let postQueue = DispatchQueue(label: "com.pawvis.mouse.post", qos: .userInteractive)
    private var lastPostTime: TimeInterval = 0 // touched only on postQueue

    init(projector: ScreenProjector) {
        self.projector = projector
    }

    func updateProjector(_ projector: ScreenProjector) {
        self.projector = projector
    }

    func apply(_ events: [GestureEvent]) {
        for (index, event) in events.enumerated() {
            switch event {
            case .move(let to):
                post(type: .mouseMoved, at: projector.toGlobal(to), button: .left)
            case .buttonDown(let button, let at, let clickCount):
                setButtonState(button, down: true)
                post(type: button == .left ? .leftMouseDown : .rightMouseDown,
                     at: projector.toGlobal(at),
                     button: button == .left ? .left : .right,
                     clickCount: clickCount)
            case .drag(let button, let to):
                // A drag immediately followed by the same button's up is
                // redundant (the up carries the final position) — and it's
                // exactly the tight pair that loses the mouseUp. Skip it.
                if case .buttonUp(let upButton, _, _)? = events[safe: index + 1],
                   upButton == button {
                    continue
                }
                post(type: button == .left ? .leftMouseDragged : .rightMouseDragged,
                     at: projector.toGlobal(to),
                     button: button == .left ? .left : .right)
            case .buttonUp(let button, let at, let clickCount):
                setButtonState(button, down: false)
                post(type: button == .left ? .leftMouseUp : .rightMouseUp,
                     at: projector.toGlobal(at),
                     button: button == .left ? .left : .right,
                     clickCount: clickCount)
            case .scroll(let deltaY):
                postScroll(deltaY)
            case .disableTracking:
                // Not a mouse event — PawvisController intercepts it before
                // apply. One that slips through is a no-op.
                break
            }
        }
    }

    /// Screen-heights of content scrolled per screen-height of hand travel.
    /// >1 because a page-per-sweep felt sluggish next to a trackpad.
    private static let scrollGain: Double = 2.2

    /// Posts one continuous (trackpad-style) pixel scroll step. `deltaY` is
    /// the engine's screen-normalized wheel delta, positive = scroll up —
    /// already Quartz's positive axis-1 direction, so no flip here.
    private func postScroll(_ deltaY: Double) {
        let pixels = Int32((deltaY * projector.targetRect.height * Self.scrollGain).rounded())
        guard pixels != 0,
              let event = CGEvent(
                scrollWheelEvent2Source: source, units: .pixel,
                wheelCount: 1, wheel1: pixels, wheel2: 0, wheel3: 0) else { return }
        // Continuous = smooth pixel scrolling; apps animate it like a trackpad.
        event.setIntegerValueField(.scrollWheelEventIsContinuous, value: 1)
        postQueue.async {
            self.paceAndPost(event)
        }
    }

    /// Clears any synthetic button a previous (crashed/killed) instance left
    /// logically down. Posted at the current cursor position on launch; a
    /// spurious button-up is harmless when nothing is pressed.
    static func postDefensiveButtonRelease() {
        let position = CGEvent(source: nil)?.location ?? .zero
        let source = CGEventSource(stateID: .hidSystemState)
        for (type, button) in [(CGEventType.leftMouseUp, CGMouseButton.left),
                               (CGEventType.rightMouseUp, CGMouseButton.right)] {
            let event = CGEvent(mouseEventSource: source, mouseType: type,
                                mouseCursorPosition: position, mouseButton: button)
            event?.setIntegerValueField(.mouseEventClickState, value: 1)
            event?.post(tap: .cghidEventTap)
            usleep(8000) // pace the pair like everything else
        }
    }

    /// Emergency release — called when tracking stops or the app quits, so a
    /// pinch in progress can never leave the system with a stuck button.
    /// Synchronous: flushes the posting queue before returning, so it is safe
    /// to call on the way out of the process.
    func releaseAllButtons() {
        var events: [CGEvent] = []
        if leftDown, let e = makeEvent(type: .leftMouseUp, at: lastPoint, button: .left, clickCount: 1) {
            events.append(e)
        }
        if rightDown, let e = makeEvent(type: .rightMouseUp, at: lastPoint, button: .right, clickCount: 1) {
            events.append(e)
        }
        leftDown = false
        rightDown = false
        guard !events.isEmpty else { return }
        postQueue.sync {
            for event in events {
                self.paceAndPost(event)
            }
        }
    }

    private func setButtonState(_ button: PawvisCore.MouseButton, down: Bool) {
        switch button {
        case .left: leftDown = down
        case .right: rightDown = down
        }
    }

    private func makeEvent(
        type: CGEventType,
        at point: CGPoint,
        button: CGMouseButton,
        clickCount: Int
    ) -> CGEvent? {
        let clamped = clamp(point)
        lastPoint = clamped
        guard let event = CGEvent(
            mouseEventSource: source, mouseType: type,
            mouseCursorPosition: clamped, mouseButton: button) else { return nil }
        switch type {
        case .leftMouseDown, .leftMouseUp, .rightMouseDown, .rightMouseUp:
            // Downs/ups always carry a valid clickState (a clickState-0 up is
            // malformed). Drags already default to clickState 1 / pressure 1.
            event.setIntegerValueField(.mouseEventClickState, value: Int64(max(clickCount, 1)))
        default:
            break
        }
        return event
    }

    private func post(
        type: CGEventType,
        at point: CGPoint,
        button: CGMouseButton,
        clickCount: Int = 0
    ) {
        guard let event = makeEvent(type: type, at: point, button: button, clickCount: clickCount) else {
            return
        }
        postQueue.async {
            self.paceAndPost(event)
        }
    }

    /// Runs on `postQueue` only: enforce the minimum gap, then post.
    private func paceAndPost(_ event: CGEvent) {
        let now = CACurrentMediaTime()
        let wait = Self.minPostInterval - (now - lastPostTime)
        if wait > 0 {
            usleep(UInt32(wait * 1_000_000))
        }
        event.post(tap: .cghidEventTap)
        lastPostTime = CACurrentMediaTime()
    }

    private func clamp(_ p: CGPoint) -> CGPoint {
        let r = projector.targetRect
        return CGPoint(
            x: min(max(p.x, r.minX), r.maxX - 1),
            y: min(max(p.y, r.minY), r.maxY - 1))
    }
}

private extension Array {
    subscript(safe index: Int) -> Element? {
        indices.contains(index) ? self[index] : nil
    }
}
