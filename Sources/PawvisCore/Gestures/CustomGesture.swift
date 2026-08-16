import Foundation

/// The bindable one-shot gestures — motions and poses distinct enough from
/// ordinary pointing that they can carry a command of their own. None of them
/// is wired to anything by default: each becomes live only when the user binds
/// it to an action in Settings → Custom, which is also what makes the
/// inevitable overlap with normal hand movement (a swipe is, after all, a fast
/// move) an explicit opt-in rather than a surprise.
///
/// Every gesture here fires *once* per performance (with a refractory period),
/// unlike the continuous pointer gestures. Detection lives in
/// `CustomGestureDetector`; the engine emits `.customGesture(kind)` and the
/// app layer maps the kind to its bound `GestureAction`.
public enum CustomGesture: String, Codable, CaseIterable, Sendable {
    // Open-palm swipes: a fast, straight sweep, like flicking to the next
    // virtual desktop. One hand in any of the four directions; both hands
    // together (same direction, same moment) for the deliberate two-handed
    // version.
    case swipeLeft, swipeRight, swipeUp, swipeDown
    case twoHandSwipeLeft, twoHandSwipeRight

    // The Palpatine: hand (or both hands) held up open toward the camera,
    // fingers wiggling while the palm stays put. Nothing in ordinary cursor
    // work oscillates the fingertips like that, which is what makes it
    // error-proof.
    case fingerWiggle, twoHandFingerWiggle

    // Held poses: unmistakable shapes dwelled on for a beat.
    case thumbsUp, thumbsDown, shaka

    // Grab & fling: gather all fingertips onto the thumb (the whole hand
    // closes, as if pinching the screen itself), then fling toward an edge or
    // corner. The open→gathered transition is required, so a hand that was
    // simply resting closed can never fling.
    case grabFlingLeft, grabFlingRight, grabFlingUp, grabFlingDown
    case grabFlingUpLeft, grabFlingUpRight, grabFlingDownLeft, grabFlingDownRight

    /// The detection families: gestures in one family share a state machine
    /// and a sensitivity setting.
    public enum Family: String, Codable, CaseIterable, Sendable {
        case swipe, wiggle, holdPose, grabFling

        public var displayName: String {
            switch self {
            case .swipe: return "Swipes"
            case .wiggle: return "Finger wiggle"
            case .holdPose: return "Held poses"
            case .grabFling: return "Grab & fling"
            }
        }
    }

    public var family: Family {
        switch self {
        case .swipeLeft, .swipeRight, .swipeUp, .swipeDown,
             .twoHandSwipeLeft, .twoHandSwipeRight:
            return .swipe
        case .fingerWiggle, .twoHandFingerWiggle:
            return .wiggle
        case .thumbsUp, .thumbsDown, .shaka:
            return .holdPose
        case .grabFlingLeft, .grabFlingRight, .grabFlingUp, .grabFlingDown,
             .grabFlingUpLeft, .grabFlingUpRight, .grabFlingDownLeft, .grabFlingDownRight:
            return .grabFling
        }
    }

    public var displayName: String {
        switch self {
        case .swipeLeft: return "Swipe left"
        case .swipeRight: return "Swipe right"
        case .swipeUp: return "Swipe up"
        case .swipeDown: return "Swipe down"
        case .twoHandSwipeLeft: return "Two-hand swipe left"
        case .twoHandSwipeRight: return "Two-hand swipe right"
        case .fingerWiggle: return "Finger wiggle"
        case .twoHandFingerWiggle: return "Two-hand finger wiggle"
        case .thumbsUp: return "Thumbs up"
        case .thumbsDown: return "Thumbs down"
        case .shaka: return "Shaka"
        case .grabFlingLeft: return "Grab & fling left"
        case .grabFlingRight: return "Grab & fling right"
        case .grabFlingUp: return "Grab & fling up"
        case .grabFlingDown: return "Grab & fling down"
        case .grabFlingUpLeft: return "Grab & fling up-left"
        case .grabFlingUpRight: return "Grab & fling up-right"
        case .grabFlingDownLeft: return "Grab & fling down-left"
        case .grabFlingDownRight: return "Grab & fling down-right"
        }
    }

