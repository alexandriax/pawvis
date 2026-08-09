import Foundation
import FoundationModels
import PawvisCore

/// Second opinion for spoken app names the deterministic catalog can't
/// resolve even with its phonetic tier ("clawed ai desktop" for Claude).
/// The candidate list is ranked deterministically and kept short; the
/// on-device model answers exactly one question — which listed name sounds
/// like what was heard? Its answer is trusted only when it names a listed
/// candidate verbatim (fold-compared); the code, not the model, then
/// resolves and opens the app. Same division of labor as WakeRescuer: the
/// 3B model classifies against an enumerated list, it never invents,
/// rewrites, or sequences.
@available(macOS 26.0, *)
@MainActor
enum AppNameRescuer {
    static var isSupported: Bool {
        SystemLanguageModel.default.availability == .available
    }

    @Generable
    struct Choice {
        @Guide(description: "The one application name from the offered list that sounds like what was heard, copied exactly — or NONE when nothing on the list is a plausible mishearing.")
        var appName: String
    }

    private static let instructions = """
        A Mac voice assistant heard the user name an application, but no \
        installed application matches the transcribed words. Speech \
        recognition garbles names it doesn't know — "clod desktop app", \
        "clawed", or "cloud" often mean "Claude"; "crone" means "Chrome". \
        You get the heard words and a list of installed applications. \
        Answer with the one listed name that SOUNDS like the heard words \
        when read aloud, copied exactly from the list — or NONE when \
        nothing on the list is a plausible mishearing.
        """

    // MARK: - Session lifecycle (same pattern as WakeRescuer)

    private static var session: LanguageModelSession?
    private static var sessionUses = 0
    private static let maxSessionUses = 20

    private static func activeSession(forceFresh: Bool) -> LanguageModelSession {
        if !forceFresh, let session, sessionUses < maxSessionUses {
            return session
        }
        let fresh = LanguageModelSession(instructions: instructions)
        session = fresh
        sessionUses = 0
        return fresh
    }

    // MARK: - Resolution

    /// The installed-app name the user most plausibly said, or nil. The
    /// returned string is always one of `installed`, verbatim.
    static func resolve(spoken: String, amongInstalled installed: [String]) async throws -> String? {
        let candidates = rankedCandidates(for: spoken, among: installed)
        guard !candidates.isEmpty else { return nil }
        let list = candidates.map { "- \($0)" }.joined(separator: "\n")
        let prompt = "Heard: “\(spoken)”\nInstalled applications:\n\(list)"
        let answer: String
        do {
            let session = activeSession(forceFresh: false)
            sessionUses += 1
            answer = try await session.respond(
                to: prompt, generating: Choice.self,
                options: GenerationOptions(sampling: .greedy)).content.appName
        } catch {
            // One retry on a fresh session (covers a filled-up transcript
            // window mid-session).
            let fresh = activeSession(forceFresh: true)
            sessionUses += 1
            answer = try await fresh.respond(
                to: prompt, generating: Choice.self,
                options: GenerationOptions(sampling: .greedy)).content.appName
        }
        let folded = AppNameMatch.fold(answer)
        guard !folded.isEmpty else { return nil }
        return candidates.first { AppNameMatch.fold($0) == folded }
    }

    // MARK: - Deterministic candidate ranking

    /// The model reads a SHORT list (small models lose the plot on long
    /// ones): rank every installed name by cheap sound-alike signals against
    /// the fully-stripped query and keep the closest few.
    private static func rankedCandidates(
        for spoken: String, among installed: [String], limit: Int = 24
    ) -> [String] {
        let query = AppNameMatch.fold(spoken)
        let stripped = AppNameMatch.strippedVariants(query).last ?? query
        guard !stripped.isEmpty else { return [] }
        let strippedKey = AppNameMatch.phoneticKey(stripped)
        let ranked = installed
            .map { name -> (name: String, cost: Int) in
                let folded = AppNameMatch.fold(name)
                let firstToken = folded.split(separator: " ").first.map(String.init) ?? folded
                var cost = min(
                    editDistance(stripped, folded), editDistance(stripped, firstToken))
                if strippedKey.count >= 2,
                   strippedKey == AppNameMatch.phoneticKey(firstToken)
                    || strippedKey == AppNameMatch.phoneticKey(folded) {
                    cost = 0
                }
                return (name, cost)
            }
            .sorted { ($0.cost, $0.name) < ($1.cost, $1.name) }
        return ranked.prefix(limit).map(\.name)
    }

    private static func editDistance(_ a: String, _ b: String) -> Int {
        let a = Array(a), b = Array(b)
        if a.isEmpty { return b.count }
        if b.isEmpty { return a.count }
        var prev = Array(0...b.count)
        var cur = [Int](repeating: 0, count: b.count + 1)
        for i in 1...a.count {
            cur[0] = i
            for j in 1...b.count {
                cur[j] = min(
                    prev[j] + 1, cur[j - 1] + 1,
                    prev[j - 1] + (a[i - 1] == b[j - 1] ? 0 : 1))
            }
            swap(&prev, &cur)
        }
        return prev[b.count]
    }
}
