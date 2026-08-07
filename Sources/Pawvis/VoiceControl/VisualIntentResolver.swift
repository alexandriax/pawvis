import Foundation
import FoundationModels
import PawvisCore

/// Resolves free-form voice commands ("click sign in", "close this tab")
/// against what's actually on screen, using the on-device Apple Intelligence
/// model with guided generation.
///
/// Escalation: the first attempt sees only the region around the pointer
/// (fast, small prompt). If the model says the target isn't in that context,
/// one retry sees the whole screen.
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
        spoken words (labels may contain small recognition errors).
        - Spoken URLs arrive as words ("alexandria dot com"); convert them to \
        a real URL for goToURL.
        - If the command refers to something that is NOT in the list, set \
        targetNotInContext to true and action to none.
        - If the command is not an action on this screen at all, set action \
        to none and targetNotInContext to false.
        """

    /// Resolve and perform. Returns a HUD-ready outcome.
    static func resolveAndExecute(
        transcript: String,
        screenContext: ScreenContextProvider,
        executor: CommandExecutor
    ) async -> ExecutionOutcome {
        let regional = await screenContext.snapshot(scope: .regionAroundPointer)
        do {
            var intent = try await resolve(transcript: transcript, snapshot: regional)
            var snapshot = regional
            if intent.targetNotInContext {
                // The target isn't near the pointer — look at the whole screen.
                snapshot = await screenContext.snapshot(scope: .fullScreen)
                intent = try await resolve(transcript: transcript, snapshot: snapshot)
            }
            return await perform(intent, snapshot: snapshot, transcript: transcript,
                                 executor: executor)
        } catch {
            Log.voice.error("Visual intent resolution failed: \(error.localizedDescription, privacy: .public)")
            return .failed("Couldn't work out “\(transcript)”")
        }
    }

    private static func resolve(
        transcript: String, snapshot: ScreenContextSnapshot
    ) async throws -> ResolvedIntent {
        // A fresh session per request: no cross-command context to carry, and
        // sessions accumulate transcript otherwise.
        let session = LanguageModelSession(instructions: instructions)
        let prompt = """
            \(snapshot.promptDescription)

            Spoken command: “\(transcript)”
            """
        let response = try await session.respond(to: prompt, generating: ResolvedIntent.self)
        return response.content
    }

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
