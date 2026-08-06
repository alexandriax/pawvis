import CoreGraphics
import Foundation
import PawvisCore

/// Posts synthetic mouse events for gesture-engine output. Requires the
/// Accessibility permission; events go to the HID tap so every app sees them.
final class MouseController {
    private(set) var projector: ScreenProjector
    private var leftDown = false
    private var rightDown = false
    private var lastPoint: CGPoint = .zero

    init(projector: ScreenProjector) {
        self.projector = projector
    }

    func updateProjector(_ projector: ScreenProjector) {
        self.projector = projector
    }

    func apply(_ events: [GestureEvent]) {
        for event in events {
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
                post(type: button == .left ? .leftMouseDragged : .rightMouseDragged,
                     at: projector.toGlobal(to),
                     button: button == .left ? .left : .right)
            case .buttonUp(let button, let at, let clickCount):
                setButtonState(button, down: false)
                post(type: button == .left ? .leftMouseUp : .rightMouseUp,
                     at: projector.toGlobal(at),
                     button: button == .left ? .left : .right,
                     clickCount: clickCount)
            case .scroll(let dx, let dy, _):
                postScroll(dx: dx, dy: dy)
            case .dictationToggle:
                break // handled by the dictation controller
            }
        }
    }

    /// Emergency release — called when tracking stops or the app quits, so a
    /// pinch in progress can never leave the system with a stuck button.
    func releaseAllButtons() {
        if leftDown {
            post(type: .leftMouseUp, at: lastPoint, button: .left)
            leftDown = false
        }
        if rightDown {
            post(type: .rightMouseUp, at: lastPoint, button: .right)
            rightDown = false
        }
    }

    private func setButtonState(_ button: PawvisCore.MouseButton, down: Bool) {
        switch button {
        case .left: leftDown = down
        case .right: rightDown = down
        }
    }

    private func post(
        type: CGEventType,
        at point: CGPoint,
        button: CGMouseButton,
        clickCount: Int = 0
    ) {
        let clamped = clamp(point)
        lastPoint = clamped
        guard let event = CGEvent(
            mouseEventSource: nil, mouseType: type,
            mouseCursorPosition: clamped, mouseButton: button) else { return }
        if clickCount > 0 {
            event.setIntegerValueField(.mouseEventClickState, value: Int64(clickCount))
        }
        event.post(tap: .cghidEventTap)
    }

    private func postScroll(dx: Double, dy: Double) {
        // Engine convention: positive dy = "hand up with natural scrolling" =
        // content should move up (toward the document's end), which is a
        // negative pixel-wheel value in CG's convention.
        guard let event = CGEvent(
            scrollWheelEvent2Source: nil,
            units: .pixel,
            wheelCount: 2,
            wheel1: Int32(-dy.rounded()),
            wheel2: Int32(-dx.rounded()),
            wheel3: 0) else { return }
        event.post(tap: .cghidEventTap)
    }

    private func clamp(_ p: CGPoint) -> CGPoint {
        let r = projector.targetRect
        return CGPoint(
            x: min(max(p.x, r.minX), r.maxX - 1),
            y: min(max(p.y, r.minY), r.maxY - 1))
    }
}
