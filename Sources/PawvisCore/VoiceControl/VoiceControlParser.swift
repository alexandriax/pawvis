import Foundation

/// What one finalized utterance amounts to: typing actions to perform (text
/// mode, including reconciliation of streamed deltas) and/or a machine
/// command to execute.
public struct VoiceParseResult: Equatable, Sendable {
    public var typing: [TypingAction] = []
    public var command: VoiceCommand? = nil

    public init(typing: [TypingAction] = [], command: VoiceCommand? = nil) {
        self.typing = typing
        self.command = command
    }
}

/// Turns transcription events into typing actions and voice commands.
///
/// States: `listening` (armed — only wake-word utterances do anything) and
/// `typing` (after "Pawvis type …": every utterance is typed until a stop
/// phrase or a pause). The parser is pure state-machine logic: no audio, no
/// screen access, no key events.
public final class VoiceControlParser {
    public enum State: Equatable, Sendable {
        case listening
        case typing
    }

    public var config: VoiceControlConfig
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

    public init(config: VoiceControlConfig = VoiceControlConfig()) {
        self.config = config
    }

    /// Reset to the armed state (called when voice control is toggled on).
    public func beginListening() {
        state = .listening
        lastEndedInWhitespace = true
        emittedForItem.removeAll()
        spacePrefixForItem.removeAll()
    }

    /// The typing-pause timer fired: leave typing mode.
    /// Returns true if the state changed.
    @discardableResult
    public func handlePauseTimeout() -> Bool {
        guard state == .typing else { return false }
        state = .listening
        lastEndedInWhitespace = true
        return true
    }

    // MARK: - Event handling

    /// Streamed partial transcript. Only types in delta mode while typing.
    public func handleDelta(itemId: String, delta: String) -> [TypingAction] {
        guard config.typeDeltasImmediately, state == .typing, !delta.isEmpty else { return [] }

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

    /// Final transcript for one utterance. Interprets wake words, commands,
    /// and stop phrases; reconciles anything already typed via deltas.
    public func handleCompleted(itemId: String, transcript: String) -> VoiceParseResult {
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
            // Key emission (inline command): un-type any deltas, press the key.
            if !alreadyTyped.isEmpty {
                out.append(.backspace(alreadyTyped.count))
            }
            if case .key(let chord) = interpretation.emission {
                out.append(.key(chord))
                lastEndedInWhitespace = true
            }
        }

        state = interpretation.newState
        if state == .listening {
            // Leaving typing mode: forget spacing context.
            lastEndedInWhitespace = true
        }
        return VoiceParseResult(typing: out, command: interpretation.command)
    }

    // MARK: - Interpretation

    private enum Emission: Equatable {
        case none
        case text(String)
        case key(KeyChord)
    }

    private struct Interpretation {
        var emission: Emission = .none
        var newState: State
        var command: VoiceCommand? = nil
    }

    private func interpret(_ transcript: String) -> Interpretation {
        let trimmed = transcript.trimmingCharacters(in: .whitespacesAndNewlines)
        guard !trimmed.isEmpty else { return Interpretation(newState: state) }

        switch state {
        case .listening:
            guard let remainder = matchWakeWord(in: trimmed) else {
                return Interpretation(newState: .listening)
            }
            return interpretCommand(remainder)

        case .typing:
            if let remainder = matchWakeWord(in: trimmed) {
                // Addressed directly while typing ("Pawvis press enter",
                // "Pawvis stop typing"): a command, never typed text. Checked
                // before stop phrases so "Pawvis stop typing" doesn't type
                // "Pawvis".
                return interpretCommand(remainder)
            }
            if let prefix = matchStopPhrase(in: trimmed) {
                return Interpretation(
                    emission: prefix.isEmpty ? .none : .text(prefix),
                    newState: .listening)
            }
            if config.inlineCommandsEnabled, let inline = matchInlineCommand(trimmed) {
                return inline
            }
            return Interpretation(emission: .text(trimmed), newState: .typing)
        }
    }

