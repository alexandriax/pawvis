import Foundation

/// How long a status notice stays on screen, and when it may come back.
///
/// The overlay re-renders on every camera frame, so "show this message" arrives
/// dozens of times a second and carries no notion of *when* it started. This
/// turns that stream into a lifecycle: a message appears when the text changes,
/// stays for `autoDismissAfter` seconds, and then gets out of the way. A
/// message the user dismissed is retired the same way — without that, a click
/// on the ✕ would be undone by the very next frame.
///
/// Pure logic: `now` comes from the caller (frame time), so the whole lifecycle
/// is testable without a clock.
public struct StatusPillPolicy: Equatable, Sendable {
    /// Notices are advice, not state — five seconds is long enough to read the
    /// wake-word hint and short enough not to live on the screen.
    public static let defaultAutoDismiss: TimeInterval = 5

    /// Seconds a message stays up. Zero or less keeps it up indefinitely.
    public var autoDismissAfter: TimeInterval

    private var current: String?
    private var shownAt: TimeInterval = 0
    private var retired = false

    public init(autoDismissAfter: TimeInterval = StatusPillPolicy.defaultAutoDismiss) {
        self.autoDismissAfter = autoDismissAfter
    }

    /// The message that should be on screen right now, or nil for nothing.
    ///
    /// Different text is always a new message: it shows immediately and starts
    /// its own countdown, so live feedback (a typing snippet) keeps the capsule
    /// alive while an unchanging hint fades out of the way.
    public mutating func display(_ message: String?, now: TimeInterval) -> String? {
        guard let message, !message.isEmpty else {
            reset()
            return nil
        }
        if message != current {
            current = message
            shownAt = now
            retired = false
        }
        guard !retired else { return nil }
        if autoDismissAfter > 0, now - shownAt >= autoDismissAfter {
            retired = true
            return nil
        }
        return message
    }

    /// Manual dismissal. The current message goes away now and stays away
    /// until different text arrives.
    public mutating func dismiss() {
        retired = true
    }

    /// Forget the current message entirely (voice stopped, tracking stopped),
    /// so the next one shows fresh with a full countdown.
    public mutating func reset() {
        current = nil
        shownAt = 0
        retired = false
    }
}
