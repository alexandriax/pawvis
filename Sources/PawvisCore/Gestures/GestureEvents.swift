import Foundation

public enum MouseButton: String, Codable, Equatable, Sendable {
    case left, right
}

/// Discrete output of the gesture engine, consumed by the app's mouse/keyboard
/// controllers. All positions are screen-normalized ([0,1], top-left origin).
public enum GestureEvent: Equatable, Sendable {
    case move(to: Vec2)
    case buttonDown(MouseButton, at: Vec2, clickCount: Int)
    case drag(MouseButton, to: Vec2)
    case buttonUp(MouseButton, at: Vec2, clickCount: Int)
    /// Wheel deltas in pixel units. With `naturalScroll` enabled, moving the
    /// hand up produces a positive dy here; the platform layer owns the final
    /// sign convention for CGEvent.
    case scroll(dxPixels: Double, dyPixels: Double, at: Vec2)
    /// The configured dictation gesture completed its hold — arm/disarm voice input.
    case dictationToggle
}

/// High-level interaction mode, for the overlay and menu status.
public enum InteractionMode: String, Equatable, Sendable {
    case none        // no hands tracked
    case pointing
    case scrolling
    case clutch      // fist: cursor frozen
}

/// Per-hand overlay data: fingertip dots plus the "pinch iris" feedback.
public struct OverlayHand: Equatable, Sendable {
    /// Screen-normalized fingertip positions (unclamped — dots may run offscreen).
    public var fingertips: [HandJoint: Vec2] = [:]
    /// sporecaster's continuous pinch ramp: 1 at a tight pinch, 0 fully open.
    /// Drives the contracting iris ring even before the click threshold.
    public var leftPinchStrength: Double = 0
    public var leftPinchPoint: Vec2?
    public var rightPinchStrength: Double = 0
    public var rightPinchPoint: Vec2?
    public var isPrimary: Bool = false

    public init() {}
}

/// Everything the overlay renderer needs for one frame.
public struct OverlayState: Equatable, Sendable {
    public var hands: [OverlayHand] = []
    /// Clamped cursor position (screen-normalized); nil when no hands.
    public var cursor: Vec2?
    public var mode: InteractionMode = .none
    public var leftEngaged: Bool = false
    public var rightEngaged: Bool = false
    /// True once an engaged press has moved past the drag threshold.
    public var isDragging: Bool = false
    /// 0→1 while the dictation-toggle pose is being held; nil otherwise.
    public var dictationHoldProgress: Double?

    public init() {}
}
