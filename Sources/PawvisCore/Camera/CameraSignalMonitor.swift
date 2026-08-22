import Foundation

/// Decides when the camera feed has gone dark: frames are arriving, but they
/// carry no image (a near-black picture). Pure and clock-free like the rest
/// of PawvisCore — every verdict is a function of the luminance samples and
/// timestamps handed in, so it is unit-testable.
///
/// This exists because a black feed is a silent dead end. The stall watchdog
/// only asks whether frames arrive, and they do; the attention gate finds no
/// face in black and reports "facing away"; the engine finds no hand and
/// reports "no hands in view". All three are technically true and together
/// useless: the real cause — the camera is not pointed at anything, most
/// often an iPhone Continuity Camera whose rear lens faces the desk — never
/// reaches the user. The monitor names it so the UI can.
///
/// The rules:
///   - **Dark is sustained, not instantaneous.** A single black frame (a
///     blink of exposure, a hand covering the lens for a moment) is not a
///     dark feed; only `darkDelay` of unbroken darkness is. This keeps the
///     warning off during the ordinary dark frames at session start while
///     the camera's exposure settles.
///   - **Recovery is instantaneous.** The first frame with any real image
///     clears it — the moment the lens sees the user, the warning is gone,
///     with no lag to sit through.
///   - **A feed that starts dark still trips.** The clock runs from the
///     first sample when no bright frame has ever been seen, which is the
///     common case: the user picks the iPhone and it was face-down the
///     whole time.
///   - **An unreadable frame holds the verdict.** A luminance of less than
///     zero means the buffer could not be measured; like every missing
///     signal in this codebase it holds state rather than flipping it.
public struct CameraSignalMonitor: Sendable {
    public struct Config: Equatable, Sendable {
        /// Mean luminance (0…255) below which a frame counts as black. Real
        /// scenes, even dim ones, sit far above this; a covered or
        /// unpointed lens reads ~2.
        public var darkLuma: Double
        /// How long the feed must stay below `darkLuma` before it is called
        /// dark. Long enough to outlast exposure warm-up, short enough that
        /// the user is not left guessing.
        public var darkDelay: TimeInterval

        public init(darkLuma: Double = 8, darkDelay: TimeInterval = 2.0) {
            self.darkLuma = darkLuma
            self.darkDelay = darkDelay
        }
    }

    public var config: Config
    private var lastBrightTime: TimeInterval?
    private var firstSampleTime: TimeInterval?
    private(set) public var isDark = false

    public init(config: Config = Config()) {
        self.config = config
    }

    /// Feed one frame's mean luminance. Returns whether the feed is dark now.
    /// `luma` below zero marks an unmeasurable frame and holds the verdict.
    @discardableResult
    public mutating func sample(luma: Double, at time: TimeInterval) -> Bool {
        guard luma >= 0 else { return isDark }
        if firstSampleTime == nil { firstSampleTime = time }
        if luma >= config.darkLuma {
            lastBrightTime = time
            isDark = false
            return false
        }
        let reference = lastBrightTime ?? firstSampleTime ?? time
        isDark = (time - reference) >= config.darkDelay
        return isDark
    }

    /// Forget all history (a new session, a device switch): the next dark
    /// run is timed from scratch, and the feed is presumed fine until then.
    public mutating func reset() {
        lastBrightTime = nil
        firstSampleTime = nil
        isDark = false
    }
}
