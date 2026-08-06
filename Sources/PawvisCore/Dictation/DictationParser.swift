import Foundation

/// Keys the parser can ask the typist to press.
public enum SpecialKey: String, Equatable, Sendable {
    case `return`, tab
}

/// What the app-layer text typist should do, in order.
public enum TypingAction: Equatable, Sendable {
    case type(String)
    /// Delete this many characters (used to reconcile streamed deltas against
    /// the final transcript, and to un-type text that turned out to be a
    /// command or stop phrase).
    case backspace(Int)
    case key(SpecialKey)
}

/// Settings for voice dictation.
public struct DictationConfig: Codable, Equatable, Sendable {
    /// Master switch.
    public var enabled: Bool = true
    /// Transcription engine: "apple" (on-device, default) or "openai" (cloud,
    /// needs an API key).
    public var engine: String = "apple"
    /// OpenAI model (used only when engine == "openai"). gpt-4o-transcribe is
    /// the default because it supports server VAD (live-verified full
    /// utterance lifecycle); gpt-live-transcribe streams lower-latency deltas
    /// but needs client-side commit segmentation.
    public var model: String = "gpt-4o-transcribe"
    /// ISO-639-1; empty = auto-detect.
    public var language: String = ""
    /// Saying one of these (as the first word of an utterance) starts typing.
    public var wakeWords: [String] = ["type", "text", "enter", "write", "dictate"]
    /// Saying one of these (alone, or at the end of an utterance) stops typing.
    public var stopPhrases: [String] = [
        "stop typing", "stop dictating", "stop dictation",
        "done typing", "end dictation",
    ]
    /// Whole-utterance spoken commands while dictating ("new line", "press enter").
    public var commandsEnabled: Bool = true
    /// Type streamed deltas immediately (lower latency, may briefly show
    /// revisions); off = type each utterance once it's final.
    public var typeDeltasImmediately: Bool = false
    public var vadSilenceMs: Int = 500
    /// "near_field" (headset), "far_field" (built-in mic), "" = off.
    public var noiseReduction: String = "far_field"

    public init() {}

    enum CodingKeys: String, CodingKey {
        case enabled, engine, model, language, wakeWords, stopPhrases
        case commandsEnabled, typeDeltasImmediately, vadSilenceMs, noiseReduction
    }

    /// Field-tolerant decoding, matching GestureConfig's behavior.
    public init(from decoder: Decoder) throws {
        self.init()
        let c = try decoder.container(keyedBy: CodingKeys.self)
        if let v = try? c.decodeIfPresent(Bool.self, forKey: .enabled) { enabled = v }
        if let v = try? c.decodeIfPresent(String.self, forKey: .engine) { engine = v }
        if let v = try? c.decodeIfPresent(String.self, forKey: .model) { model = v }
        if let v = try? c.decodeIfPresent(String.self, forKey: .language) { language = v }
        if let v = try? c.decodeIfPresent([String].self, forKey: .wakeWords) { wakeWords = v }
        if let v = try? c.decodeIfPresent([String].self, forKey: .stopPhrases) { stopPhrases = v }
        if let v = try? c.decodeIfPresent(Bool.self, forKey: .commandsEnabled) { commandsEnabled = v }
        if let v = try? c.decodeIfPresent(Bool.self, forKey: .typeDeltasImmediately) { typeDeltasImmediately = v }
        if let v = try? c.decodeIfPresent(Int.self, forKey: .vadSilenceMs) { vadSilenceMs = v }
        if let v = try? c.decodeIfPresent(String.self, forKey: .noiseReduction) { noiseReduction = v }
    }
}

/// Turns transcription events into typing actions.
///
/// States: `listening` (armed, waiting for a wake word — nothing is typed) and
/// `dictating` (every utterance is typed until a stop phrase). The parser is
/// pure state-machine logic: no audio, no network, no key events.
public final class DictationParser {
    public enum State: Equatable, Sendable {
        case listening
        case dictating
    }

    public var config: DictationConfig
    public private(set) var state: State = .listening

    /// True when the last emitted character was whitespace/newline (controls
    /// smart spacing between utterances).
    private var lastEndedInWhitespace = true

    /// Per-item record of exactly what we've already typed for that utterance
    /// (delta mode), including any smart-space prefix.
    private var emittedForItem: [String: String] = [:]
    /// Whether a smart space was decided for the item when its first delta was
    /// typed (so reconciliation recomputes the same desired string).
    private var spacePrefixForItem: [String: Bool] = [:]

    public init(config: DictationConfig = DictationConfig()) {
        self.config = config
    }

