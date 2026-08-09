import Foundation

/// Pure spoken-name ↔ app-name matching, shared by the app layer's catalog
/// (resolving "chrome" to /Applications/Google Chrome.app) and the autopilot's
/// completion checks (is the frontmost app the one the step named?). Lives in
/// PawvisCore so the scoring rules are unit-testable without AppKit.
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

        // Every query token is a prefix of some name token, in order:
        // "google chrome" ~ "google chrome", "chrome" ~ "google chrome".
        var ni = 0
        var allPrefix = true
        for qt in queryTokens {
            var found = false
            while ni < nameTokens.count {
                if nameTokens[ni].hasPrefix(qt) { found = true; ni += 1; break }
                ni += 1
            }
            if !found { allPrefix = false; break }
        }
        if allPrefix {
            // Prefer tighter names ("Google Chrome" over "Chrome Remote
            // Desktop Host Uninstaller" for "chrome").
            return 500 - min(nameTokens.count - queryTokens.count, 40) * 10
        }

        // Initialism: "vs code" won't hit this, but "gc" → "Google Chrome".
        let initialism = nameTokens.compactMap(\.first).map(String.init).joined()
        if initialism == query.replacingOccurrences(of: " ", with: "") { return 300 }

        if folded.hasPrefix(query) { return 250 }
        if folded.contains(query) { return 150 }
        return 0
    }

    /// True when the spoken name plausibly names the given app — the
    /// autopilot's frontmost-app completion check.
    public static func matches(spoken: String, appName: String) -> Bool {
        matchScore(query: fold(spoken), name: appName) > 0
    }
}
