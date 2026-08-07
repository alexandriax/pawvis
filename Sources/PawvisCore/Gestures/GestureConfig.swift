import Foundation

/// Tunables for the (deliberately minimal) gesture engine: the thumb–index
/// midpoint moves the cursor, pinching clicks/drags. Pinch thresholds,
/// smoothing, and slot-tracking defaults come from sporecaster's tuned values.
public struct GestureConfig: Codable, Equatable, Sendable {
    // MARK: Pinch detection
    /// Pinch engages when distance(thumbTip, indexTip) / handScale drops below
    /// this. Lower = the tips must come closer before a click fires.
    public var pinchEngageRatio: Double = 0.45
    /// Pinch releases above this ratio. The gap between the two is the
    /// hysteresis band, and it is the primary anti-flutter mechanism.
    public var pinchReleaseRatio: Double = 0.68
    /// Consecutive frames past a threshold before the transition fires, in
    /// *both* directions. sporecaster needed none on MediaPipe; Vision's
    /// landmarks spike often enough that single-frame noise must not click.
    public var pinchDebounceFrames: Int = 2

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
    public var interactionBox: InteractionBox = .default
    public var mirrorCamera: Bool = true

    public init() {}

    public static let `default` = GestureConfig()

    var mapper: CoordinateMapper {
        CoordinateMapper(box: interactionBox, mirrored: mirrorCamera)
    }

    enum CodingKeys: String, CodingKey {
        case pinchEngageRatio, pinchReleaseRatio, pinchDebounceFrames
        case doubleClickInterval, doubleClickSlop, dragActivationDistance
        case smoothing, poseThresholds
        case minHandConfidence, minJointConfidence, trackingLossGrace
        case interactionBox, mirrorCamera
    }

    /// Field-tolerant decoding: unknown/missing/mistyped fields (including
    /// keys from retired gestures) keep defaults instead of failing the tree.
    public init(from decoder: Decoder) throws {
        self.init()
        let c = try decoder.container(keyedBy: CodingKeys.self)
        if let v = try? c.decodeIfPresent(Double.self, forKey: .pinchEngageRatio) { pinchEngageRatio = v }
        if let v = try? c.decodeIfPresent(Double.self, forKey: .pinchReleaseRatio) { pinchReleaseRatio = v }
        if let v = try? c.decodeIfPresent(Int.self, forKey: .pinchDebounceFrames) { pinchDebounceFrames = v }
        if let v = try? c.decodeIfPresent(TimeInterval.self, forKey: .doubleClickInterval) { doubleClickInterval = v }
        if let v = try? c.decodeIfPresent(Double.self, forKey: .doubleClickSlop) { doubleClickSlop = v }
        if let v = try? c.decodeIfPresent(Double.self, forKey: .dragActivationDistance) { dragActivationDistance = v }
        if let v = try? c.decodeIfPresent(OneEuroFilter.Params.self, forKey: .smoothing) { smoothing = v }
        if let v = try? c.decodeIfPresent(PoseThresholds.self, forKey: .poseThresholds) { poseThresholds = v }
        if let v = try? c.decodeIfPresent(Double.self, forKey: .minHandConfidence) { minHandConfidence = v }
        if let v = try? c.decodeIfPresent(Double.self, forKey: .minJointConfidence) { minJointConfidence = v }
        if let v = try? c.decodeIfPresent(TimeInterval.self, forKey: .trackingLossGrace) { trackingLossGrace = v }
        if let v = try? c.decodeIfPresent(InteractionBox.self, forKey: .interactionBox) { interactionBox = v }
        if let v = try? c.decodeIfPresent(Bool.self, forKey: .mirrorCamera) { mirrorCamera = v }
    }
}
