import Foundation

/// The idle frame-skip policy: with tracking on but nobody's hands in view,
/// most frames should skip Vision inference entirely — the camera keeps
/// running (reconfiguring an AVCaptureSession glitches; skipping inference is
/// free), but per-frame hand-pose detection drops to a probe rate until a
/// hand shows up again.
///
/// Pure and clock-free, like the rest of PawvisCore: every decision is a
/// function of the frame timestamps handed in, so the whole policy is
/// unit-testable. The app layer calls `shouldRunInference` at the camera tap
/// for every captured frame, and reports what Vision saw on the frames that
/// did run via `sawHands`.
///
/// Rules, in order:
///   - Exempt frames (a button held, a scroll active, the trainer open)
///     always process. Hands are obviously present while a button is down,
///     but the guard is explicit anyway: throttling mid-press must be
///     impossible by construction, not by inference.
///   - Hands in view (or none missing long enough): process every frame.
///   - No hands for `noHandsDelay` seconds: process one frame in `stride`
///     (~5 fps of the 30 fps feed) as the probe for a returning hand.
///   - Low Power Mode: the shorter `lowPowerNoHandsDelay` and the sparser
///     `lowPowerStride` (~2 fps) apply instead.
///   - The first processed frame containing a hand exits the throttle at
///     once — `sawHands(true)` clears it, so every following frame
///     processes again.
public struct IdleThrottle {
    public struct Config: Equatable {
        /// Seconds of no hands in view before the throttle engages.
        public var noHandsDelay: TimeInterval
        /// While throttled, process one captured frame in this many.
        /// At the camera's locked 30 fps, 6 ≈ 5 fps of inference.
        public var stride: Int
        /// The shorter no-hands delay while macOS Low Power Mode is on.
        public var lowPowerNoHandsDelay: TimeInterval
        /// The sparser stride while Low Power Mode is on (15 ≈ 2 fps).
        public var lowPowerStride: Int

        public init(noHandsDelay: TimeInterval = 10,
                    stride: Int = 6,
                    lowPowerNoHandsDelay: TimeInterval = 3,
                    lowPowerStride: Int = 15) {
            self.noHandsDelay = noHandsDelay
            self.stride = stride
            self.lowPowerNoHandsDelay = lowPowerNoHandsDelay
            self.lowPowerStride = lowPowerStride
        }

        public static let `default` = Config()
    }

    public var config: Config

    /// When hands stopped being seen (the first no-hands frame's timestamp);
    /// nil while hands are in view — or until the first frame reports.
    private var noHandsSince: TimeInterval?
    /// Captured frames skipped since the last processed one.
    private var skipped = 0
    /// Whether the policy is currently in its reduced-rate state.
    public private(set) var throttled = false

    public init(config: Config = .default) {
        self.config = config
    }

    /// Back to full rate with no history — for a fresh tracking session.
    public mutating func reset() {
        noHandsSince = nil
        skipped = 0
        throttled = false
    }

    /// Decide, at the camera tap, whether this captured frame runs Vision.
    /// Frames answered `false` are dropped before inference and never reach
    /// the gesture engine — whose only clock is the timestamps of frames it
    /// is actually given, so a gap in delivery is indistinguishable from a
    /// slow camera and disturbs nothing.
    public mutating func shouldRunInference(at time: TimeInterval,
                                            exempt: Bool,
                                            lowPower: Bool) -> Bool {
        if exempt {
            throttled = false
            skipped = 0
            return true
        }
        guard let since = noHandsSince else {
            throttled = false
            skipped = 0
            return true
        }
        let delay = lowPower ? config.lowPowerNoHandsDelay : config.noHandsDelay
        guard time - since >= delay else {
            throttled = false
            skipped = 0
            return true
        }
        throttled = true
        let stride = max(lowPower ? config.lowPowerStride : config.stride, 1)
        guard skipped >= stride - 1 else {
            skipped += 1
            return false
        }
        skipped = 0
        return true
    }

    /// Report what Vision saw on a frame that did run. A frame with a hand
    /// clears the throttle immediately; the first frame without one starts
    /// the no-hands clock.
    public mutating func sawHands(_ seen: Bool, at time: TimeInterval) {
        if seen {
            noHandsSince = nil
            throttled = false
            skipped = 0
        } else if noHandsSince == nil {
            noHandsSince = time
        }
    }
}
