import Foundation

/// What one finalized utterance amounts to: typing actions to perform and/or
/// a machine command to execute.
public struct VoiceParseResult: Equatable, Sendable {
    public var typing: [TypingAction] = []
    public var command: VoiceCommand? = nil

    public init(typing: [TypingAction] = [], command: VoiceCommand? = nil) {
        self.typing = typing
        self.command = command
    }
}

/// Turns finalized utterances into typing actions and voice commands.
///
/// Stateless by design: EVERY command must start with the wake word — speech
/// without it is ignored, and no utterance changes how the next one is
/// interpreted. "Pawvis type hello" types "hello" and that's the end of it;
/// there is no lingering dictation mode to fall out of.
public final class VoiceControlParser {
    public var config: VoiceControlConfig

    public init(config: VoiceControlConfig = VoiceControlConfig()) {
        self.config = config
    }

    /// True when the utterance begins with the wake word or a close
    /// mishearing — used to gate the transcript capsule so ambient speech is
    /// never displayed.
    public func hasWakePrefix(_ transcript: String) -> Bool {
        wakeRemainder(transcript) != nil
    }

    /// The utterance with the wake word stripped (nil when it doesn't start
    /// with the wake word) — what the free-form handlers should receive.
    public func wakeRemainder(_ transcript: String) -> String? {
        matchWakeWord(in: transcript.trimmingCharacters(in: .whitespacesAndNewlines))
    }

    /// A looser gate for utterances the strict one rejects: the opening
    /// chunks are a *plausible* mishearing of the wake word (edit distance
    /// ≤ 2 where the strict gate stops at 1 — "Paw this open Safari").
    /// Never act on this alone: it only nominates an utterance for on-device
    /// AI confirmation on the agent path, so ambient speech that merely
    /// resembles the wake word still can't trigger anything by itself.
    public func nearWakeRemainder(_ transcript: String) -> String? {
        matchWakeWord(
            in: transcript.trimmingCharacters(in: .whitespacesAndNewlines), tolerance: 2)
    }

    /// Interpret one finalized utterance.
    public func parse(_ transcript: String) -> VoiceParseResult {
        let trimmed = transcript.trimmingCharacters(in: .whitespacesAndNewlines)
        guard !trimmed.isEmpty, let remainder = matchWakeWord(in: trimmed) else {
            return VoiceParseResult()
        }
        return parseRemainder(remainder)
    }

    /// Interpret an utterance whose wake word is already stripped — either by
    /// `parse` above, or spoken in an earlier segment and stitched on by the
    /// utterance gate's capture window.
    public func parseRemainder(_ remainder: String) -> VoiceParseResult {
        // Leading noise only: a trailing "." or "!" belongs to typed payloads
        // ("Pawvis type hello world."); command targets are trimmed in
        // payload().
        let cleaned = Self.trimLeadingNoise(remainder)
        guard !cleaned.isEmpty else {
            // Bare "Pawvis" — attention with nothing to do.
            return VoiceParseResult()
        }
        let tokens = Self.normalize(cleaned).split(separator: " ").map(String.init)

        // "type …" / "dictate …" types its payload — one-shot.
        if let payload = typePayload(cleaned: cleaned, tokens: tokens) {
            return VoiceParseResult(typing: payload.isEmpty ? [] : [.type(payload)])
        }
        if let command = matchCommandVerb(cleaned: cleaned, tokens: tokens) {
            return VoiceParseResult(command: command)
        }
        return VoiceParseResult(command: .resolve(transcript: cleaned))
    }

    // MARK: - Command grammar

    /// "type …" / "dictate …" / "write …" → the original-cased payload.
    private func typePayload(cleaned: String, tokens: [String]) -> String? {
        let typeVerbs: Set<String> = ["type", "dictate", "write"]
        guard let first = tokens.first, typeVerbs.contains(first) else { return nil }
        return Self.trimLeadingNoise(String(dropFirstWord(of: cleaned)))
    }

