import Foundation

/// Tunables for the (deliberately minimal) gesture engine: open hand moves,
/// closed hand clicks/drags. Smoothing and slot-tracking defaults come from
/// sporecaster's tuned values.
public struct GestureConfig: Codable, Equatable, Sendable {
    // MARK: Grab (hand-close) detection
    /// Hand counts as closed when openness (0 = fist, ~1 = open palm) falls
    /// below this. Lower = must squeeze tighter to click.
    public var grabCloseThreshold: Double = 0.18
    /// Hand counts as open again above this (hysteresis band between the two
    /// prevents flutter at the boundary).
    public var grabOpenThreshold: Double = 0.38
    /// Consecutive frames below the close threshold before the click fires
    /// (absorbs single-frame tracking blips).
    public var grabDebounceFrames: Int = 2

    // MARK: Click timing
    /// Two clicks within this interval (and within `doubleClickSlop`) become a
    /// double-click (macOS default ballpark).
    public var doubleClickInterval: TimeInterval = 0.45
    /// Max cursor travel (screen-normalized) between clicks that still chains
    /// into a double-click.
    public var doubleClickSlop: Double = 0.025
    /// Cursor travel (screen-normalized) beyond which a grab starts dragging.
    /// Below this the cursor holds still, so quick clicks don't micro-drag.
    public var dragActivationDistance: Double = 0.010

    // MARK: Pointer
    public var smoothing: OneEuroFilter.Params = .cursor

    // MARK: Pose classification thresholds (used by hand features)
    public var poseThresholds: PoseThresholds = PoseThresholds()

    // MARK: Tracking robustness
    public var minHandConfidence: Double = 0.30
    public var minJointConfidence: Double = 0.25
    /// If tracking drops out mid-grab, keep state alive this long before
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
        case grabCloseThreshold, grabOpenThreshold, grabDebounceFrames
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
        if let v = try? c.decodeIfPresent(Double.self, forKey: .grabCloseThreshold) { grabCloseThreshold = v }
        if let v = try? c.decodeIfPresent(Double.self, forKey: .grabOpenThreshold) { grabOpenThreshold = v }
        if let v = try? c.decodeIfPresent(Int.self, forKey: .grabDebounceFrames) { grabDebounceFrames = v }
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
