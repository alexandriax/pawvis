import Foundation

/// What a tracked hand must do before it controls the cursor. Tracking itself
/// always runs while enabled — this gates only whether the hand may move the
/// cursor and click.
public enum ControlTrigger: String, Codable, CaseIterable, Sendable {
    /// Show an open hand — all four fingers extended, thumb free — to take
    /// control; close the hand into a fist for a moment to let go. Keeps a
    /// hand that is merely visible (resting, typing, gesturing) from dragging
    /// the cursor around. Default.
    case openHand
    /// Any tracked hand controls the cursor immediately (the original
    /// behavior).
    case anyHand
    /// The cursor is never taken: no pointing, no clicks, no scrolling.
    /// Hands are still tracked and the custom gestures (and the tracking-off
    /// wave) still fire — the hands-as-a-remote mode.
    case gesturesOnly

    public var displayName: String {
        switch self {
        case .openHand: return "Open hand"
        case .anyHand: return "Any detected hand"
        case .gesturesOnly: return "Never — custom gestures only"
        }
    }
}

/// How the interaction box — the slice of the camera view that maps onto the
/// whole screen — is chosen.
public enum ReachMode: String, Codable, CaseIterable, Sendable {
    /// Sized from the hand actually being tracked: a big (close) hand gets a
    /// wide box, a small (far) hand a tight one, so the sweep needed to cross
    /// the screen feels the same at any distance from the camera. Default.
    case auto
    /// `interactionBox` verbatim — the Reach slider, and nothing else.
    case manual
}

/// Tunables for the (deliberately minimal) gesture engine: the palm moves the
/// cursor, dipping the index finger clicks/drags, a second finger's dip
/// right-clicks, and the scroll pose scrolls. Thresholds, smoothing, and
/// slot-tracking defaults come from sporecaster's tuned values.
public struct GestureConfig: Codable, Equatable, Sendable {
    // MARK: Control trigger
    /// What arms cursor control: `.openHand` requires showing an open hand
    /// before the cursor follows; `.anyHand` follows any tracked hand.
    public var controlTrigger: ControlTrigger = .openHand

    // MARK: Click detection
    /// Scale for a *finger dip* ratio: the tip→knuckle differential idles
    /// near 1.0 and drops to ~0.5 when the finger taps down (0.45 × 1.5 =
    /// 0.675 at the default slider position). Shared by the index-tap left
    /// button and the right-click dip, so both buttons stay on the same
    /// sensitivity slider.
    public static let dipEngageFactor = 1.5
    /// The sensitivity slider (the name predates the index-tap model — this
    /// was once a raw thumb–index pinch distance, and keeping the key keeps
    /// everyone's saved tuning). Lower = the finger must dip further before a
    /// click fires.
    public var pinchEngageRatio: Double = 0.45
    /// How much past the engage threshold the ratio must recover to release.
    /// Deliberately small so engaging and releasing feel like the same
    /// distance; just enough band remains to stop boundary chatter, and
    /// smoothing and the debounce handle the rest.
    public var pinchReleaseHysteresis: Double = 0.08
    /// The release threshold tracks the engage threshold (and therefore the
    /// sensitivity slider).
    public var pinchReleaseRatio: Double { pinchEngageRatio + pinchReleaseHysteresis }
    /// What the engine compares the index-tap differential against: the
    /// slider scaled into the dip's range.
    public var engageRatio: Double { pinchEngageRatio * Self.dipEngageFactor }
    /// Release tracks engage by the same hysteresis.
    public var releaseRatio: Double { engageRatio + pinchReleaseHysteresis }
    /// Consecutive frames past a threshold before the transition fires, in
    /// *both* directions. sporecaster needed none on MediaPipe; Vision's
    /// landmarks spike often enough that single-frame noise must not click.
    public var pinchDebounceFrames: Int = 2

