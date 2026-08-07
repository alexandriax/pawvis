import Foundation
import FoundationModels
import PawvisCore

/// Maps a spoken command (already stripped of the wake word) to a
/// constrained intent with the on-device Apple Intelligence model. This is
/// the robustness layer for everything the deterministic grammar doesn't
/// match exactly — speech recognition garbles verbs and word boundaries, and
/// guided generation over an enum action space absorbs that (live-probed:
/// 10/10 intent classifications with the enum-typed action field, ~1 s on a
/// warm reused session).
///
/// Screen-referencing commands ("click sign in") come back as
/// `.screenAction` and are handled by `VisualIntentResolver`, which builds
/// the around-the-pointer context; this mapper deliberately sees only the
/// transcript, keeping its prompt tiny and fast.
@available(macOS 26.0, *)
@MainActor
enum IntentMapper {
    static var isSupported: Bool {
        SystemLanguageModel.default.availability == .available
    }

    @Generable
    enum Action: String, CaseIterable {
        case openApp
        case switchToApp
        case goToURL
        case webSearch
        case typeText
        case pressKey
        case clickAtPointer
        case rightClickAtPointer
        case doubleClickAtPointer
        case scrollUp
        case scrollDown
        case screenAction
        case stopListening
        case none
    }

    @Generable
    struct MappedIntent {
        @Guide(description: "The intent behind the user's spoken command")
        var action: Action

        @Guide(description: "The parameter: app name for openApp/switchToApp, URL for goToURL, query for webSearch, the exact text for typeText, key name (e.g. 'return', 'command shift t') for pressKey. Omit for other actions.")
        var argument: String?
    }

    private static let instructions = """
        You map spoken commands to intents for controlling a Mac. The text \
        comes from speech recognition, so words may be slightly garbled, \
        split, or misheard — infer the most plausible intent.

        Rules:
        - openApp launches an app; switchToApp brings a running one forward.
        - Spoken URLs arrive as words; convert them to a real URL for \
        goToURL. NEVER invent path segments or subdomains that weren't \
        spoken; drop connector words that are clearly the misheard word \
        "to" ("two", "too"). Examples: "git hub dot com slash anthropics" \
        → "github.com/anthropics"; "go two reddit dot com" → "reddit.com"; \
        "here's alexandria dot com" → "heresalexandria.com"; "lobste dot \
        rs" → "lobste.rs"; "localhost colon three thousand" → \
        "localhost:3000".
        - "go to X" where X is not a web address is a webSearch.
        - typeText's argument is EXACTLY the text to type, nothing added.
        - screenAction is for commands that refer to ANY named or described \
        target on the screen (a button, link, field, tab, window, image) — \
        "click sign in", "click the sign in button", "close this tab", \
        "select the third result". clickAtPointer (and its right/double \
        variants) is ONLY for a bare click with no target, where the mouse \
        already is.
        - stopListening is for ending voice control ("stop listening", \
        "go to sleep").
        - none only when the words don't amount to a computer command at all.
        """

    // MARK: - Session lifecycle (same pattern as VisualIntentResolver)

    private static var session: LanguageModelSession?
    private static var sessionUses = 0
    /// Prompts here are one line each; the transcript window still fills
    /// eventually, so recycle periodically.
    private static let maxSessionUses = 20

    static func prewarm() {
        guard isSupported else { return }
        _ = activeSession(forceFresh: false)
    }

    private static func activeSession(forceFresh: Bool) -> LanguageModelSession {
        if !forceFresh, let session, sessionUses < maxSessionUses {
            return session
        }
        let fresh = LanguageModelSession(instructions: instructions)
        fresh.prewarm()
        session = fresh
        sessionUses = 0
        return fresh
    }

    // MARK: - Mapping

    static func map(_ transcript: String) async throws -> MappedIntent {
        let prompt = "Spoken command: “\(transcript)”"
        do {
            let session = activeSession(forceFresh: false)
            sessionUses += 1
            let response = try await session.respond(
                to: prompt, generating: MappedIntent.self,
                options: GenerationOptions(sampling: .greedy))
            return response.content
        } catch {
            // One retry on a fresh session (covers a filled-up transcript
            // window mid-session).
            let fresh = activeSession(forceFresh: true)
            sessionUses += 1
            let response = try await fresh.respond(
                to: prompt, generating: MappedIntent.self,
                options: GenerationOptions(sampling: .greedy))
            return response.content
        }
    }

    /// Convert a mapped intent to an executable command. `.screenAction`,
    /// `.stopListening`, and `.none` are not executor commands — the
    /// controller handles those.
    static func command(for intent: MappedIntent) -> VoiceCommand? {
        switch intent.action {
        case .openApp:
            guard let app = intent.argument, !app.isEmpty else { return nil }
            return .open(app: app)
        case .switchToApp:
            guard let app = intent.argument, !app.isEmpty else { return nil }
            return .switchTo(app: app)
        case .goToURL:
            guard let raw = intent.argument,
                  let url = SpokenURLNormalizer.normalize(raw) ?? (raw.contains(".") ? raw : nil) else {
                return nil
            }
            return .goTo(url: url)
        case .webSearch:
            guard let query = intent.argument, !query.isEmpty else { return nil }
            return .webSearch(query: query)
        case .typeText:
            // Typed via the executor as a press-free action; represented as
            // a resolve-free command by the controller (it types directly).
            return nil
        case .pressKey:
            guard let name = intent.argument,
                  let chord = SpokenKeyParser.chord(
                    from: name.lowercased().split(separator: " ").map(String.init)) else {
                return nil
            }
            return .press(chord)
        case .clickAtPointer: return .click(.left)
        case .rightClickAtPointer: return .click(.right)
        case .doubleClickAtPointer: return .click(.double)
        case .scrollUp: return .scroll(direction: .up, amount: .step)
        case .scrollDown: return .scroll(direction: .down, amount: .step)
        case .screenAction, .stopListening, .none: return nil
        }
    }
}