    /// How to perform it — the gallery card and the Gesture Guide row.
    public var howTo: String {
        switch self {
        case .swipeLeft:
            return "Sweep your open hand quickly to the left, like flicking to the next desktop."
        case .swipeRight:
            return "Sweep your open hand quickly to the right."
        case .swipeUp:
            return "Sweep your open hand quickly upward."
        case .swipeDown:
            return "Sweep your open hand quickly downward."
        case .twoHandSwipeLeft:
            return "Sweep both open hands to the left together."
        case .twoHandSwipeRight:
            return "Sweep both open hands to the right together."
        case .fingerWiggle:
            return "Hold one open hand up, fingers spread, and wiggle your fingers while the hand stays put."
        case .twoHandFingerWiggle:
            return "Hold both open hands up, fingers spread, and wiggle all your fingers at once."
        case .thumbsUp:
            return "Make a fist with your thumb pointing up and hold it for a beat."
        case .thumbsDown:
            return "Make a fist with your thumb pointing down and hold it for a beat."
        case .shaka:
            return "Thumb and pinky out, middle three fingers folded — hold the shaka for a beat."
        case .grabFlingLeft:
            return "Close your open hand into a grab (all fingertips onto your thumb), then fling it left."
        case .grabFlingRight:
            return "Close your open hand into a grab, then fling it right."
        case .grabFlingUp:
            return "Close your open hand into a grab, then fling it up."
        case .grabFlingDown:
            return "Close your open hand into a grab, then fling it down."
        case .grabFlingUpLeft:
            return "Close your open hand into a grab, then fling it toward the top-left."
        case .grabFlingUpRight:
            return "Close your open hand into a grab, then fling it toward the top-right."
        case .grabFlingDownLeft:
            return "Close your open hand into a grab, then fling it toward the bottom-left."
        case .grabFlingDownRight:
            return "Close your open hand into a grab, then fling it toward the bottom-right."
        }
    }

    /// The posed-hand glyph's name in `docs/assets/gestures` (bundled as
    /// `gesture-<name>.svg`).
    public var glyphName: String {
        switch self {
        case .swipeLeft: return "swipe-left"
        case .swipeRight: return "swipe-right"
        case .swipeUp: return "swipe-up"
        case .swipeDown: return "swipe-down"
        case .twoHandSwipeLeft: return "swipe-two-left"
        case .twoHandSwipeRight: return "swipe-two-right"
        case .fingerWiggle: return "wiggle"
        case .twoHandFingerWiggle: return "wiggle-two"
        case .thumbsUp: return "thumbs-up"
        case .thumbsDown: return "thumbs-down"
        case .shaka: return "shaka"
        case .grabFlingLeft: return "grab-left"
        case .grabFlingRight: return "grab-right"
        case .grabFlingUp: return "grab-up"
        case .grabFlingDown: return "grab-down"
        case .grabFlingUpLeft: return "grab-up-left"
        case .grabFlingUpRight: return "grab-up-right"
        case .grabFlingDownLeft: return "grab-down-left"
        case .grabFlingDownRight: return "grab-down-right"
        }
    }

    /// SF Symbol fallback for runs without a bundle (bare `swift run`).
    public var symbolName: String {
        switch family {
        case .swipe: return "hand.draw.fill"
        case .wiggle: return "hand.raised.fingers.spread.fill"
        case .holdPose:
            switch self {
            case .thumbsUp: return "hand.thumbsup.fill"
            case .thumbsDown: return "hand.thumbsdown.fill"
            default: return "hands.and.sparkles.fill"
            }
        case .grabFling: return "hand.pinch.fill"
        }
    }
}