    // MARK: Right click
    /// Dip a second finger to press the right button. The open index-tap hand
    /// leaves a lone finger's drop unambiguous.
    public var rightClickEnabled: Bool = true
    /// Whose dip right-clicks. The little finger is the one the click doesn't
    /// use, and dropping it barely disturbs the rest of the hand — but it
    /// can never be the finger already pressing the left button, so setting
    /// this to `.index` simply turns right-click off.
    public var rightClickFinger: Finger = .little
    /// The right-click dip rides the same sensitivity slider and dip factor
    /// as the left button.
    public var rightEngageRatio: Double { pinchEngageRatio * Self.dipEngageFactor }
    /// Release tracks engage by the same hysteresis as the left button.
    public var rightReleaseRatio: Double { rightEngageRatio + pinchReleaseHysteresis }

    // MARK: Scroll
    /// Fold the middle and ring fingers in — index and little stay up — and
    /// vertical hand movement scrolls instead of moving the cursor (which
    /// parks while the pose is held).
    public var scrollEnabled: Bool = true
    /// Flip which way the page moves relative to the hand. Off: hand up =
    /// scroll up (`.scroll` deltas are positive-up wheel units).
    public var scrollInvert: Bool = false

    // MARK: Tracking-off wave
    /// Hold up both hands open with fingers spread wide (a double high-five)
    /// and cross them over each other back and forth to switch hand tracking
    /// off entirely — the same full stop as the menu bar toggle. Optional,
    /// on by default.
    public var crissCrossDisableEnabled: Bool = true
    /// How many times the hands must trade sides before tracking switches
    /// off. Two is one full wave: cross over, then back.
    public var crissCrossDisableCrossings: Int = 2

    // MARK: Click timing
    /// Two clicks within this interval (and within `doubleClickSlop`) become a
    /// double-click (macOS default ballpark).
    public var doubleClickInterval: TimeInterval = 0.45
    /// Max cursor travel (screen-normalized) between clicks that still chains
    /// into a double-click.
    public var doubleClickSlop: Double = 0.025
    /// Cursor travel (screen-normalized) beyond which a pinch starts dragging.
    /// Below this the cursor holds still, so quick clicks don't micro-drag.
    public var dragActivationDistance: Double = 0.010
    /// Tap window: for this long after the button goes down, nothing drags and
    /// the cursor stays pinned at the press point. Movement alone was starting
    /// drags, which turned nearly every quick click into a micro-drag — a hand
    /// in the air always drifts a little while the fingers close and open.
    public var dragStartDelay: TimeInterval = 0.30
    /// Travel inside the tap window that means the drag is deliberate (a flick,
    /// not press wobble), starting the drag immediately.
    public var dragIntentDistance: Double = 0.030
    /// Minimum travel between emitted drag positions. Overlapping fingertips
    /// confuse Vision, so a held pinch shivers by a fraction of a percent;
    /// re-emitting that shiver reads as a shaking drag. Plain moves use half
    /// this, enough to kill stationary shimmer without feeling sticky.
    public var jitterDeadband: Double = 0.004

    // MARK: Pointer
    /// sporecaster's landmark tuning, applied to every joint. Vision is noisier
    /// than MediaPipe, so this is the floor for smoothing, not the ceiling.
    public var smoothing: OneEuroFilter.Params = .landmark

    // MARK: Pose classification thresholds (used by hand features)
    public var poseThresholds: PoseThresholds = PoseThresholds()

    // MARK: Tracking robustness
    public var minHandConfidence: Double = 0.30
    public var minJointConfidence: Double = 0.25
    /// If tracking drops out mid-pinch, keep state alive this long before
    /// releasing the button (sporecaster resets slots at 300 ms).
    public var trackingLossGrace: TimeInterval = 0.30

    // MARK: Mapping
    /// The manual box, and the starting point the automatic one drifts from.
    public var interactionBox: InteractionBox = .default
    /// Whether the engine sizes the box to the hand it can see (`.auto`) or
    /// uses `interactionBox` verbatim (`.manual`).
    public var reachMode: ReachMode = .auto
    public var mirrorCamera: Bool = true

    public init() {}

    public static let `default` = GestureConfig()