    /// Reset to the armed state (called when dictation is toggled on).
    public func beginListening() {
        state = .listening
        lastEndedInWhitespace = true
        emittedForItem.removeAll()
        spacePrefixForItem.removeAll()
    }

    // MARK: - Event handling

    /// Streamed partial transcript. Only types in delta mode while dictating.
    public func handleDelta(itemId: String, delta: String) -> [TypingAction] {
        guard config.typeDeltasImmediately, state == .dictating, !delta.isEmpty else { return [] }

        var out: [TypingAction] = []
        var emission = delta
        if emittedForItem[itemId] == nil {
            // First delta of this utterance: decide smart spacing once.
            let needsSpace = needsSmartSpace(before: delta)
            spacePrefixForItem[itemId] = needsSpace
            if needsSpace { emission = " " + emission }
            emittedForItem[itemId] = ""
        }
        emittedForItem[itemId]! += emission
        out.append(.type(emission))
        updateWhitespaceState(afterTyping: emission)
        return out
    }

    /// Final transcript for one utterance. Interprets wake words, stop phrases,
    /// and commands; reconciles anything already typed via deltas.
    public func handleCompleted(itemId: String, transcript: String) -> [TypingAction] {
        let alreadyTyped = emittedForItem.removeValue(forKey: itemId) ?? ""
        let hadSpacePrefix = spacePrefixForItem.removeValue(forKey: itemId)

        let interpretation = interpret(transcript)

        // Compute the exact string this utterance should leave behind.
        var desiredText: String? = nil
        switch interpretation.emission {
        case .text(let text):
            if text.isEmpty {
                desiredText = ""
            } else {
                let needsSpace = hadSpacePrefix ?? needsSmartSpace(before: text)
                desiredText = (needsSpace ? " " : "") + text
            }
        case .key:
            desiredText = nil // keys can't be expressed as typed text
        case .none:
            desiredText = ""
        }

        var out: [TypingAction] = []

        if let desired = desiredText {
            if desired == alreadyTyped {
                // Deltas already produced exactly the right text.
            } else if !alreadyTyped.isEmpty, desired.hasPrefix(alreadyTyped) {
                let remainder = String(desired.dropFirst(alreadyTyped.count))
                if !remainder.isEmpty {
                    out.append(.type(remainder))
                    updateWhitespaceState(afterTyping: remainder)
                }
            } else {
                if !alreadyTyped.isEmpty {
                    out.append(.backspace(alreadyTyped.count))
                }
                if !desired.isEmpty {
                    out.append(.type(desired))
                    updateWhitespaceState(afterTyping: desired)
                } else if !alreadyTyped.isEmpty {
                    lastEndedInWhitespace = true
                }
            }
        } else {
            // Key emission (command): un-type any deltas, then press the key.
            if !alreadyTyped.isEmpty {
                out.append(.backspace(alreadyTyped.count))
            }
            if case .key(let key) = interpretation.emission {
                out.append(.key(key))
                lastEndedInWhitespace = true
            }
        }

        state = interpretation.newState
        if state == .listening {
            // Leaving dictation: forget spacing context.
            lastEndedInWhitespace = true
        }
        return out
    }

    // MARK: - Interpretation

    private enum Emission: Equatable {
        case none
        case text(String)
        case key(SpecialKey)
    }

    private struct Interpretation {
        var emission: Emission
        var newState: State
    }

    private func interpret(_ transcript: String) -> Interpretation {
        let trimmed = transcript.trimmingCharacters(in: .whitespacesAndNewlines)
        guard !trimmed.isEmpty else { return Interpretation(emission: .none, newState: state) }

        switch state {
        case .listening:
            if let remainder = matchWakeWord(in: trimmed) {
                return Interpretation(emission: remainder.isEmpty ? .none : .text(remainder),
                                      newState: .dictating)
            }
            return Interpretation(emission: .none, newState: .listening)

        case .dictating:
            if let prefix = matchStopPhrase(in: trimmed) {
                return Interpretation(emission: prefix.isEmpty ? .none : .text(prefix),
                                      newState: .listening)
            }
            if config.commandsEnabled, let key = matchCommand(trimmed) {
                switch key {
                case .newline: return Interpretation(emission: .text("\n"), newState: .dictating)
                case .newParagraph: return Interpretation(emission: .text("\n\n"), newState: .dictating)
                case .pressReturn: return Interpretation(emission: .key(.return), newState: .dictating)
                case .pressTab: return Interpretation(emission: .key(.tab), newState: .dictating)
                }
            }
            return Interpretation(emission: .text(trimmed), newState: .dictating)
        }
    }

