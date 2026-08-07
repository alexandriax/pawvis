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
    /// truly different mishearings.
    public var wakeWordAliases: [String] = ["pawviz", "pavis", "purvis", "pervis", "jarvis"]
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
    /// Hand free-form commands to an installed agent CLI instead of the
    /// on-device intent mapper: "" (off), "claude" (Claude Code), or
    /// "codex" (Codex CLI). The agent runs headless with permission checks
    /// bypassed — strictly opt-in.
    public var agentExecutor: String = ""
    /// Seconds before a background agent run is abandoned.
    public var agentTimeoutSeconds: Double = 120
    /// Quiet time (legacy SFSpeechRecognizer path only) before an utterance is
    /// considered done.
    public var vadSilenceMs: Int = 500

    public init() {}

    enum CodingKeys: String, CodingKey {
        case enabled, language, wakeWord, wakeWordAliases
        case visualContextEnabled, vadSilenceMs
        case transcriptOverlayEnabled, transcriptOverlaySeconds, transcriptOverlayManualDismiss
        case agentExecutor, agentTimeoutSeconds
    }

    /// Field-tolerant decoding, matching GestureConfig's behavior. Keys from
    /// earlier builds (stop phrases, typing pause, delta typing) are simply
    /// ignored — one-shot commands made them obsolete.
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
        if let v = try? c.decodeIfPresent(String.self, forKey: .agentExecutor) { agentExecutor = v }
        if let v = try? c.decodeIfPresent(Double.self, forKey: .agentTimeoutSeconds) { agentTimeoutSeconds = v }
    }
}
