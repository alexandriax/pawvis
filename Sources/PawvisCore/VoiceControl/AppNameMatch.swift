import Foundation

/// Pure spoken-name ↔ app-name matching, shared by the app layer's catalog
/// (resolving "chrome" to /Applications/Google Chrome.app) and the autopilot's
/// completion checks (is the frontmost app the one the step named?). Lives in
/// PawvisCore so the scoring rules are unit-testable without AppKit.
///
/// Spoken names arrive damaged in two deterministic-fixable ways, so matching
/// has tiers beyond literal prefix/contains: a phonetic tier ("clod",
/// "clawed", and "cloud" all key like "Claude" — recognizers garble names
/// they don't know), and query variants that peel spoken padding ("the …",
/// "… desktop app") the on-disk name doesn't carry.
public enum AppNameMatch {
    /// Lowercased, alphanumerics+spaces only, collapsed.
    public static func fold(_ s: String) -> String {
        s.lowercased()
            .map { $0.isLetter || $0.isNumber ? $0 : " " }
            .reduce(into: "") { $0.append($1) }
            .split(separator: " ")
            .joined(separator: " ")
    }

    /// Score a spoken query (pre-folded) against an app name. 0 = no match.
    public static func matchScore(query: String, name: String) -> Int {
        let folded = fold(name)
        guard !folded.isEmpty, !query.isEmpty else { return 0 }
        if folded == query { return 1000 }

        let nameTokens = folded.split(separator: " ").map(String.init)
        let queryTokens = query.split(separator: " ").map(String.init)

        // Every query token matches some name token, in order — as a literal
        // prefix ("chrome" ~ "google chrome") or, failing that, phonetically
        // ("clod" ~ "claude"). A walk that needed the phonetic tier scores
        // well below one that didn't.
        var ni = 0
        var allMatch = true
        var usedPhonetic = false
        for qt in queryTokens {
            var found = false
            let qKey = phoneticKey(qt)
            while ni < nameTokens.count {
                let nt = nameTokens[ni]
                ni += 1
                if nt.hasPrefix(qt) { found = true; break }
                // Length ≥ 2: one-consonant keys ("up" → "p") collide with
                // half the catalog.
                if qKey.count >= 2, qKey == phoneticKey(nt) {
                    usedPhonetic = true
                    found = true
                    break
                }
            }
            if !found { allMatch = false; break }
        }
        if allMatch, !usedPhonetic {
            // Prefer tighter names ("Google Chrome" over "Chrome Remote
            // Desktop Host Uninstaller" for "chrome").
            return 500 - min(nameTokens.count - queryTokens.count, 40) * 10
        }
        let phoneticScore = allMatch
            ? 220 - min(nameTokens.count - queryTokens.count, 10) * 10
            : 0

        // Initialism: "vs code" won't hit this, but "gc" → "Google Chrome".
        let initialism = nameTokens.compactMap(\.first).map(String.init).joined()
        if initialism == query.replacingOccurrences(of: " ", with: "") { return 300 }

        if folded.hasPrefix(query) { return 250 }
        return max(phoneticScore, folded.contains(query) ? 150 : 0)
    }

    /// Soundex-style consonant skeleton: vowels and near-vowels (h/w/y) drop
    /// out, related consonants collapse into one class letter, and runs
    /// dedupe — "clod", "clawed", "cloud", and "claude" all key to "klt".
    /// Deterministic mishearing tolerance; no model involved.
    public static func phoneticKey(_ token: String) -> String {
        var key = ""
        for ch in token.lowercased() {
            let mapped: Character?
            switch ch {
            case "b", "f", "p", "v": mapped = "b"
            case "c", "g", "j", "k", "q", "s", "x", "z": mapped = "k"
            case "d", "t": mapped = "t"
            case "l": mapped = "l"
            case "m", "n": mapped = "m"
            case "r": mapped = "r"
            default: mapped = nil // vowels, h/w/y, digits, punctuation
            }
            if let mapped, key.last != mapped { key.append(mapped) }
        }
        return key
    }

    /// Folded variants of a spoken query worth trying when the literal query
    /// doesn't match: leading articles dropped, then trailing generic words
    /// peeled one at a time — "the clod desktop app" → "clod desktop app" →
    /// "clod desktop" → "clod". Ordered most-complete-first; callers dock
    /// later variants so a fuller match always outranks a stripped one
    /// ("github desktop" resolves GitHub Desktop, not GitHub).
    public static func strippedVariants(_ query: String) -> [String] {
        var tokens = query.split(separator: " ").map(String.init)
        var variants: [String] = []
        let articles: Set<String> = ["the", "a", "an", "my"]
        while let first = tokens.first, articles.contains(first), tokens.count > 1 {
            tokens.removeFirst()
            variants.append(tokens.joined(separator: " "))
        }
        let fillers: Set<String> = ["app", "application", "desktop"]
        while let last = tokens.last, fillers.contains(last), tokens.count > 1 {
            tokens.removeLast()
            variants.append(tokens.joined(separator: " "))
        }
        return variants
    }

    /// Best score for a spoken name against an app name across the query's
    /// stripped variants (each dock keeps fuller matches ahead on ties).
    public static func bestScore(spoken: String, name: String) -> Int {
        let query = fold(spoken)
        var best = matchScore(query: query, name: name)
        for (index, variant) in strippedVariants(query).enumerated() {
            let score = matchScore(query: variant, name: name)
            if score > 0 { best = max(best, score - (index + 1) * 5) }
        }
        return best
    }

    /// True when the spoken name plausibly names the given app — the
    /// autopilot's frontmost-app completion check.
    public static func matches(spoken: String, appName: String) -> Bool {
        bestScore(spoken: spoken, name: appName) > 0
    }

    // MARK: - Generic web qualifiers

    /// Qualifiers that name "the web" or "a browser" in general, not any one
    /// specific app — "the browser", "my browser", "the internet"… A speaker
    /// who says one of these hasn't actually named an app; it means "no app
    /// in particular", i.e. fall back to the default browser. Shared by two
    /// call sites that both receive free-form spoken text: intent
    /// translation (`TranslationPolicy`, the on-device model regularly emits
    /// these on plain search requests) and the deterministic grammar's own
    /// qualifier, which reaches the executor unresolved on purpose — "the
    /// browser-word list is vocabulary, not app resolution" — so without
    /// this check "the browser" fell through to fuzzy app resolution, where
    /// stripping its leading article left "browser", a prefix match for any
    /// installed app literally named Browser (Brave, Tor). One list, so
    /// every path treats "the browser" identically.
    public static let genericWebQualifiers: Set<String> = [
        "web", "the web", "internet", "the internet", "online",
        "browser", "the browser", "my browser", "a browser",
        "default browser", "the default browser",
    ]

    /// An app qualifier ready for resolution: nil when `spoken` is nil,
    /// empty/whitespace, or names the web/a browser generically (see
    /// `genericWebQualifiers`) — callers should treat all three exactly like
    /// "no app was named" rather than attempt to resolve them against an
    /// installed or running app. Otherwise the trimmed qualifier, so a real
    /// app name ("chrome", "safari") passes through for resolution.
    public static func resolvedAppQualifier(_ spoken: String?) -> String? {
        guard let spoken else { return nil }
        let trimmed = spoken.trimmingCharacters(in: .whitespacesAndNewlines)
        guard !trimmed.isEmpty,
              !genericWebQualifiers.contains(VoiceControlParser.normalize(trimmed)) else {
            return nil
        }
        return trimmed
    }
}
