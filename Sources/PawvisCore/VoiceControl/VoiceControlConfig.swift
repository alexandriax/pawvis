import Foundation

/// Settings for voice control (beta). Speech recognition is always Apple's
/// on-device stack — nothing leaves the Mac.
public struct VoiceControlConfig: Codable, Equatable, Sendable {
    /// Master switch. Beta: off until the user turns it on.
    public var enabled: Bool = false
    /// ISO-639-1; empty = auto-detect.
    public var language: String = ""
    /// Say this word first to address Pawvis ("Pawvis, go to github.com").
    /// Required for every command — speech without it is ignored.
    public var wakeWord: String = "Pawvis"
    /// Alternate spellings the recognizer may produce for the wake word.
    /// Matching is also fuzzy (edit distance 1), so this list only needs the
    /// truly different mishearings. Deliberately absent: "jarvis" — a stock
    /// movie wake word shipped here once, which made any TV audio saying
    /// "Jarvis, …" a full-trust accept. Users who want it can add it back.
    public var wakeWordAliases: [String] = ["pawviz", "pavis", "purvis", "pervis"]
    /// Map commands the grammar doesn't recognize to intents with the
    /// on-device Apple Intelligence model, and ground screen-referencing
    /// commands ("click sign in") against what's around the pointer.
    /// macOS 26+ with Apple Intelligence.
    public var visualContextEnabled: Bool = true
    /// Show what voice control is hearing in a capsule at the top of the
    /// screen (only once an utterance starts with the wake word).
    public var transcriptOverlayEnabled: Bool = true
    /// Seconds the capsule stays up after an utterance completes.
    public var transcriptOverlaySeconds: Double = 3.0
    /// Keep the capsule up until it's clicked instead of auto-hiding.
    public var transcriptOverlayManualDismiss: Bool = false
    /// Play a short system sound when a command is accepted and another when
    /// it finishes (success and failure sound different). Off by default.
    public var audibleCues: Bool = false
    /// Hand free-form commands to an installed agent CLI instead of the
    /// on-device intent mapper: "" (off), "claude" (Claude Code), or
    /// "codex" (Codex CLI). The agent runs headless with permission checks
    /// bypassed — strictly opt-in.
    public var agentExecutor: String = ""
    /// Read an agent-bound command back and wait for a spoken yes/no before
    /// anything is sent. ON by default: the agent runs without its own
    /// permission prompts, so this read-back is the last moment a misheard
    /// command can be stopped.
    public var agentConfirm: Bool = true
    /// Seconds before a background agent run is abandoned.
    public var agentTimeoutSeconds: Double = 120
    /// Quiet time (legacy SFSpeechRecognizer path only) before an utterance is
    /// considered done.
    public var vadSilenceMs: Int = 500
    /// Tightened wake acceptance for high-stakes handlers. The app layer sets
    /// this whenever the agent hand-off is active (an accepted utterance there
    /// is arbitrary execution); the core just takes the flag. With it on, the
    /// glued-speech tier is disabled outright, and the utterance gate's
    /// capture window stops taking the next final verbatim (the app threads
    /// the same flag into `UtteranceGate.decide`). Transient by design —
    /// never encoded, and ignored by the decoder.
    public var strictWake: Bool = false

    public init() {}

    enum CodingKeys: String, CodingKey {
        case enabled, language, wakeWord, wakeWordAliases
        case visualContextEnabled, vadSilenceMs
        case transcriptOverlayEnabled, transcriptOverlaySeconds, transcriptOverlayManualDismiss
        case audibleCues
        case agentExecutor, agentConfirm, agentTimeoutSeconds
    }

    /// Field-tolerant decoding, matching GestureConfig's behavior. Keys from
    /// earlier builds (stop phrases, typing pause, delta typing) are simply
    /// ignored — one-shot commands made them obsolete.
    ///
    /// Most numeric fields here are app-layer UI timers, not engine state
    /// machines, and already fail safe at their point of use (`vadSilenceMs`
    /// is floored by `SpeechEngine`; `transcriptOverlaySeconds` only changes
    /// how long a capsule stays visible), so they're left unclamped —
    /// they're the "benign cosmetic numbers" this pattern deliberately
    /// leaves alone. `agentTimeoutSeconds` is the exception: it reaches
    /// `AgentSessionManager.run`, which does `Int(max(30, timeout))` — a
    /// huge decoded value (a corrupted or hand-edited file has no reason not
    /// to contain one) overflows that `Double`-to-`Int` conversion and traps,
    /// crashing the app the moment a voice command runs an agent. Clamping
    /// here closes that.
    public init(from decoder: Decoder) throws {
        self.init()
        let c = try decoder.container(keyedBy: CodingKeys.self)
        if let v = try? c.decodeIfPresent(Bool.self, forKey: .enabled) { enabled = v }
        if let v = try? c.decodeIfPresent(String.self, forKey: .language) { language = v }
        if let v = try? c.decodeIfPresent(String.self, forKey: .wakeWord) { wakeWord = v }
        if let v = try? c.decodeIfPresent([String].self, forKey: .wakeWordAliases) { wakeWordAliases = v }
        if let v = try? c.decodeIfPresent(Bool.self, forKey: .visualContextEnabled) { visualContextEnabled = v }
        if let v = try? c.decodeIfPresent(Int.self, forKey: .vadSilenceMs) { vadSilenceMs = v }
        if let v = try? c.decodeIfPresent(Bool.self, forKey: .transcriptOverlayEnabled) { transcriptOverlayEnabled = v }
        if let v = try? c.decodeIfPresent(Double.self, forKey: .transcriptOverlaySeconds) { transcriptOverlaySeconds = v }
        if let v = try? c.decodeIfPresent(Bool.self, forKey: .transcriptOverlayManualDismiss) { transcriptOverlayManualDismiss = v }
        if let v = try? c.decodeIfPresent(Bool.self, forKey: .audibleCues) { audibleCues = v }
        if let v = try? c.decodeIfPresent(String.self, forKey: .agentExecutor) { agentExecutor = v }
        if let v = try? c.decodeIfPresent(Bool.self, forKey: .agentConfirm) { agentConfirm = v }
        if let v = try? c.decodeIfPresent(Double.self, forKey: .agentTimeoutSeconds) {
            // "Agent timeout" slider (`range: 30...300`) — also the ceiling
            // that keeps AgentSessionManager's `Int(max(30, timeout))` from
            // trapping on an oversized decoded value.
            agentTimeoutSeconds = v.clamped(to: 30...300)
        }
    }
}
