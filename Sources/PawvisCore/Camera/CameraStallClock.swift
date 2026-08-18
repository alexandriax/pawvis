import Foundation

/// The camera-liveness policy behind the frame-stall watchdog: no captured
/// frames for `stallSeconds` (outside a warm-up grace) means the camera is
/// gone.
///
/// Pure and clock-free, like the rest of PawvisCore: every verdict is a
/// function of the timestamps handed in, so the rules are unit-testable.
///
/// The rules exist because each one was once violated:
///   - **Evidence is captured frames, not processed frames.** The idle
///     throttle drops most frames before inference while no hands are in
///     view; a skipped frame still proves the camera is delivering. Stamping
///     liveness after the throttle gate made the watchdog convict a live
///     camera whenever the throttled cadence (stride ÷ delivery rate)
///     approached the stall window — a false failure the very next processed
///     frame cleared, flapping "camera stopped" / "camera is back" forever.
///   - **Arming is synchronous and re-stamps the evidence.** Every resume
///     path (unlock, wake, training hand-back, device switch) must call
///     `arm` the moment it flips its pause flag or restarts the camera. The
///     asynchronous running-state callback re-arms too, but it arrives from
///     the camera queue after `startRunning` — later than the next watchdog
///     tick, which would otherwise convict on a timestamp from before the
///     pause.
///   - **An un-armed clock accuses nobody.** Until the pipeline explicitly
///     arms it, `isStalled` is false: a watchdog that starts up mid-verdict
///     would fail a camera that was never asked to run.
public struct CameraStallClock: Sendable {
    /// No frames for this long (past any grace) means the camera is gone.
    /// Comfortably above any real inter-frame gap at the locked 30 fps, and
    /// short enough that a stuck drag doesn't wander far.
    public var stallSeconds: TimeInterval

    /// When the camera last proved it was alive: the latest captured frame,
    /// or the latest `arm` (a restart's "count from now").
    private var lastEvidenceAt: TimeInterval = 0
    /// No verdict before this deadline — warm-up isn't failure. `.infinity`
    /// until the first `arm`, so an un-armed clock never convicts.
    private var graceUntil: TimeInterval = .infinity

    public init(stallSeconds: TimeInterval = 2) {
        self.stallSeconds = stallSeconds
    }

    /// Restart the no-frames countdown, with a warm-up grace during which no
    /// verdict is reached. Also stamps the evidence clock: a camera told to
    /// (re)start owes its first frame `stallSeconds` from *now*, not from
    /// whenever the last frame before the pause arrived.
    public mutating func arm(at now: TimeInterval, grace: TimeInterval) {
        lastEvidenceAt = now
        graceUntil = now + grace
    }

    /// A captured frame arrived at the tap — before, and regardless of, the
    /// idle throttle's inference verdict.
    public mutating func noteFrame(at time: TimeInterval) {
        lastEvidenceAt = time
    }

    /// The watchdog's question: has the camera stopped delivering?
    public func isStalled(at now: TimeInterval) -> Bool {
        now >= graceUntil && now - lastEvidenceAt >= stallSeconds
    }
}
