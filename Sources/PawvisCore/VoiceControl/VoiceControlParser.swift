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

    /// The utterance with the wake word stripped (nil when the wake word
    /// isn't there) — what the free-form handlers should receive.
    ///
    /// Three acceptance tiers, strictest first:
    /// - Utterance-initial (edit distance ≤ 1), as always.
    /// - After leading filler ("Um, Pawvis, open chrome") — people front
    ///   commands with filler constantly, and the recognizer transcribes it.
    /// - Glued mid-utterance (the recognizer joined ambient speech to the
    ///   command segment): accepted ONLY when what follows the wake word
    ///   parses as a deterministic command — "she said pawvis was busy"
    ///   stays ambient, "…anyway pawvis open safari" acts. With
    ///   `config.strictWake` on (the agent hand-off is live), this tier is
    ///   disabled outright: mid-utterance stitching is a mishearing surface
    ///   no accept should ride when accepting means arbitrary execution.
    public func wakeRemainder(_ transcript: String) -> String? {
        guard let match = wakeMatch(in: transcript, tolerance: 1) else { return nil }
        if match.trusted { return match.remainder }
        if config.strictWake { return nil }
        return remainderIsDeterministicCommand(match.remainder) ? match.remainder : nil
    }

    /// A looser gate for utterances the strict one rejects: the opening
    /// chunks are a *plausible* mishearing of the wake word (edit distance
    /// ≤ 2 where the strict gate stops at 1 — "Paw this open Safari").
    /// Never act on this alone: it only nominates an utterance for on-device
    /// AI confirmation, so ambient speech that merely resembles the wake
    /// word still can't trigger anything by itself. Filler-tolerant, but
    /// never glued-speech-tolerant — distance 2 plus a mid-utterance start
    /// would be two loosenings at once.
    public func nearWakeRemainder(_ transcript: String) -> String? {
        guard let match = wakeMatch(in: transcript, tolerance: 2),
              match.trusted else { return nil }
        return match.remainder
    }

    /// True when a remainder parses to a plain deterministic command (or
    /// typing) — the acceptance bar for glued-speech wake matches, and (via
    /// `UtteranceGate.decide(strictCommandBar:)`) for what the armed capture
    /// window may take when strict wake is on.
    public func remainderIsDeterministicCommand(_ remainder: String) -> Bool {
        let result = parseRemainder(remainder)
        if !result.typing.isEmpty { return true }
        switch result.command {
        case nil, .resolve:
            return false
        default:
            return true
        }
    }

    /// Interpret one finalized utterance.
    public func parse(_ transcript: String) -> VoiceParseResult {
        guard let remainder = wakeRemainder(transcript) else {
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

        // "type …" / "dictate …" types its payload — one-shot, and it owns
        // the WHOLE utterance: typed text legitimately contains "and".
        if let payload = typePayload(cleaned: cleaned, tokens: tokens) {
            return VoiceParseResult(typing: payload.isEmpty ? [] : [.type(payload)])
        }
        // "open chrome and go to youtube dot com": when EVERY clause parses
        // on its own, the composite executes deterministically in order —
        // the visual loop never sees it.
        if let sequence = clauseSequence(cleaned: cleaned, tokens: tokens) {
            return VoiceParseResult(command: sequence)
        }
        if let command = matchCommandVerb(cleaned: cleaned, tokens: tokens) {
            return VoiceParseResult(command: command)
        }
        return VoiceParseResult(command: .resolve(transcript: cleaned))
    }

    // MARK: - Clause sequences

    /// Splits a multi-clause utterance at standalone "and"/"then" tokens and
    /// parses each clause independently. Returns a `.sequence` only when
    /// every clause parses to a plain command — one clause the grammar
    /// can't own sends the whole utterance down the ladder instead, and
    /// safety phrases (stop/cancel) never take part in a sequence at all.
    /// This is what keeps "go to fish and chips dot com" whole (clause two
    /// isn't verb-led, so the split fails) while "pause this, open a new
    /// tab, and go to youtube dot com" becomes three verified steps.
    private func clauseSequence(cleaned: String, tokens: [String]) -> VoiceCommand? {
        let words = cleaned.split(whereSeparator: { $0.isWhitespace }).map(String.init)
        var clauses: [[String]] = []
        var current: [String] = []
        func closeClause() {
            if !current.isEmpty {
                clauses.append(current)
                current = []
            }
        }
        for word in words {
            let normalized = Self.normalize(word)
            if normalized == "and" || normalized == "then" {
                closeClause()
                continue
            }
            current.append(word)
            // The recognizer punctuates list-style commands ("pause this,
            // open a new tab, and …") — a trailing comma ends a clause.
            if word.hasSuffix(",") || word.hasSuffix(";") {
                closeClause()
            }
        }
        closeClause()
        guard clauses.count >= 2, clauses.count <= 4 else { return nil }

        var commands: [VoiceCommand] = []
        for clause in clauses {
            let clauseText = Self.trimTrailingNoise(clause.joined(separator: " "))
            let clauseTokens = Self.normalize(clauseText)
                .split(separator: " ").map(String.init)
            guard !clauseTokens.isEmpty,
                  let command = matchCommandVerb(cleaned: clauseText, tokens: clauseTokens) else {
                return nil
            }
            switch command {
            case .resolve, .sequence, .stopVoiceControl, .cancelActivity:
                // Needs the screen, or is a safety phrase — the utterance
                // stays whole.
                return nil
            default:
                commands.append(command)
            }
        }
        return .sequence(commands)
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

        // "pause" / "play" — the hardware media key. macOS routes it to the
        // now-playing app, which is exactly what the speaker means, no
        // matter which app is frontmost.
        if Self.mediaPlayPausePhrases.contains(normalizedJoined) {
            return .mediaKey(.playPause)
        }

        // Window and edit chords — the shortcuts everyone means by the bare
        // phrase. Whole-utterance only, same rule as above.
        if let chord = Self.phraseChords[normalizedJoined] {
            return .press(chord)
        }

        // "open a new tab" means ⌘T, not an app named "a new tab": strip a
        // leading open/make/create verb (plus "up" and articles) and retry
        // the chord table, so browser furniture gets its shortcut instead of
        // wandering down the app-launch path.
        if let chord = Self.phraseChords[Self.strippedChordPhrase(tokens: tokens)] {
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

        if let app = payload(after: ["open up", "pull up", "bring up", "open", "launch"],
                             cleaned: cleaned, tokens: tokens),
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

    /// Whole-clause phrases that mean the hardware play/pause key.
    private static let mediaPlayPausePhrases: Set<String> = [
        "pause", "pause this", "pause it", "pause that",
        "pause the video", "pause the music", "pause the song",
        "pause playback", "pause the movie",
        "play", "play it", "resume", "resume playback", "unpause",
    ]

    /// "open a new tab" → "new tab": drop one leading open/make/create verb
    /// (with an optional "up") and any articles, so furniture phrases land
    /// on their chord. Returns the stripped normalized phrase (which may
    /// simply not be in the chord table — that's fine).
    static func strippedChordPhrase(tokens: [String]) -> String {
        var rest = tokens[...]
        if let first = rest.first, ["open", "make", "create", "start"].contains(first) {
            rest = rest.dropFirst()
            if rest.first == "up" { rest = rest.dropFirst() }
        }
        while let first = rest.first, ["a", "an", "the", "another"].contains(first) {
            rest = rest.dropFirst()
        }
        return rest.joined(separator: " ")
    }

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

    /// One wake-word hit inside an utterance.
    public struct WakeMatch: Equatable, Sendable {
        public var remainder: String
        /// True when the wake word was utterance-initial or preceded only by
        /// filler — trusted outright. False means it was glued after other
        /// speech, which needs the deterministic-command bar.
        public var trusted: Bool
    }

    /// Filler people front commands with, transcribed faithfully by the
    /// recognizer. Skipping these before the wake word costs nothing:
    /// matching the wake word itself is still required.
    private static let leadingFillerTokens: Set<String> = [
        "um", "uh", "umm", "uhh", "er", "erm", "hmm", "mm",
        "hey", "hi", "yo", "oh", "ah", "so", "well", "yeah", "yes",
        "ok", "okay", "and", "then", "now", "please", "alright", "right",
    ]

    /// How far into an utterance the wake word may sit (chunks skipped).
    private static let maxWakeSkip = 3

    /// Fuzzy (edit-distance) wake matching needs candidates at least this
    /// long: at five characters, one edit reaches common names ("pavis" ± 1
    /// = "Davis", "Paris"). Shorter wake words and aliases still match —
    /// exactly, as written.
    public static let fuzzyMinCandidateLength = 6

    /// True when this wake word (or alias) is long enough for edit-distance
    /// tolerance, measured on the same folded token matching uses ("Paw
    /// Viz" → "pawviz"). Settings shows a hint when it isn't, so nobody
    /// discovers by mishearing that a short wake word matches strictly.
    public static func supportsFuzzyMatching(_ wakeWord: String) -> Bool {
        foldedWakeToken(wakeWord).count >= fuzzyMinCandidateLength
    }

    /// Finds the wake word within the first few chunks of the utterance.
    /// Skipped filler keeps full trust; skipped non-filler (the recognizer
    /// glued ambient speech to a command segment) is matched but marked
    /// untrusted for the caller's stricter acceptance bar.
    public func wakeMatch(in transcript: String, tolerance: Int) -> WakeMatch? {
        let trimmed = transcript.trimmingCharacters(in: .whitespacesAndNewlines)
        let chunks = trimmed.split(whereSeparator: { $0.isWhitespace })
        guard !chunks.isEmpty else { return nil }
        for skip in 0...min(Self.maxWakeSkip, chunks.count - 1) {
            guard let remainder = matchWakeWord(
                in: trimmed, chunks: chunks, from: skip, tolerance: tolerance) else {
                continue
            }
            let trusted = chunks[0..<skip].allSatisfy {
                Self.leadingFillerTokens.contains(Self.normalize(String($0)))
            }
            return WakeMatch(remainder: remainder, trusted: trusted)
        }
        return nil
    }

    private func matchWakeWord(
        in transcript: String, chunks: [Substring], from start: Int, tolerance: Int
    ) -> String? {
        let chunks = Array(chunks[start...])
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
            // Fuzzy matching needs `fuzzyMinCandidateLength`+ character
            // candidates (at five, one edit reaches common names — "pavis"
            // ± 1 = "Davis", "Paris") and a shared initial letter (a garble
            // that loses the opening consonant is beyond rescuing; requiring
            // it keeps "Davis, open the meeting notes" ambient at every
            // tier). Short aliases still match — exactly, as written.
            let matched = candidates.contains(joined)
                || candidates.contains { candidate in
                    candidate.count >= Self.fuzzyMinCandidateLength
                        && candidate.first == joined.first
                        && abs(candidate.count - joined.count) <= tolerance
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
