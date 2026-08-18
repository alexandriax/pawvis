import Foundation

/// Decides what a finalized utterance is, with a short capture window that
/// stitches a bare wake word to the command that follows it.
///
/// The speech engine's fast segmentation regularly finalizes "Pawvis" on the
/// natural pause before the command, then delivers "open Safari" as a
/// separate, wake-less final. Treating each final independently silently
/// drops both halves — the original beta's "command disappears into nowhere"
/// bug. A bare wake word therefore *arms* the gate: for a few seconds the
/// next final is taken as the command, no wake word needed. With strict wake
/// on (the agent hand-off is live) the capture stops being verbatim — see
/// `decide(strictCommandBar:)`.
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
    ///
    /// `strictCommandBar` is the strict-wake policy for the armed window
    /// (the app passes it while the agent hand-off is live): instead of
    /// taking the next final verbatim, a wake-less capture is accepted only
    /// when the bar says it parses as a deterministic command. A final that
    /// carries the wake word never consults the bar — it has a remainder
    /// and dispatches on the wake word itself, free-form included. The
    /// window stays one-shot either way: a refused capture consumes it,
    /// exactly like any other final. Nil keeps the original verbatim
    /// capture. The bar is a parameter, not a stored parser, so the gate
    /// stays pure and clock-free.
    public mutating func decide(
        remainder: String?, transcript: String, now: TimeInterval,
        strictCommandBar: ((String) -> Bool)? = nil
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
            guard !cleaned.isEmpty else { return .ignored }
            if let strictCommandBar, !strictCommandBar(cleaned) {
                return .ignored
            }
            return .command(cleaned)
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
