import Foundation

/// A single tracked hand: up to 21 landmarks in normalized screen-oriented
/// coordinates (origin top-left, +y down, already mirrored so that moving your
/// hand to your right moves the point to the right on screen).
public struct Hand: Sendable {
    public enum Chirality: String, Codable, Sendable {
        case left, right, unknown
    }

    public var chirality: Chirality

    /// Overall tracking confidence in [0, 1].
    public var confidence: Double

    private var points: [Vec2?]
    private var jointConfidences: [Double]

    public init(chirality: Chirality = .unknown, confidence: Double = 1.0) {
        self.chirality = chirality
        self.confidence = confidence
        self.points = Array(repeating: nil, count: HandJoint.allCases.count)
        self.jointConfidences = Array(repeating: 0, count: HandJoint.allCases.count)
    }

    /// Convenience initializer from a dictionary of joints (used heavily in tests).
    public init(
        chirality: Chirality = .unknown,
        confidence: Double = 1.0,
        joints: [HandJoint: Vec2],
        jointConfidence: Double = 1.0
    ) {
        self.init(chirality: chirality, confidence: confidence)
        for (joint, point) in joints {
            setPoint(point, for: joint, confidence: jointConfidence)
        }
    }

    public subscript(joint: HandJoint) -> Vec2? {
        points[joint.rawValue]
    }

    public mutating func setPoint(_ point: Vec2, for joint: HandJoint, confidence: Double = 1.0) {
        points[joint.rawValue] = point
        jointConfidences[joint.rawValue] = confidence
    }

    public func confidence(for joint: HandJoint) -> Double {
        jointConfidences[joint.rawValue]
    }

    /// Joints present with at least the given confidence.
    public func point(for joint: HandJoint, minConfidence: Double) -> Vec2? {
        guard jointConfidences[joint.rawValue] >= minConfidence else { return nil }
        return points[joint.rawValue]
    }

    /// All available fingertip positions (thumb + four fingers), for overlay rendering.
    public var fingertips: [(joint: HandJoint, point: Vec2)] {
        let tips: [HandJoint] = [.thumbTip, .indexTip, .middleTip, .ringTip, .littleTip]
        return tips.compactMap { joint in
            self[joint].map { (joint, $0) }
        }
    }

    /// Apply a transform to every landmark (used to map camera space → screen space).
    public func mapPoints(_ transform: (Vec2) -> Vec2) -> Hand {
        var copy = self
        for joint in HandJoint.allCases {
            if let p = copy.points[joint.rawValue] {
                copy.points[joint.rawValue] = transform(p)
            }
        }
        return copy
    }
}

/// One camera frame's worth of tracking output, fed to the gesture engine.
public struct HandFrame: Sendable {
    /// Monotonic timestamp in seconds. Injected (never read from a clock) so the
    /// engine is fully deterministic and testable.
    public var time: TimeInterval
    public var hands: [Hand]

    public init(time: TimeInterval, hands: [Hand]) {
        self.time = time
        self.hands = hands
    }
}
