import Foundation

/// The bindable one-shot gestures — motions and poses distinct enough from
/// ordinary pointing that they can carry a command of their own. None of them
/// is bound to anything by default: the Custom tab lists every one, and only
/// a gesture given an action is detected at all.
///
/// Every gesture here fires *once* per performance (with a refractory period),
/// unlike the continuous pointer gestures. Detection lives in
/// `CustomGestureDetector`; the engine emits `.customGesture(kind)` and the
/// app layer maps the kind to its bound `GestureAction`.
///
/// (The open-palm swipes shipped here once and were retired: real sweeps
/// blur, close mid-arc and mirror themselves on the return stroke, and they
/// never got reliable enough to trust. Their code lives in git history; the
/// tolerant settings decoders drop saved swipe bindings on sight, which is
/// the whole retirement path.)
public enum CustomGesture: String, Codable, CaseIterable, Sendable {
    // The Palpatine: hand (or both hands) held up open toward the camera,
    // fingers wiggling while the palm stays put. Nothing in ordinary cursor
    // work oscillates the fingertips like that, which is what makes it
    // error-proof.
    case fingerWiggle, twoHandFingerWiggle

    // The same wiggle from the desk posture: hand flat, palm down, fingers
    // pointed at the screen, drumming on invisible keys. A different gesture
    // from the raised wiggle on purpose — the two orientations are told
    // apart by where the fingertips stand relative to the knuckle line, and
    // each can carry its own action.
    case pointedWiggle, twoHandPointedWiggle

    // Held poses: unmistakable shapes dwelled on for a beat. The thumb
    // signals cover all four directions — a fist with the thumb up, down,
    // or tilted to point straight left or right.
    case thumbsUp, thumbsDown, thumbsLeft, thumbsRight, shaka

    // Grab & fling: gather all your fingertips onto your thumb (wherever
    // that bunch forms — in front of the palm is fine), then fling toward an
    // edge or corner. The open→gathered transition is required, so a hand
    // that was simply resting closed can never fling.
    case grabFlingLeft, grabFlingRight, grabFlingUp, grabFlingDown
    case grabFlingUpLeft, grabFlingUpRight, grabFlingDownLeft, grabFlingDownRight

    /// The detection families: gestures in one family share a state machine
    /// and tuning.
    public enum Family: String, Codable, CaseIterable, Sendable {
        case wiggle, holdPose, grabFling

        public var displayName: String {
            switch self {
            case .wiggle: return "Finger wiggle"
            case .holdPose: return "Held poses"
            case .grabFling: return "Grab & fling"
            }
        }

        /// One line under the family header in Settings.
        public var blurb: String {
            switch self {
            case .wiggle:
                return "Fingers wiggling while the hand stays put — hand raised with the palm to the camera, or pointed flat at the screen. Two orientations, two separate gestures."
            case .holdPose:
                return "An unambiguous shape, held for a beat."
            case .grabFling:
                return "Close your open hand into a grab, then fling it toward an edge or corner. The cursor parks while you hold the grab."
            }
        }
    }

    public var family: Family {
        switch self {
        case .fingerWiggle, .twoHandFingerWiggle, .pointedWiggle, .twoHandPointedWiggle:
            return .wiggle
        case .thumbsUp, .thumbsDown, .thumbsLeft, .thumbsRight, .shaka:
            return .holdPose
        case .grabFlingLeft, .grabFlingRight, .grabFlingUp, .grabFlingDown,
             .grabFlingUpLeft, .grabFlingUpRight, .grabFlingDownLeft, .grabFlingDownRight:
            return .grabFling
        }
    }

    public var displayName: String {
        switch self {
        case .fingerWiggle: return "Raised finger wiggle"
        case .twoHandFingerWiggle: return "Two-hand raised wiggle"
        case .pointedWiggle: return "Pointed finger wiggle"
        case .twoHandPointedWiggle: return "Two-hand pointed wiggle"
        case .thumbsUp: return "Thumbs up"
        case .thumbsDown: return "Thumbs down"
        case .thumbsLeft: return "Thumb to the left"
        case .thumbsRight: return "Thumb to the right"
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

    /// How to perform it — the Settings row and the Gesture Guide.
    public var howTo: String {
        switch self {
        case .fingerWiggle:
            return "Hold one open hand up, palm to the camera, fingers spread, and wiggle your fingers while the hand stays put."
        case .twoHandFingerWiggle:
            return "Hold both open hands up, palms to the camera, and wiggle all your fingers at once."
        case .pointedWiggle:
            return "Point one hand at the screen, palm down, and wiggle your fingers up and down, drumming on invisible keys, while the hand stays put."
        case .twoHandPointedWiggle:
            return "Point both hands at the screen, palms down, and wiggle all your fingers at once."
        case .thumbsUp:
            return "Make a fist with your thumb pointing up and hold it for a beat."
        case .thumbsDown:
            return "Make a fist with your thumb pointing down and hold it for a beat."
        case .thumbsLeft:
            return "Make a fist and tilt it so your thumb points straight left; hold it for a beat."
        case .thumbsRight:
            return "Make a fist and tilt it so your thumb points straight right; hold it for a beat."
        case .shaka:
            return "Thumb and pinky out, middle three fingers folded — hold the shaka for a beat."
        case .grabFlingLeft:
            return "Bunch all your fingertips onto your thumb, then fling the bunch left."
        case .grabFlingRight:
            return "Bunch all your fingertips onto your thumb, then fling the bunch right."
        case .grabFlingUp:
            return "Bunch all your fingertips onto your thumb, then fling the bunch up."
        case .grabFlingDown:
            return "Bunch all your fingertips onto your thumb, then fling the bunch down."
        case .grabFlingUpLeft:
            return "Bunch all your fingertips onto your thumb, then fling toward the top-left."
        case .grabFlingUpRight:
            return "Bunch all your fingertips onto your thumb, then fling toward the top-right."
        case .grabFlingDownLeft:
            return "Bunch all your fingertips onto your thumb, then fling toward the bottom-left."
        case .grabFlingDownRight:
            return "Bunch all your fingertips onto your thumb, then fling toward the bottom-right."
        }
    }

    /// The posed-hand glyph's name in `docs/assets/gestures` (bundled as
    /// `gesture-<name>.svg`).
    public var glyphName: String {
        switch self {
        case .fingerWiggle: return "wiggle"
        case .twoHandFingerWiggle: return "wiggle-two"
        case .pointedWiggle: return "wiggle-pointed"
        case .twoHandPointedWiggle: return "wiggle-pointed-two"
        case .thumbsUp: return "thumbs-up"
        case .thumbsDown: return "thumbs-down"
        case .thumbsLeft: return "thumbs-left"
        case .thumbsRight: return "thumbs-right"
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
        case .wiggle:
            switch self {
            case .pointedWiggle, .twoHandPointedWiggle: return "hand.point.left.fill"
            default: return "hand.raised.fingers.spread.fill"
            }
        case .holdPose:
            switch self {
            case .thumbsUp, .thumbsLeft, .thumbsRight: return "hand.thumbsup.fill"
            case .thumbsDown: return "hand.thumbsdown.fill"
            default: return "hands.and.sparkles.fill"
            }
        case .grabFling: return "hand.pinch.fill"
        }
    }
}
