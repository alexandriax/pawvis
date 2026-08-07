import Foundation
import FoundationModels
import PawvisCore

/// Resolves free-form voice commands ("click sign in", "close this tab")
/// against what's actually on screen, using the on-device Apple Intelligence
/// model with guided generation.
///
/// Live-probed design constraints (macOS 26.5):
/// - The model is text-only — screen pixels are pre-digested into an AX/OCR
///   element list. Context window is exactly 4096 tokens, so lists are capped
///   (~50 elements) and the session is recycled before it fills.
/// - One persistent, prewarmed session: guided responses drop from ~4–7 s
///   (fresh session) to ~0.6–1.3 s (reused, KV-prefix cached).
/// - Escalation (region → full screen) is driven HERE, not via model tool
///   calls — tool calling composed with guided generation loops until the
///   context overflows.
/// - `targetNotInContext` is reliable only for far misses; semantically
///   adjacent requests get force-matched ("click log out" → "Cancel"). A
///   label-similarity gate escalates those too.
@available(macOS 26.0, *)
@MainActor
enum VisualIntentResolver {
    static var isSupported: Bool {
        SystemLanguageModel.default.availability == .available
    }

    @Generable
    enum ResolvedAction: String, CaseIterable {
        case click
        case doubleClick
        case rightClick
        case typeText
        case pressKey
        case goToURL
        case openApp
        case switchToApp
        case scrollUp
        case scrollDown
        case none
    }

    @Generable
    struct ResolvedIntent {
        @Guide(description: "The action that fulfills the user's spoken request")
        var action: ResolvedAction

        @Guide(description: "For click actions: the index of the target element from the numbered list. Omit otherwise.")
        var elementIndex: Int?

        @Guide(description: "Payload: the URL for goToURL, the text for typeText, the key name for pressKey (e.g. 'return', 'escape'), the app name for openApp/switchToApp. Omit otherwise.")
        var argument: String?

        @Guide(description: "True only when the element the user refers to is not in the provided list and is probably elsewhere on the screen")
        var targetNotInContext: Bool
    }

    private static let instructions = """
        You control a macOS computer for a user speaking voice commands. You \
        are given what is visible on screen (a numbered list of UI elements \
        and text with their positions) and the user's spoken command. Decide \
        the single action that fulfills the command.

        Rules:
        - Prefer clicking a listed element when the command refers to \
        something visible; pick the element whose label best matches the \
        spoken words (labels may contain small recognition errors). Always \
        answer with the element's index number.
        - Spoken URLs arrive as words; convert them to a real URL for \
        goToURL. Examples: "git hub dot com slash anthropics" → \
        "github.com/anthropics"; "here's alexandria dot com" → \
        "heresalexandria.com"; "lobste dot rs" → "lobste.rs"; \
        "localhost colon three thousand" → "localhost:3000".
        - If the command refers to something that is NOT in the list, set \
        targetNotInContext to true and action to none.
        - If the command is not an action on this screen at all, set action \
        to none and targetNotInContext to false.
        """

    // MARK: - Session lifecycle

    private static var session: LanguageModelSession?
    private static var sessionUses = 0
    /// Each request adds prompt + response to the session transcript; recycle
    /// well before the 4096-token window fills.
    private static let maxSessionUses = 6

    /// Called when voice control starts: model warm-up happens in the
    /// background so the first command doesn't pay the ~5 s cold cost.
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

    // MARK: - Resolution

    /// Resolve and perform. Returns a HUD-ready outcome.
    static func resolveAndExecute(
        transcript: String,
        screenContext: ScreenContextProvider,
        executor: CommandExecutor
    ) async -> ExecutionOutcome {
        let regional = await screenContext.snapshot(scope: .regionAroundPointer)
        do {
            var snapshot = regional
            var intent = try await resolve(transcript: transcript, snapshot: snapshot)

            // Escalate to the whole screen when the model says the target
            // isn't nearby — or when it "found" a click target whose label
            // doesn't actually resemble the spoken words (the model
            // force-matches semantically adjacent requests).
            let suspicious = isClickish(intent.action)
                && !labelResemblesTranscript(intent, snapshot: snapshot, transcript: transcript)
            if intent.targetNotInContext || suspicious {
                snapshot = await screenContext.snapshot(scope: .fullScreen)
                intent = try await resolve(transcript: transcript, snapshot: snapshot)
            }
            return await perform(intent, snapshot: snapshot, transcript: transcript,
                                 executor: executor)
        } catch {
            // Context overflow or transient model failure: drop the session
            // (a fresh one is built lazily) and report.
            session = nil
            Log.voice.error("Visual intent resolution failed: \(error.localizedDescription, privacy: .public)")
            return .failed("Couldn't work out “\(transcript)”")
        }
    }