    /// Parse what follows the wake word. Falls back to `.resolve` (on-screen
    /// context + on-device model) for anything the grammar doesn't cover.
    private func interpretCommand(_ remainder: String) -> Interpretation {
        // Leading noise only: a trailing "." or "!" belongs to typed payloads
        // ("type hello world."); command targets are trimmed in payload().
        let cleaned = Self.trimLeadingNoise(remainder)
        guard !cleaned.isEmpty else {
            // Bare "Pawvis" — attention with nothing to do.
            return Interpretation(newState: state)
        }
        let tokens = Self.normalize(cleaned).split(separator: " ").map(String.init)

        // Stop phrases addressed via wake word ("Pawvis stop typing").
        if state == .typing, matchStopPhrase(in: cleaned) != nil {
            return Interpretation(newState: .listening)
        }

        if let interpretation = matchTypeVerb(cleaned: cleaned, tokens: tokens) {
            return interpretation
        }
        if let command = matchCommandVerb(cleaned: cleaned, tokens: tokens) {
            return Interpretation(newState: stateAfter(command), command: command)
        }
        return Interpretation(newState: state, command: .resolve(transcript: cleaned))
    }

    /// "type …" / "dictate …" enters typing mode and types the payload.
    private func matchTypeVerb(cleaned: String, tokens: [String]) -> Interpretation? {
        let typeVerbs: Set<String> = ["type", "dictate", "write"]
        guard let first = tokens.first, typeVerbs.contains(first) else { return nil }
        let payload = Self.trimLeadingNoise(String(dropFirstWord(of: cleaned)))
        return Interpretation(
            emission: payload.isEmpty ? .none : .text(payload),
            newState: .typing)
    }

    private func matchCommandVerb(cleaned: String, tokens: [String]) -> VoiceCommand? {
        guard let first = tokens.first else { return nil }
        let normalizedJoined = tokens.joined(separator: " ")

        // Whole-utterance phrases first.
        switch normalizedJoined {
        case "stop", "stop listening", "go to sleep", "sleep", "turn off", "goodbye":
            return .stopVoiceControl
        case "click", "tap": return .click(.left)
        case "right click": return .click(.right)
        case "double click", "double tap": return .click(.double)
        default: break
        }

        // "go to X" / "navigate to X" / "visit X" — a URL or a web search.
        if let target = payload(after: ["go to", "goto", "navigate to", "browse to", "visit"],
                                cleaned: cleaned, tokens: tokens), !target.isEmpty {
            if let url = SpokenURLNormalizer.normalize(target) {
                return .goTo(url: url)
            }
            return .webSearch(query: target)
        }

        if let query = payload(after: ["search for", "google", "look up"],
                               cleaned: cleaned, tokens: tokens), !query.isEmpty {
            return .webSearch(query: query)
        }

        // "switch to X" before "open X" so "switch to chrome" never launches
        // a second copy.
        if let app = payload(after: ["switch to", "switch back to", "go back to"],
                             cleaned: cleaned, tokens: tokens), !app.isEmpty {
            return .switchTo(app: app)
        }

        if let app = payload(after: ["open", "launch"], cleaned: cleaned, tokens: tokens),
           !app.isEmpty {
            return .open(app: app)
        }

        if first == "press" || first == "hit" || first == "push" {
            let keyTokens = Array(tokens.dropFirst())
            if let chord = SpokenKeyParser.chord(from: keyTokens) {
                return .press(chord)
            }
            return .resolve(transcript: cleaned)
        }

        if first == "scroll" {
            return scrollCommand(from: Array(tokens.dropFirst()))
        }

        // "click X" with a target needs on-screen context.
        if first == "click" || first == "tap" {
            return .resolve(transcript: cleaned)
        }

        return nil
    }

    private func stateAfter(_ command: VoiceCommand) -> State {
        if case .stopVoiceControl = command { return .listening }
        return state
    }

    private func scrollCommand(from tokens: [String]) -> VoiceCommand {
        var direction = ScrollDirection.down
        var amount = ScrollAmount.step
        for token in tokens {
            if let d = ScrollDirection(rawValue: token) { direction = d }
        }
        let joined = tokens.joined(separator: " ")
        if joined.contains("little") || joined.contains("bit") || joined.contains("nudge") {
            amount = .nudge
        } else if joined.contains("page") || joined.contains("lot") || joined.contains("way") {
            amount = .page
        }
        return .scroll(direction: direction, amount: amount)
    }

    /// If the normalized utterance starts with one of `prefixes`, returns the
    /// original-cased payload after it ("open Google Chrome" → "Google Chrome").
    private func payload(after prefixes: [String], cleaned: String, tokens: [String]) -> String? {
        let normalizedJoined = tokens.joined(separator: " ")
        for prefix in prefixes {
            if normalizedJoined == prefix { return "" }
            guard normalizedJoined.hasPrefix(prefix + " ") else { continue }
            let wordCount = prefix.split(separator: " ").count
            var rest = cleaned
            for _ in 0..<wordCount {
                rest = String(dropFirstWord(of: rest))
            }
            return Self.trimTrailingNoise(Self.trimLeadingNoise(rest))
        }
        return nil
    }

