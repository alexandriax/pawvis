import Foundation

/// Which hand shape presses the left button. All four are ratio gestures
/// driven by the same sensitivity slider (see `ClickGesture.engageFactor`), so
/// switching modes keeps the user's tuning.
/// Declaration order is the picker order — best-performing modes first (per
/// real-world testing: the mouse tap keeps the whole hand open and visible,
/// so tracking never has to guess at overlapping fingers).
public enum ClickGesture: String, Codable, CaseIterable, Sendable {
    case indexTap         // open hand; dip the index finger like a mouse button (default)
    case wholeHandPinch   // all fingertips gathered onto the thumb
    case thumbCurl        // open "high-five" hand; tucking the thumb clicks
    case pinch            // thumb + index tip

    public var displayName: String {
        switch self {
        case .indexTap: return "Mouse tap (index finger)"
        case .wholeHandPinch: return "Whole-hand pinch"
        case .thumbCurl: return "High-five, thumb to click"
        case .pinch: return "Pinch (thumb + index)"
        }
    }

    /// Scale for any *finger dip* ratio: the tip→knuckle differential idles
    /// near 1.0 and drops to ~0.5 when the finger taps down (0.45 × 1.5 =
    /// 0.675 at the default slider position). Shared by the index-tap left
    /// button and by the right-click dip in every mode that has one, so both
    /// buttons stay on the same sensitivity slider.
    static let dipEngageFactor = 1.5

    /// Scales the sensitivity slider into each mode's reachable range: the ring
    /// and little fingers physically can't close on the thumb as tightly as the
    /// index can; a tucked thumb sits ~0.3–0.35 of hand scale from the index
    /// knuckle; and the index-tap differential is a dip (see `dipEngageFactor`).
    var engageFactor: Double {
        switch self {
        case .indexTap: return Self.dipEngageFactor
        case .wholeHandPinch: return 1.25
        case .thumbCurl: return 0.8
        case .pinch: return 1.0
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

/// Tunables for the (deliberately minimal) gesture engine: a pointer landmark
/// moves the cursor and `clickGesture` clicks/drags. Pinch thresholds,
/// smoothing, and slot-tracking defaults come from sporecaster's tuned values.
public struct GestureConfig: Codable, Equatable, Sendable {
    // MARK: Pinch detection
    /// Which hand shape clicks. The rest of the pinch tuning applies to all
    /// modes.
    public var clickGesture: ClickGesture = .indexTap
    /// Pinch engages when distance(thumbTip, indexTip) / handScale drops below
    /// this. Lower = the tips must come closer before a click fires.
    public var pinchEngageRatio: Double = 0.45
    /// How much farther apart than the engage distance the tips must move to
    /// release. Deliberately small so engaging and releasing feel like the
    /// same distance — a fixed release ratio meant tight sensitivity settings
    /// needed an absurdly wide splay to let go. Just enough band remains to
    /// stop boundary chatter; smoothing and the debounce handle the rest.
    public var pinchReleaseHysteresis: Double = 0.08
    /// The release threshold tracks the engage threshold (and therefore the
    /// sensitivity slider).
    public var pinchReleaseRatio: Double { pinchEngageRatio + pinchReleaseHysteresis }
    /// What the engine actually compares the current mode's ratio against:
    /// the slider scaled into that mode's range. Identical to
    /// `pinchEngageRatio` in `.pinch` mode.
    public var engageRatio: Double { pinchEngageRatio * clickGesture.engageFactor }
    /// Release tracks engage by the same hysteresis in every mode.
    public var releaseRatio: Double { engageRatio + pinchReleaseHysteresis }
    /// Consecutive frames past a threshold before the transition fires, in
    /// *both* directions. sporecaster needed none on MediaPipe; Vision's
    /// landmarks spike often enough that single-frame noise must not click.
    public var pinchDebounceFrames: Int = 2

    // MARK: Right click
    /// Dip a second finger to press the right button. Only the two dip-capable
    /// modes offer it: `.indexTap` and `.thumbCurl` leave the hand open, so a
    /// lone finger dropping is unambiguous. The gathering modes (`.pinch`,
    /// `.wholeHandPinch`) pull every finger toward the thumb, which no dip
    /// differential can read apart from the click itself.
    public var rightClickEnabled: Bool = true
    /// Whose dip right-clicks. The little finger is the one no click mode
    /// uses, and dropping it barely disturbs the rest of the hand — but it
    /// can never be the finger already pressing the left button, so in
    /// `.indexTap` mode setting this to `.index` simply turns right-click off.
    public var rightClickFinger: Finger = .little
    /// Right-click always thresholds a finger dip, whatever the left button is
    /// doing, so it scales the sensitivity slider by the dip factor in every
    /// mode (in `.thumbCurl` the two buttons therefore use different factors).
    public var rightEngageRatio: Double { pinchEngageRatio * ClickGesture.dipEngageFactor }
    /// Release tracks engage by the same hysteresis as the left button.
    public var rightReleaseRatio: Double { rightEngageRatio + pinchReleaseHysteresis }

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
        case clickGesture
        case pinchEngageRatio, pinchReleaseHysteresis, pinchDebounceFrames
        case rightClickEnabled, rightClickFinger
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
        if let v = try? c.decodeIfPresent(ClickGesture.self, forKey: .clickGesture) { clickGesture = v }
        if let v = try? c.decodeIfPresent(Double.self, forKey: .pinchEngageRatio) { pinchEngageRatio = v }
        if let v = try? c.decodeIfPresent(Double.self, forKey: .pinchReleaseHysteresis) { pinchReleaseHysteresis = v }
        if let v = try? c.decodeIfPresent(Int.self, forKey: .pinchDebounceFrames) { pinchDebounceFrames = v }
        if let v = try? c.decodeIfPresent(Bool.self, forKey: .rightClickEnabled) { rightClickEnabled = v }
        if let v = try? c.decodeIfPresent(Finger.self, forKey: .rightClickFinger) { rightClickFinger = v }
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
