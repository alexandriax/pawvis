import Foundation

/// Decides what a finalized utterance is, with a short capture window that
/// stitches a bare wake word to the command that follows it.
///
/// The speech engine's fast segmentation regularly finalizes "Pawvis" on the
/// natural pause before the command, then delivers "open Safari" as a
/// separate, wake-less final. Treating each final independently silently
/// drops both halves — the original beta's "command disappears into nowhere"
/// bug. A bare wake word therefore *arms* the gate: for a few seconds the
/// next final is taken as the command, no wake word needed.
///
/// Pure and clock-free (time comes in as a parameter) so the stitching rules
/// are unit-testable.
public struct UtteranceGate: Sendable {
    public enum Decision: Equatable, Sendable {
        /// Dispatch this wake-stripped command.
        case command(String)
        /// Bare wake word: the capture window is now open.
        case armed
        /// No wake word and no open window — ambient speech.
        case ignored
    }

    /// How long a bare wake word keeps listening for its command.
    public let windowSeconds: TimeInterval

    private var armedUntil: TimeInterval?

    public init(windowSeconds: TimeInterval = 8) {
        self.windowSeconds = windowSeconds
    }

    /// `remainder` is the parser's wake-stripped remainder (nil when the
    /// utterance didn't start with the wake word).
    public mutating func decide(
        remainder: String?, transcript: String, now: TimeInterval
    ) -> Decision {
        if let remainder {
            let cleaned = remainder.trimmingCharacters(in: .whitespacesAndNewlines)
            guard cleaned.isEmpty else {
                armedUntil = nil
                return .command(cleaned)
            }
            armedUntil = now + windowSeconds
            return .armed
        }
        if let until = armedUntil, now <= until {
            armedUntil = nil
            let cleaned = transcript.trimmingCharacters(in: .whitespacesAndNewlines)
            return cleaned.isEmpty ? .ignored : .command(cleaned)
        }
        armedUntil = nil
        return .ignored
    }

    public func isArmed(now: TimeInterval) -> Bool {
        guard let until = armedUntil else { return false }
        return now <= until
    }

    public mutating func disarm() {
        armedUntil = nil
    }
}