    enum CodingKeys: String, CodingKey {
        case controlTrigger
        case pinchEngageRatio, pinchReleaseHysteresis, pinchDebounceFrames
        case rightClickEnabled, rightClickFinger
        case scrollEnabled, scrollInvert
        case crissCrossDisableEnabled, crissCrossDisableCrossings
        case doubleClickInterval, doubleClickSlop, dragActivationDistance
        case dragStartDelay, dragIntentDistance, jitterDeadband
        case smoothing, poseThresholds
        case minHandConfidence, minJointConfidence, trackingLossGrace
        case interactionBox, reachMode, mirrorCamera
    }

    /// Field-tolerant decoding: unknown/missing/mistyped fields (including
    /// keys from retired gestures) keep defaults instead of failing the tree.
    public init(from decoder: Decoder) throws {
        self.init()
        let c = try decoder.container(keyedBy: CodingKeys.self)
        if let v = try? c.decodeIfPresent(ControlTrigger.self, forKey: .controlTrigger) { controlTrigger = v }
        if let v = try? c.decodeIfPresent(Double.self, forKey: .pinchEngageRatio) { pinchEngageRatio = v }
        if let v = try? c.decodeIfPresent(Double.self, forKey: .pinchReleaseHysteresis) { pinchReleaseHysteresis = v }
        if let v = try? c.decodeIfPresent(Int.self, forKey: .pinchDebounceFrames) { pinchDebounceFrames = v }
        if let v = try? c.decodeIfPresent(Bool.self, forKey: .rightClickEnabled) { rightClickEnabled = v }
        if let v = try? c.decodeIfPresent(Finger.self, forKey: .rightClickFinger) { rightClickFinger = v }
        if let v = try? c.decodeIfPresent(Bool.self, forKey: .scrollEnabled) { scrollEnabled = v }
        if let v = try? c.decodeIfPresent(Bool.self, forKey: .scrollInvert) { scrollInvert = v }
        if let v = try? c.decodeIfPresent(Bool.self, forKey: .crissCrossDisableEnabled) { crissCrossDisableEnabled = v }
        if let v = try? c.decodeIfPresent(Int.self, forKey: .crissCrossDisableCrossings) { crissCrossDisableCrossings = v }
        if let v = try? c.decodeIfPresent(TimeInterval.self, forKey: .doubleClickInterval) { doubleClickInterval = v }
        if let v = try? c.decodeIfPresent(Double.self, forKey: .doubleClickSlop) { doubleClickSlop = v }
        if let v = try? c.decodeIfPresent(Double.self, forKey: .dragActivationDistance) { dragActivationDistance = v }
        if let v = try? c.decodeIfPresent(TimeInterval.self, forKey: .dragStartDelay) { dragStartDelay = v }
        if let v = try? c.decodeIfPresent(Double.self, forKey: .dragIntentDistance) { dragIntentDistance = v }
        if let v = try? c.decodeIfPresent(Double.self, forKey: .jitterDeadband) { jitterDeadband = v }
        if let v = try? c.decodeIfPresent(OneEuroFilter.Params.self, forKey: .smoothing) { smoothing = v }
        if let v = try? c.decodeIfPresent(PoseThresholds.self, forKey: .poseThresholds) { poseThresholds = v }
        if let v = try? c.decodeIfPresent(Double.self, forKey: .minHandConfidence) { minHandConfidence = v }
        if let v = try? c.decodeIfPresent(Double.self, forKey: .minJointConfidence) { minJointConfidence = v }
        if let v = try? c.decodeIfPresent(TimeInterval.self, forKey: .trackingLossGrace) { trackingLossGrace = v }
        if let v = try? c.decodeIfPresent(InteractionBox.self, forKey: .interactionBox) { interactionBox = v }
        if let v = try? c.decodeIfPresent(ReachMode.self, forKey: .reachMode) { reachMode = v }
        if let v = try? c.decodeIfPresent(Bool.self, forKey: .mirrorCamera) { mirrorCamera = v }
    }
}