    /// If the utterance begins with a wake word, returns the remainder (may be
    /// empty). "Type hello world." → "hello world."
    private func matchWakeWord(in transcript: String) -> String? {
        let normalized = Self.normalize(transcript)
        for wake in config.wakeWords {
            let w = Self.normalize(wake)
            guard !w.isEmpty else { continue }
            if normalized == w { return "" }
            if normalized.hasPrefix(w + " ") {
                // Locate the wake word in the original to preserve casing of
                // the remainder; it is always at the (punctuation-trimmed) start.
                let stripped = Self.trimLeadingNoise(transcript)
                let afterWake = stripped.dropFirst(wakeWordOriginalLength(w, in: stripped))
                return Self.trimLeadingNoise(String(afterWake))
            }
        }
        return nil
    }

    /// Length in the original string of the leading wake word (which normalize
    /// may have shortened by stripping trailing punctuation like "type,").
    private func wakeWordOriginalLength(_ normalizedWake: String, in original: String) -> Int {
        var count = 0
        var matched = 0
        let target = Array(normalizedWake.unicodeScalars)
        for scalar in original.unicodeScalars {
            count += 1
            let lower = String(scalar).lowercased().unicodeScalars.first!
            if matched < target.count, lower == target[matched] {
                matched += 1
                if matched == target.count { break }
            } else if CharacterSet.punctuationCharacters.contains(scalar) {
                continue // skip punctuation interleaved with the wake word
            }
        }
        return count
    }

    /// If the utterance is (or ends with) a stop phrase, returns the content
    /// before it ("wrap it up stop typing" → "wrap it up"; "stop typing" → "").
    private func matchStopPhrase(in transcript: String) -> String? {
        let normalized = Self.normalize(transcript)
        for stop in config.stopPhrases {
            let s = Self.normalize(stop)
            guard !s.isEmpty else { continue }
            if normalized == s { return "" }
            if normalized.hasSuffix(" " + s) {
                // Find the stop phrase's start in the original (case-insensitive
                // search from the end) and keep what precedes it.
                if let range = transcript.range(of: stop, options: [.caseInsensitive, .backwards]) {
                    let prefix = String(transcript[..<range.lowerBound])
                    return Self.trimTrailingNoise(prefix)
                }
                return ""
            }
        }
        return nil
    }

    private enum Command {
        case newline, newParagraph, pressReturn, pressTab
    }

    private func matchCommand(_ transcript: String) -> Command? {
        switch Self.normalize(transcript) {
        case "new line", "newline": return .newline
        case "new paragraph": return .newParagraph
        case "press enter", "hit enter", "press return": return .pressReturn
        case "press tab", "hit tab": return .pressTab
        default: return nil
        }
    }

    // MARK: - Text helpers

    /// Lowercase, strip punctuation, collapse whitespace — for matching only.
    static func normalize(_ s: String) -> String {
        let lowered = s.lowercased()
        let stripped = lowered.unicodeScalars.filter {
            !CharacterSet.punctuationCharacters.contains($0)
        }
        let collapsed = String(String.UnicodeScalarView(stripped))
            .components(separatedBy: .whitespacesAndNewlines)
            .filter { !$0.isEmpty }
            .joined(separator: " ")
        return collapsed
    }

    static func trimLeadingNoise(_ s: String) -> String {
        String(s.drop { c in
            c.unicodeScalars.allSatisfy {
                CharacterSet.whitespacesAndNewlines.contains($0)
                    || CharacterSet.punctuationCharacters.contains($0)
            }
        })
    }

    static func trimTrailingNoise(_ s: String) -> String {
        var result = s
        while let last = result.last, last.unicodeScalars.allSatisfy({
            CharacterSet.whitespacesAndNewlines.contains($0)
                || CharacterSet.punctuationCharacters.contains($0)
        }) {
            result.removeLast()
        }
        return result
    }

    private static let noSpaceBeforePrefixes: Set<Character> = [
        ".", ",", "!", "?", ";", ":", ")", "]", "}", "'", "”", "%",
    ]

    private func needsSmartSpace(before text: String) -> Bool {
        guard !lastEndedInWhitespace, let first = text.first else { return false }
        if first.isWhitespace || first.isNewline { return false }
        return !Self.noSpaceBeforePrefixes.contains(first)
    }

    private func updateWhitespaceState(afterTyping text: String) {
        if let last = text.last {
            lastEndedInWhitespace = last.isWhitespace || last.isNewline
        }
    }
}
