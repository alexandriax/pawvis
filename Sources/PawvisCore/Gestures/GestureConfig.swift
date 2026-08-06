import Foundation

/// Which gesture arms/disarms voice dictation.
public enum DictationToggleGesture: String, Codable, CaseIterable, Sendable {
    /// One hand fully splayed (all five fingers extended and spread), held still.
    case oneHandSplayHold
    /// Both hands splayed open at once.
    case twoHandSplay
    /// Shaka (thumb + pinky out, middle fingers folded), held.
    case shakaHold
    /// No gesture — dictation is toggled from the menu bar only.
    case off

    public var displayName: String {
        switch self {
        case .oneHandSplayHold: return "One open hand (hold)"
        case .twoHandSplay: return "Two open hands"
        case .shakaHold: return "Shaka 🤙 (hold)"
        case .off: return "Menu bar only"
        }
    }
}

/// All tunables for the gesture engine. Defaults come from sporecaster's tuned
/// values where an equivalent exists (pinch thresholds, One Euro parameters,
/// stale-tracking reset), and from standard macOS behavior for click timing.
public struct GestureConfig: Codable, Equatable, Sendable {
    // MARK: Pinch (sporecaster: engage < 0.45, release > 0.68 of hand scale)
    public var pinchEngageRatio: Double = 0.45
    public var pinchReleaseRatio: Double = 0.68
    /// Which fingertip pinched against the thumb produces a right-click.
    public var rightClickFinger: Finger = .middle

    // MARK: Click timing
    /// Two clicks within this interval (and within `doubleClickSlop`) become a
    /// double-click (macOS default ballpark).
    public var doubleClickInterval: TimeInterval = 0.45
    /// Max cursor travel (screen-normalized) between clicks that still chains
    /// into a double-click.
    public var doubleClickSlop: Double = 0.02
    /// Cursor travel (screen-normalized) beyond which an engaged pinch starts
    /// dragging. Below this the cursor holds its position, so quick clicks
    /// don't smear into micro-drags.
    public var dragActivationDistance: Double = 0.008

    // MARK: Pointer
    public var pointerSource: PointerSource = .palmCenter
    public var smoothing: OneEuroFilter.Params = .cursor

    // MARK: Poses
    public var poseThresholds: PoseThresholds = PoseThresholds()
    /// A pose must persist this many consecutive frames before it takes effect
    /// (debounce for scroll/clutch entry).
    public var poseHoldFrames: Int = 3

    // MARK: Scroll (two-finger point pose + hand movement)
    public var scrollEnabled: Bool = true
    /// Scroll pixels emitted per unit of normalized hand travel.
    public var scrollGainPixels: Double = 1400
    /// Natural scrolling: hand up moves content up (like a trackpad).
    public var naturalScroll: Bool = true

    // MARK: Clutch (fist freezes the cursor, like lifting a mouse)
    public var clutchEnabled: Bool = true

    // MARK: Dictation toggle gesture
    public var dictationToggle: DictationToggleGesture = .oneHandSplayHold
    /// How long the toggle pose must be held before it fires.
    public var dictationHoldSeconds: TimeInterval = 0.75

    // MARK: Tracking robustness
    public var minHandConfidence: Double = 0.30
    public var minJointConfidence: Double = 0.25
    /// If tracking drops out mid-gesture, keep state alive this long before
    /// releasing any held buttons (sporecaster resets slots at 300 ms).
    public var trackingLossGrace: TimeInterval = 0.30

    // MARK: Mapping
    public var interactionBox: InteractionBox = .default
    public var mirrorCamera: Bool = true

    public init() {}

    public static let `default` = GestureConfig()

    var mapper: CoordinateMapper {
        CoordinateMapper(box: interactionBox, mirrored: mirrorCamera)
    }

    enum CodingKeys: String, CodingKey {
        case pinchEngageRatio, pinchReleaseRatio, rightClickFinger
        case doubleClickInterval, doubleClickSlop, dragActivationDistance
        case pointerSource, smoothing, poseThresholds, poseHoldFrames
        case scrollEnabled, scrollGainPixels, naturalScroll, clutchEnabled
        case dictationToggle, dictationHoldSeconds
        case minHandConfidence, minJointConfidence, trackingLossGrace
        case interactionBox, mirrorCamera
    }

    /// Field-tolerant decoding: unknown/missing/mistyped fields keep their
    /// defaults instead of failing the whole settings tree.
    public init(from decoder: Decoder) throws {
        self.init()
        let c = try decoder.container(keyedBy: CodingKeys.self)
        if let v = try? c.decodeIfPresent(Double.self, forKey: .pinchEngageRatio) { pinchEngageRatio = v }
        if let v = try? c.decodeIfPresent(Double.self, forKey: .pinchReleaseRatio) { pinchReleaseRatio = v }
        if let v = try? c.decodeIfPresent(Finger.self, forKey: .rightClickFinger) { rightClickFinger = v }
        if let v = try? c.decodeIfPresent(TimeInterval.self, forKey: .doubleClickInterval) { doubleClickInterval = v }
        if let v = try? c.decodeIfPresent(Double.self, forKey: .doubleClickSlop) { doubleClickSlop = v }
        if let v = try? c.decodeIfPresent(Double.self, forKey: .dragActivationDistance) { dragActivationDistance = v }
        if let v = try? c.decodeIfPresent(PointerSource.self, forKey: .pointerSource) { pointerSource = v }
        if let v = try? c.decodeIfPresent(OneEuroFilter.Params.self, forKey: .smoothing) { smoothing = v }
        if let v = try? c.decodeIfPresent(PoseThresholds.self, forKey: .poseThresholds) { poseThresholds = v }
        if let v = try? c.decodeIfPresent(Int.self, forKey: .poseHoldFrames) { poseHoldFrames = v }
        if let v = try? c.decodeIfPresent(Bool.self, forKey: .scrollEnabled) { scrollEnabled = v }
        if let v = try? c.decodeIfPresent(Double.self, forKey: .scrollGainPixels) { scrollGainPixels = v }
        if let v = try? c.decodeIfPresent(Bool.self, forKey: .naturalScroll) { naturalScroll = v }
        if let v = try? c.decodeIfPresent(Bool.self, forKey: .clutchEnabled) { clutchEnabled = v }
        if let v = try? c.decodeIfPresent(DictationToggleGesture.self, forKey: .dictationToggle) { dictationToggle = v }
        if let v = try? c.decodeIfPresent(TimeInterval.self, forKey: .dictationHoldSeconds) { dictationHoldSeconds = v }
        if let v = try? c.decodeIfPresent(Double.self, forKey: .minHandConfidence) { minHandConfidence = v }
        if let v = try? c.decodeIfPresent(Double.self, forKey: .minJointConfidence) { minJointConfidence = v }
        if let v = try? c.decodeIfPresent(TimeInterval.self, forKey: .trackingLossGrace) { trackingLossGrace = v }
        if let v = try? c.decodeIfPresent(InteractionBox.self, forKey: .interactionBox) { interactionBox = v }
        if let v = try? c.decodeIfPresent(Bool.self, forKey: .mirrorCamera) { mirrorCamera = v }
    }
}
