import Foundation
import PawvisCore

/// The camera-queue face of the pure `IdleThrottle` policy: the state machine
/// under a lock, with the main-actor facts it needs (a press or scroll in
/// flight, the trainer open, Low Power Mode) mirrored in so the tap can
/// consult them off-main without touching the main actor.
///
/// The tap calls `shouldRunInference` for every captured frame and
/// `sawHands` after Vision on the frames that ran; `PawvisController`
/// pushes the exemption and power inputs whenever they change. Frames
/// answered `false` are dropped before inference and never reach the
/// gesture engine.
final class FrameThrottleBox: @unchecked Sendable {
    private let lock = NSLock()
    private var throttle = IdleThrottle()
    /// A button held or a scroll active: never throttle. Hands are obviously
    /// present then, but the guard is explicit, not inferred.
    private var interacting = false
    /// The trainer owns the stream while its window is open, and it wants
    /// every frame — a 5 fps preview would record 5 fps templates.
    private var training = false
    private var lowPower = false

    /// Called on the camera queue for every captured frame.
    func shouldRunInference(at time: TimeInterval) -> Bool {
        lock.withLock {
            throttle.shouldRunInference(at: time,
                                        exempt: interacting || training,
                                        lowPower: lowPower)
        }
    }

    /// Called on the camera queue after Vision ran on a processed frame.
    func sawHands(_ seen: Bool, at time: TimeInterval) {
        lock.withLock { throttle.sawHands(seen, at: time) }
    }

    func setInteracting(_ value: Bool) {
        lock.withLock { interacting = value }
    }

    func setTraining(_ value: Bool) {
        lock.withLock { training = value }
    }

    func setLowPower(_ value: Bool) {
        lock.withLock { lowPower = value }
    }

    /// A fresh tracking session (start, or resume from the lock screen)
    /// begins at full rate.
    func reset() {
        lock.withLock { throttle.reset() }
    }
}