    private static func resolve(
        transcript: String, snapshot: ScreenContextSnapshot
    ) async throws -> ResolvedIntent {
        let prompt = """
            \(snapshot.promptDescription)

            Spoken command: “\(transcript)”
            """
        do {
            let session = activeSession(forceFresh: false)
            sessionUses += 1
            let response = try await session.respond(
                to: prompt, generating: ResolvedIntent.self,
                options: GenerationOptions(sampling: .greedy))
            return response.content
        } catch {
            // One retry on a fresh session (covers a filled-up transcript
            // window mid-session).
            let fresh = activeSession(forceFresh: true)
            sessionUses += 1
            let response = try await fresh.respond(
                to: prompt, generating: ResolvedIntent.self,
                options: GenerationOptions(sampling: .greedy))
            return response.content
        }
    }

    // MARK: - Guards

    private static func isClickish(_ action: ResolvedAction) -> Bool {
        action == .click || action == .doubleClick || action == .rightClick
    }

    /// True when at least one meaningful spoken word matches the chosen
    /// element's label (prefix match either way, so "sign" ~ "signing" and
    /// OCR misreads within reason still pass). Purely semantic matches
    /// ("gear icon" → "Settings") fail this and trigger one full-screen
    /// retry — which then resolves against the complete element list.
    private static func labelResemblesTranscript(
        _ intent: ResolvedIntent, snapshot: ScreenContextSnapshot, transcript: String
    ) -> Bool {
        guard let index = intent.elementIndex,
              snapshot.targets.indices.contains(index) else { return false }
        let stopWords: Set<String> = [
            "click", "tap", "press", "the", "on", "button", "link", "that",
            "this", "it", "a", "an", "to", "double", "right",
        ]
        let spoken = tokens(of: transcript).filter { $0.count >= 3 && !stopWords.contains($0) }
        guard !spoken.isEmpty else { return true } // nothing to compare — trust the model
        let label = tokens(of: snapshot.targets[index].label)
        for s in spoken {
            for l in label where l.hasPrefix(s) || s.hasPrefix(l) {
                return true
            }
        }
        return false
    }

    private static func tokens(of s: String) -> [String] {
        s.lowercased()
            .map { $0.isLetter || $0.isNumber ? $0 : " " }
            .reduce(into: "") { $0.append($1) }
            .split(separator: " ")
            .map(String.init)
    }

    // MARK: - Execution

    private static func perform(
        _ intent: ResolvedIntent,
        snapshot: ScreenContextSnapshot,
        transcript: String,
        executor: CommandExecutor
    ) async -> ExecutionOutcome {
        func target() -> ScreenTarget? {
            guard let index = intent.elementIndex,
                  snapshot.targets.indices.contains(index) else { return nil }
            return snapshot.targets[index]
        }

        switch intent.action {
        case .click, .doubleClick, .rightClick:
            guard let target = target() else {
                return .failed("Couldn't find that on screen")
            }
            let kind: ClickKind = intent.action == .doubleClick ? .double
                : intent.action == .rightClick ? .right : .left
            executor.click(kind, at: target.center)
            return .done(notice: "Clicked “\(target.label)”")

        case .typeText:
            guard let text = intent.argument, !text.isEmpty else {
                return .failed("Nothing to type")
            }
            executor.type(text)
            return .done(notice: nil)

        case .pressKey:
            guard let name = intent.argument,
                  let chord = SpokenKeyParser.chord(
                    from: name.lowercased().split(separator: " ").map(String.init)) else {
                return .failed("Didn't recognize that key")
            }
            return await executor.execute(.press(chord))

        case .goToURL:
            guard let raw = intent.argument,
                  let url = SpokenURLNormalizer.normalize(raw) ?? (raw.contains(".") ? raw : nil) else {
                return .failed("Didn't catch the address")
            }
            return await executor.execute(.goTo(url: url))

        case .openApp:
            guard let app = intent.argument else { return .failed("Which app?") }
            return await executor.execute(.open(app: app))

        case .switchToApp:
            guard let app = intent.argument else { return .failed("Which app?") }
            return await executor.execute(.switchTo(app: app))

        case .scrollUp:
            return await executor.execute(.scroll(direction: .up, amount: .step))

        case .scrollDown:
            return await executor.execute(.scroll(direction: .down, amount: .step))

        case .none:
            return .failed("Couldn't work out “\(transcript)”")
        }
    }
}