    /// Drops the first whitespace-delimited word (plus leading noise).
    private func dropFirstWord(of s: String) -> Substring {
        let trimmed = Self.trimLeadingNoise(s)
        guard let space = trimmed.firstIndex(where: { $0.isWhitespace }) else {
            return Substring("")
        }
        return trimmed[space...]
    }

    // MARK: - Wake word

    /// If the utterance begins with the wake word (or a close mishearing),
    /// returns the remainder with original casing (may be empty).
    /// "Pawvis, go to github.com" → "go to github.com".
    private func matchWakeWord(in transcript: String) -> String? {
        let chunks = transcript.split(whereSeparator: { $0.isWhitespace })
        guard !chunks.isEmpty else { return nil }

        var candidates: Set<String> = [Self.foldedWakeToken(config.wakeWord)]
        for alias in config.wakeWordAliases {
            candidates.insert(Self.foldedWakeToken(alias))
        }
        candidates.remove("")
        let maxCandidateWords = max(
            config.wakeWord.split(separator: " ").count,
            config.wakeWordAliases.map { $0.split(separator: " ").count }.max() ?? 1)

        // The recognizer may split the wake word ("Paw vis") — try joining the
        // first k chunks. One extra chunk beyond the longest candidate covers
        // a split single-word wake word.
        for k in 1...min(maxCandidateWords + 1, chunks.count) {
            let joined = chunks[0..<k].map { Self.normalize(String($0)) }.joined()
            guard joined.count >= 3 else { continue }
            let matched = candidates.contains(joined)
                || candidates.contains { candidate in
                    candidate.count >= 5 && abs(candidate.count - joined.count) <= 1
                        && Self.editDistanceAtMostOne(joined, candidate)
                }
            if matched {
                if chunks.count > k {
                    let remainderStart = chunks[k].startIndex
                    return Self.trimLeadingNoise(String(transcript[remainderStart...]))
                }
                return ""
            }
        }
        return nil
    }

    /// Normalized, space-stripped form used for wake-word comparison
    /// ("Paw Viz" → "pawviz").
    private static func foldedWakeToken(_ s: String) -> String {
        normalize(s).replacingOccurrences(of: " ", with: "")
    }

    /// True when Levenshtein distance ≤ 1 (covers "pavis", "pawbis"…).
    static func editDistanceAtMostOne(_ a: String, _ b: String) -> Bool {
        if a == b { return true }
        let aChars = Array(a), bChars = Array(b)
        if abs(aChars.count - bChars.count) > 1 { return false }

        if aChars.count == bChars.count {
            // Exactly one substitution allowed.
            var mismatches = 0
            for i in 0..<aChars.count where aChars[i] != bChars[i] {
                mismatches += 1
                if mismatches > 1 { return false }
            }
            return true
        }

        // Lengths differ by one: one insertion/deletion allowed.
        let (longer, shorter) = aChars.count > bChars.count ? (aChars, bChars) : (bChars, aChars)
        var li = 0, si = 0, skipped = false
        while li < longer.count && si < shorter.count {
            if longer[li] == shorter[si] {
                li += 1; si += 1
            } else {
                if skipped { return false }
                skipped = true
                li += 1
            }
        }
        return true
    }

    // MARK: - Stop phrases & inline commands

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

    /// Spoken whole-utterance commands while typing, no wake word needed:
    /// "new line", "new paragraph", "press enter", "press tab", …
    private func matchInlineCommand(_ transcript: String) -> Interpretation? {
        let tokens = Self.normalize(transcript).split(separator: " ").map(String.init)
        switch tokens.joined(separator: " ") {
        case "new line", "newline":
            return Interpretation(emission: .text("\n"), newState: .typing)
        case "new paragraph":
            return Interpretation(emission: .text("\n\n"), newState: .typing)
        default:
            break
        }
        if tokens.count >= 2, tokens[0] == "press" || tokens[0] == "hit",
           let chord = SpokenKeyParser.chord(from: Array(tokens.dropFirst())) {
            return Interpretation(emission: .key(chord), newState: .typing)
        }
        return nil
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