    private func matchCommandVerb(cleaned: String, tokens: [String]) -> VoiceCommand? {
        guard let first = tokens.first else { return nil }
        let normalizedJoined = tokens.joined(separator: " ")

        // Stop and cancel first, and tolerant of politeness padding
        // ("please stop listening", "ok stop now"): these are the safety
        // phrases, and padding must never turn a brake into an autopilot
        // goal that starts acting on the screen.
        let depoliteJoined = tokens
            .filter { !Self.politenessTokens.contains($0) }
            .joined(separator: " ")
        switch depoliteJoined {
        case "stop listening", "go to sleep", "sleep", "turn off", "goodbye":
            return .stopVoiceControl
        // Bare "stop" cancels what's running (and only stops listening when
        // nothing is) — the instant brake for a runaway autopilot or agent.
        case "stop", "stop it", "cancel", "cancel that", "never mind", "nevermind":
            return .cancelActivity
        default: break
        }

        // Whole-utterance phrases, exact matches only: any trailing words
        // ("copy that file over there") fall through to the autopilot, so
        // multi-clause requests are never half-eaten by a chord.
        switch normalizedJoined {
        case "click", "tap": return .click(.left)
        case "right click": return .click(.right)
        case "double click", "double tap": return .click(.double)
        // "quit it/this/that" pin to the frontmost app: two-letter payloads
        // would otherwise fuzzy-match real apps ("it" → iTerm), and quit is
        // no verb to guess on.
        case "quit", "quit this app", "quit it", "quit this", "quit that",
             "quit the app":
            return .quit(app: nil)
        default: break
        }

        // Window and edit chords — the shortcuts everyone means by the bare
        // phrase. Whole-utterance only, same rule as above.
        if let chord = Self.phraseChords[normalizedJoined] {
            return .press(chord)
        }

        // "go to X" / "navigate to X" / "visit X" — a URL or a web search,
        // possibly qualified with an app ("go to discord dot com in chrome").
        if let target = payload(after: ["go to", "goto", "navigate to", "browse to", "visit"],
                                cleaned: cleaned, tokens: tokens), !target.isEmpty {
            if let nav = navigation(from: target) {
                return nav
            }
            return .webSearch(query: target, app: nil)
        }

        if let query = payload(after: ["search for", "google", "look up"],
                               cleaned: cleaned, tokens: tokens), !query.isEmpty {
            // A trailing browser qualifier names where to search; anything
            // else is part of the query ("search for life in the universe").
            if let split = Self.splitAppQualifier(of: query),
               Self.isBrowserWord(split.app) {
                return .webSearch(query: split.payload, app: split.app)
            }
            return .webSearch(query: query, app: nil)
        }

        // "switch to X" before "open X" so "switch to chrome" never launches
        // a second copy. App-name targets can't contain clause markers — a
        // multi-clause target ("open notes and start a new note") is a
        // task, not an app name, and goes to the free-form ladder whole.
        if let app = payload(after: ["switch to", "switch back to", "go back to"],
                             cleaned: cleaned, tokens: tokens), !app.isEmpty {
            if AutopilotPolicy.isMultiClause(goal: app) {
                return .resolve(transcript: cleaned)
            }
            return .switchTo(app: app)
        }

        if let app = payload(after: ["quit"], cleaned: cleaned, tokens: tokens),
           !app.isEmpty {
            if AutopilotPolicy.isMultiClause(goal: app) {
                return .resolve(transcript: cleaned)
            }
            return .quit(app: app)
        }

        if let app = payload(after: ["open", "launch"], cleaned: cleaned, tokens: tokens),
           !app.isEmpty {
            // "open" covers places as well as apps: a URL-shaped target
            // ("open discord dot com"), or anything aimed at a browser
            // ("open discord in chrome"), is navigation, not an app launch.
            if let nav = navigation(from: app) {
                return nav
            }
            if AutopilotPolicy.isMultiClause(goal: app) {
                return .resolve(transcript: cleaned)
            }
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

    /// Filler that pads spoken stop phrases without changing their meaning.
    /// Only the stop/cancel matching strips these — a chord or app name is
    /// never rewritten.
    private static let politenessTokens: Set<String> = [
        "please", "ok", "okay", "hey", "now",
    ]

    // MARK: - App-qualified navigation

    /// A spoken target split at its trailing app qualifier:
    /// "discord dot com in chrome" → ("discord dot com", "chrome", "in").
    struct AppQualifierSplit: Equatable {
        var payload: String
        var app: String
        var separator: String
    }

    /// Browsers people name in navigation commands. Pure vocabulary — whether
    /// the name resolves to an installed app is the executor's business; this
    /// list only decides that a qualifier makes a phrase navigational.
    private static let browserWords: Set<String> = [
        "safari", "safari technology preview", "chrome", "google chrome",
        "chromium", "firefox", "edge", "microsoft edge", "arc", "brave",
        "brave browser", "opera", "vivaldi", "orion", "kagi", "dia",
        "browser", "the browser", "my browser", "a browser",
        "default browser", "the default browser",
    ]

    /// Payload words that mean browser furniture or screen context, not a
    /// destination — "open a new tab in chrome" and "open it in chrome" must
    /// not become web searches for "a new tab" or "it".
    private static let nonDestinationWords: Set<String> = [
        "tab", "tabs", "window", "windows", "incognito", "private",
        "it", "this", "that", "them",
    ]

    static func isBrowserWord(_ s: String) -> Bool {
        browserWords.contains(normalize(s))
    }

    /// Splits "<payload> in <app>" (also "with"/"using"/"on") at the LAST
    /// separator. Both halves keep the original casing. Purely lexical —
    /// whether the qualifier actually reads as an app is decided in
    /// `navigation(from:)`.
    static func splitAppQualifier(of target: String) -> AppQualifierSplit? {
        let words = target.split(whereSeparator: { $0.isWhitespace }).map(String.init)
        guard words.count >= 3 else { return nil }
        let separators: Set<String> = ["in", "with", "using", "on"]
        for index in stride(from: words.count - 2, through: 1, by: -1) {
            let separator = normalize(words[index])
            guard separators.contains(separator) else { continue }
            // A separator followed by spoken URL punctuation is inside an
            // address ("linked in dot com"), not introducing a qualifier —
            // keep scanning left.
            if SpokenURLNormalizer.isConnectorToken(normalize(words[index + 1])) {
                continue
            }
            let payload = words[..<index].joined(separator: " ")
            let app = trimTrailingNoise(words[(index + 1)...].joined(separator: " "))
            guard !payload.isEmpty, !app.isEmpty else { return nil }
            return AppQualifierSplit(payload: payload, app: app, separator: separator)
        }
        return nil
    }

    /// Interprets a spoken open/go-to target as a navigation destination.
    /// In order:
    /// - "<url> <qualifier>" → that URL; the qualifier rides along as the
    ///   app when it reads like one (a known browser, or a short "in/with/
    ///   using" phrase) and is DROPPED otherwise ("discord dot com on my
    ///   laptop" navigates to discord.com) — a qualifier must never be
    ///   glued into the address.
    /// - "<words> in <known browser>" → search those words there (the
    ///   address bar autocompletes "discord" the same way the user would),
    ///   unless the words are browser furniture ("a new tab") or pronouns.
    /// - A target that is URL-shaped as a whole → that URL.
    /// Returns nil when the target doesn't read as navigation (an app name,
    /// a file, free-form speech) — the caller keeps its own meaning.
    func navigation(from target: String) -> VoiceCommand? {
        if let split = Self.splitAppQualifier(of: target) {
            let qualifierIsBrowser = Self.isBrowserWord(split.app)
            if let url = SpokenURLNormalizer.normalize(split.payload) {
                let qualifierWordCount = split.app
                    .split(whereSeparator: { $0.isWhitespace }).count
                let qualifierReadsAsApp = qualifierIsBrowser
                    || (split.separator != "on" && qualifierWordCount <= 4)
                return .goTo(url: url, app: qualifierReadsAsApp ? split.app : nil)
            }
            if qualifierIsBrowser {
                let payloadWords = Set(
                    Self.normalize(split.payload).split(separator: " ").map(String.init))
                if payloadWords.isDisjoint(with: Self.nonDestinationWords) {
                    return .webSearch(query: split.payload, app: split.app)
                }
            }
            // A qualifier structure existed but didn't read as navigation
            // ("open the file in downloads"): never fall through to
            // whole-target URL assembly — that's the gluing bug again.
            return nil
        }
        if let url = SpokenURLNormalizer.normalize(target) {
            return .goTo(url: url, app: nil)
        }
        return nil
    }

    /// Spoken window/edit phrases and the chord each one means. All keys
    /// exist in TextTyper's code table.
    private static let phraseChords: [String: KeyChord] = [
        "close window": KeyChord(key: "w", modifiers: [.command]),
        "close the window": KeyChord(key: "w", modifiers: [.command]),
        "close this window": KeyChord(key: "w", modifiers: [.command]),
        "close tab": KeyChord(key: "w", modifiers: [.command]),
        "close the tab": KeyChord(key: "w", modifiers: [.command]),
        "close this tab": KeyChord(key: "w", modifiers: [.command]),
        "minimize": KeyChord(key: "m", modifiers: [.command]),
        "minimize window": KeyChord(key: "m", modifiers: [.command]),
        "minimize the window": KeyChord(key: "m", modifiers: [.command]),
        "hide": KeyChord(key: "h", modifiers: [.command]),
        "hide this": KeyChord(key: "h", modifiers: [.command]),
        "hide this app": KeyChord(key: "h", modifiers: [.command]),
        "new tab": KeyChord(key: "t", modifiers: [.command]),
        "new window": KeyChord(key: "n", modifiers: [.command]),
        "copy": KeyChord(key: "c", modifiers: [.command]),
        "paste": KeyChord(key: "v", modifiers: [.command]),
        "cut": KeyChord(key: "x", modifiers: [.command]),
        "undo": KeyChord(key: "z", modifiers: [.command]),
        "redo": KeyChord(key: "z", modifiers: [.command, .shift]),
        "save": KeyChord(key: "s", modifiers: [.command]),
        "select all": KeyChord(key: "a", modifiers: [.command]),
        "full screen": KeyChord(key: "f", modifiers: [.control, .command]),
        "fullscreen": KeyChord(key: "f", modifiers: [.control, .command]),
        "enter full screen": KeyChord(key: "f", modifiers: [.control, .command]),
        "exit full screen": KeyChord(key: "f", modifiers: [.control, .command]),
    ]

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
        matchWakeWord(in: transcript, tolerance: 1)
    }

    private func matchWakeWord(in transcript: String, tolerance: Int) -> String? {
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
                    candidate.count >= 5 && abs(candidate.count - joined.count) <= tolerance
                        && Self.editDistance(joined, candidate, isAtMost: tolerance)
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
        editDistance(a, b, isAtMost: 1)
    }

    /// Bounded Levenshtein: true when distance ≤ `limit`. The strings here
    /// are folded wake-word tokens — a handful of characters — so the full
    /// DP table is nothing.
    static func editDistance(_ a: String, _ b: String, isAtMost limit: Int) -> Bool {
        if a == b { return true }
        let aChars = Array(a), bChars = Array(b)
        if abs(aChars.count - bChars.count) > limit { return false }

        var previous = Array(0...bChars.count)
        for (i, aChar) in aChars.enumerated() {
            var current = [i + 1]
            current.reserveCapacity(bChars.count + 1)
            for (j, bChar) in bChars.enumerated() {
                let substitution = previous[j] + (aChar == bChar ? 0 : 1)
                current.append(min(previous[j + 1] + 1, current[j] + 1, substitution))
            }
            if current.min()! > limit { return false }
            previous = current
        }
        return previous[bChars.count] <= limit
    }

    // MARK: - Text helpers

    /// Lowercase, strip punctuation, collapse whitespace — for matching only.
    public static func normalize(_ s: String) -> String {
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
}
