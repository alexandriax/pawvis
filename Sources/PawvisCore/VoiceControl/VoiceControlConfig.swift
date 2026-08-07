import Foundation

/// Settings for voice control. Speech recognition is always Apple's on-device
/// stack — nothing leaves the Mac.
public struct VoiceControlConfig: Codable, Equatable, Sendable {
    /// Master switch.
    public var enabled: Bool = true
    /// ISO-639-1; empty = auto-detect.
    public var language: String = ""
    /// Say this word first to address Pawvis ("Pawvis, go to github.com").
    public var wakeWord: String = "Pawvis"
    /// Alternate spellings the recognizer may produce for the wake word.
    /// Matching is also fuzzy (edit distance 1), so this list only needs the
    /// truly different mishearings.
    public var wakeWordAliases: [String] = ["pawviz", "pavis", "purvis", "pervis", "jarvis"]
    /// Saying one of these (alone, or at the end of an utterance) while typing
    /// returns to listening.
    public var stopPhrases: [String] = [
        "stop typing", "stop dictating", "stop dictation",
        "done typing", "end dictation",
    ]
    /// Seconds of silence after which typing mode ends on its own.
    public var typingPauseSeconds: Double = 2.5
    /// Whole-utterance spoken commands while typing ("new line", "press enter").
    public var inlineCommandsEnabled: Bool = true
    /// Type streamed deltas immediately (lower latency, may briefly show
    /// revisions); off = type each utterance once it's final.
    public var typeDeltasImmediately: Bool = false
    /// Resolve free-form commands ("click sign in") against a screenshot/
    /// accessibility snapshot of the area around the pointer, using the
    /// on-device Apple Intelligence model. macOS 26+ with Apple Intelligence.
    public var visualContextEnabled: Bool = true
    /// Quiet time (legacy SFSpeechRecognizer path only) before an utterance is
    /// considered done.
    public var vadSilenceMs: Int = 500

    public init() {}

    enum CodingKeys: String, CodingKey {
        case enabled, language, wakeWord, wakeWordAliases, stopPhrases
        case typingPauseSeconds, inlineCommandsEnabled, typeDeltasImmediately
        case visualContextEnabled, vadSilenceMs
    }

    /// Field-tolerant decoding, matching GestureConfig's behavior.
    public init(from decoder: Decoder) throws {
        self.init()
        let c = try decoder.container(keyedBy: CodingKeys.self)
        if let v = try? c.decodeIfPresent(Bool.self, forKey: .enabled) { enabled = v }
        if let v = try? c.decodeIfPresent(String.self, forKey: .language) { language = v }
        if let v = try? c.decodeIfPresent(String.self, forKey: .wakeWord) { wakeWord = v }
        if let v = try? c.decodeIfPresent([String].self, forKey: .wakeWordAliases) { wakeWordAliases = v }
        if let v = try? c.decodeIfPresent([String].self, forKey: .stopPhrases) { stopPhrases = v }
        if let v = try? c.decodeIfPresent(Double.self, forKey: .typingPauseSeconds) { typingPauseSeconds = v }
        if let v = try? c.decodeIfPresent(Bool.self, forKey: .inlineCommandsEnabled) { inlineCommandsEnabled = v }
        if let v = try? c.decodeIfPresent(Bool.self, forKey: .typeDeltasImmediately) { typeDeltasImmediately = v }
        if let v = try? c.decodeIfPresent(Bool.self, forKey: .visualContextEnabled) { visualContextEnabled = v }
        if let v = try? c.decodeIfPresent(Int.self, forKey: .vadSilenceMs) { vadSilenceMs = v }
    }
}
