import Foundation

public enum MouseButton: String, Codable, Equatable, Sendable {
    case left, right
}

/// Discrete output of the gesture engine, consumed by the app's mouse
/// controller. All positions are screen-normalized ([0,1], top-left origin).
///
/// The gesture model is deliberately minimal: the thumb–index midpoint moves
/// the cursor, closing that pinch presses the left button (click), moving
/// while pinched drags, opening the pinch releases. Nothing else.
public enum GestureEvent: Equatable, Sendable {
    case move(to: Vec2)
    case buttonDown(MouseButton, at: Vec2, clickCount: Int)
    case drag(MouseButton, to: Vec2)
    case buttonUp(MouseButton, at: Vec2, clickCount: Int)
}

/// Per-hand overlay data: small dots for every detected fingertip.
public struct OverlayHand: Equatable, Sendable {
    /// Screen-normalized fingertip positions (unclamped — dots may run offscreen).
    public var fingertips: [HandJoint: Vec2] = [:]
    public var isPrimary: Bool = false

    public init() {}
}

/// Everything the overlay renderer needs for one frame.
public struct OverlayState: Equatable, Sendable {
    public var hands: [OverlayHand] = []
    /// Clamped cursor position (screen-normalized); nil when no hands.
    public var cursor: Vec2?
    /// False while the control trigger is still waiting for its gesture: the
    /// hand is tracked (dots render) but the cursor is parked and clicks are
    /// inert. Always true in `.anyHand` mode.
    public var armed: Bool = true
    /// True while the click gesture is closed (left button down).
    public var grabbed: Bool = false
    /// True while the right-click finger is dipped (right button down). Kept
    /// separate from `grabbed`, which stays left-only.
    public var rightGrabbed: Bool = false
    /// True once a press has moved past the drag threshold.
    public var isDragging: Bool = false
    /// Pinch strength ramp: 0 = tips comfortably apart, 1 = pinched. Drives the
    /// closing-ring feedback around the cursor. Pinned at 1 while *either*
    /// button is down — the ring says "you are pressing", not which finger.
    public var closingProgress: Double = 0

    public init() {}
}
