import Foundation

/// The look-to-control policy: with the attention feature on, mouse and
/// gesture actions run only while the user is facing the screen. The camera
/// already watching their hands also sees their face; when the head turns
/// away — or leaves the frame — for long enough, the gate closes and frames
/// stop reaching the gesture engine until they look back.
///
/// Pure and clock-free, like `IdleThrottle`: every decision is a function of
/// the observation timestamps handed in, so the whole policy is
/// unit-testable. The app layer feeds it head-pose observations sampled from
/// Vision's face detector and reads back one bool.
///
/// Rules, in order:
///   - Disabled: always attentive. The gate must be inert unless asked for.
///   - A press or scroll in flight holds the gate open, whatever the face is
///     doing — closing mid-press would drop a synthetic mouseUp wherever the
///     cursor happens to be, the one failure this feature must not add. The
///     away clock starts fresh once the interaction ends.
///   - Facing means: a face is in frame and both |yaw| and |pitch| are inside
///     `maxOffAngle`. No face at all is not-facing — an operator the camera
///     cannot see is exactly who must not be moving the cursor.
///   - Closing takes `awayDelay` seconds of *sustained* not-facing evidence:
///     a glance at the keyboard or a notification must cost nothing.
///   - Reopening takes `returnDelay` seconds of sustained facing, and the
///     head must come back `returnMargin` inside the angle limit — time and
///     angle hysteresis together, so a head hovering at the threshold cannot
///     flap the gate.
public struct AttentionGate: Equatable, Sendable {
    public struct Config: Equatable, Sendable {
        public var enabled: Bool
        /// Largest |yaw| or |pitch| (radians) that still counts as facing
        /// the screen.
        public var maxOffAngle: Double
        /// How far back inside `maxOffAngle` the head must come to count as
        /// facing again once the gate has closed (angle hysteresis).
        public var returnMargin: Double
        /// Seconds of sustained not-facing before the gate closes.
        public var awayDelay: TimeInterval
        /// Seconds of sustained facing before it reopens.
        public var returnDelay: TimeInterval

        public init(enabled: Bool = false,
                    maxOffAngle: Double = 32.5 * .pi / 180,
                    returnMargin: Double = 5 * .pi / 180,
                    awayDelay: TimeInterval = 1.0,
                    returnDelay: TimeInterval = 0.25) {
            self.enabled = enabled
            self.maxOffAngle = maxOffAngle
            self.returnMargin = returnMargin
            self.awayDelay = awayDelay
            self.returnDelay = returnDelay
        }
    }

    /// One sampled head pose. Angles are radians off the camera axis; nil
    /// means the detector did not report that axis, which counts as facing
    /// on it — a missing number must not read as a turned head.
    public struct Observation: Equatable, Sendable {
        public var faceSeen: Bool
        public var yaw: Double?
        public var pitch: Double?

        public init(faceSeen: Bool, yaw: Double? = nil, pitch: Double? = nil) {
            self.faceSeen = faceSeen
            self.yaw = yaw
            self.pitch = pitch
        }

        /// Nobody in frame.
        public static let noFace = Observation(faceSeen: false)
    }

    public private(set) var config: Config
    /// The verdict: false while the gate is holding control closed.
    public private(set) var attentive = true

    /// When continuous not-facing evidence started; nil while facing.
    private var awaySince: TimeInterval?
    /// When continuous facing evidence started while the gate is closed.
    private var facingSince: TimeInterval?

    public init(config: Config = Config()) {
        self.config = config
    }

    /// Swap the tuning in. Turning the feature off (or on) starts clean:
    /// stale away evidence from before the flip must not close — or hold
    /// closed — a gate the user just reconfigured.
    public mutating func setConfig(_ newConfig: Config) {
        let enabledFlipped = newConfig.enabled != config.enabled
        config = newConfig
        if enabledFlipped { reset() }
    }

    /// Back to attentive with no history — for a fresh tracking session.
    public mutating func reset() {
        attentive = true
        awaySince = nil
        facingSince = nil
    }

    /// Feed one sampled observation and read the verdict.
    public mutating func assess(_ observation: Observation,
                                interacting: Bool,
                                at time: TimeInterval) -> Bool {
        guard config.enabled else { return true }
        if interacting {
            // Held button or active scroll: the gate holds, and the away
            // clock restarts once the interaction ends — evidence gathered
            // mid-drag must not close the gate the instant the button lifts.
            awaySince = nil
            return attentive
        }
        if attentive {
            if isFacing(observation) {
                awaySince = nil
            } else {
                let since = awaySince ?? time
                awaySince = since
                if time - since >= config.awayDelay {
                    attentive = false
                    awaySince = nil
                    facingSince = nil
                }
            }
        } else {
            if isFacing(observation) {
                let since = facingSince ?? time
                facingSince = since
                if time - since >= config.returnDelay {
                    attentive = true
                    awaySince = nil
                    facingSince = nil
                }
            } else {
                facingSince = nil
            }
        }
        return attentive
    }

    /// Whether this observation reads as a face turned toward the screen.
    /// The closed gate demands `returnMargin` more than the open one keeps —
    /// the angle half of the anti-flap hysteresis.
    private func isFacing(_ observation: Observation) -> Bool {
        guard observation.faceSeen else { return false }
        let limit = attentive ? config.maxOffAngle
                              : max(config.maxOffAngle - config.returnMargin, 0)
        if let yaw = observation.yaw, abs(yaw) > limit { return false }
        if let pitch = observation.pitch, abs(pitch) > limit { return false }
        return true
    }
}
