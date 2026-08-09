import AppKit
import Foundation
import FoundationModels
import PawvisCore

/// Carries out free-form voice commands ("open Notes and start a new note")
/// as an iterative loop on the on-device Apple Intelligence model: look at
/// the screen, decide the single next action, do it, look again — until the
/// goal is met or a budget runs out. Replaces the one-shot IntentMapper +
/// VisualIntentResolver pair: a `goalComplete` flag in the step schema keeps
/// single-action commands ("click sign in") at exactly one model round, so
/// nothing got slower by becoming a loop.
///
/// Live-probed design constraints (macOS 26.5, inherited from the resolver
/// this grew out of):
/// - The model is text-only — screen pixels are pre-digested into an AX/OCR
///   element list. Context window is exactly 4096 tokens.
/// - Guided responses: ~0.6–1.3 s on a warm reused session, ~4–7 s fresh;
///   `prewarm()` hides the cold cost. Enum-typed action fields measured
///   10/10 reliable.
/// - Tool calling composed with guided generation loops until the context
///   overflows — the loop is driven HERE, in Swift, never via model tools.
/// - Every prompt is self-contained (goal + history + fresh elements), so
///   the session transcript is disposable: the token ledger recycles it
///   proactively, and the replacement prewarms during settle waits, making a
///   mid-run recycle cost nothing observable.
/// - All decision rules (scopes, budgets, guards, no-progress) live in
///   `AutopilotPolicy` — pure PawvisCore, unit-tested; this file only owns
///   the model session and the side effects.
@available(macOS 26.0, *)
@MainActor
final class AutopilotEngine {
    static var isSupported: Bool {
        SystemLanguageModel.default.availability == .available
    }

    enum Outcome: Equatable {
        case finished(notice: String?)
        case failed(String)
        case cancelled
    }

    // MARK: - Step schema

    @Generable
    enum StepAction: String, CaseIterable {
        case click, doubleClick, rightClick
        case typeText, pressKey
        case openApp, switchToApp
        case goToURL, webSearch
        case scrollUp, scrollDown
        case wait
        case done
        case cannotProceed
    }

    @Generable
    struct StepChoice {
        @Guide(description: "The single next action that makes progress toward the goal")
        var action: StepAction

        @Guide(description: "For click actions and for typeText into a listed input field: the target element's index number from the list. Omit otherwise.")
        var elementIndex: Int?

        @Guide(description: "Payload: exact text for typeText, key name for pressKey (e.g. 'return', 'command shift t'), app name for openApp/switchToApp, URL for goToURL, query for webSearch. Omit for other actions.")
        var argument: String?

        @Guide(description: "True when this action is the LAST one the goal needs — after it runs, the goal is complete.")
        var goalComplete: Bool

        @Guide(description: "True only when the element the goal needs next is not in the provided list and is probably elsewhere on the screen")
        var targetNotInContext: Bool
    }

    private static let instructions = """
        You operate a macOS computer for a user who gave one spoken \
        instruction. You are shown the goal, the steps already taken, and a \
        fresh numbered list of what is on screen right now (UI elements and \
        text with their positions). Decide the SINGLE next action that makes \
        progress toward the goal. After it runs you will be shown the screen \
        again and asked for the next one.

        Rules:
        - Set goalComplete to true when THIS action is the last one the goal \
        needs. A one-action goal ("click sign in") is one step with \
        goalComplete true. Never keep acting after the goal is met.
        - If the goal is already satisfied and no action is needed, answer \
        done. If the goal cannot be completed, answer cannotProceed.
        - To click something visible, answer click with the target \
        element's index number from the list. Pick the element whose label \
        best matches; labels may contain small recognition errors.
        - To use an app's menus, first click the menu's name from the list \
        (File, Edit, View…); the opened menu's items appear in the next \
        screen list, then click the item.
        - typeText types the argument exactly, nothing added. When a listed \
        input field is the target, also give its elementIndex so it is \
        focused first.
        - openApp launches an app; switchToApp brings a running one \
        forward. The frontmost app is named at the top of the screen list.
        - Spoken URLs arrive as words; convert them to a real URL for \
        goToURL. NEVER invent path segments or subdomains that weren't \
        spoken; drop connector words that are clearly the misheard word \
        "to" ("two", "too"). Examples: "git hub dot com slash anthropics" \
        → "github.com/anthropics"; "here's alexandria dot com" → \
        "heresalexandria.com"; "lobste dot rs" → "lobste.rs"; "localhost \
        colon three thousand" → "localhost:3000".
        - "search for X" / "look up X" is a webSearch with X as the argument.
        - goToURL and webSearch arguments come ONLY from the goal's words. \
        Never copy an address or text you see in the element list — the \
        address bar shows where the user already is, not where they asked \
        to go.
        - pressKey presses one key or shortcut; the argument is its spoken \
        name ("return", "escape", "command shift t").
        - If the screen is still loading, or the last action's result has \
        not appeared yet, answer wait.
        - If the element the goal needs next is not in the list and is \
        probably elsewhere on the screen, set targetNotInContext to true \
        and answer cannotProceed; you may then be shown more of the screen.
        - scrollUp / scrollDown reveal content above or below when the \
        target should exist but is off screen.
        """

    private static let instructionTokens = AutopilotPolicy.estimatedTokens(instructions)
    /// What one prompt may spend: the window minus the instruction prefix
    /// and the response+headroom reserve. The ledger guarantees a session
    /// with at least this much room before every send.
    private static let promptBudget = AutopilotTokenLedger.windowTokens
        - instructionTokens - AutopilotTokenLedger.reservedTokens

    // MARK: - Translation schema

    @Generable
    enum TranslatedAction: String, CaseIterable {
        case openApp, switchToApp, goToURL, webSearch, pressKey, quitApp
        case needsScreen
    }

    @Generable
    struct TranslationChoice {
        @Guide(description: "The single machine intent the spoken command means; needsScreen when it refers to on-screen things or needs several actions")
        var action: TranslatedAction

        @Guide(description: "The app name, URL, search words, or key name the intent needs. Omit for needsScreen.")
        var argument: String?

        @Guide(description: "The app named to act in ('in Chrome' → 'Chrome'). Omit when none was named.")
        var app: String?
    }

    private static let translationInstructionTokens =
        AutopilotPolicy.estimatedTokens(TranslationPolicy.instructions)

    // MARK: - Session lifecycle

    private var session: LanguageModelSession?
    /// Prewarmed replacement, built during settle waits once the ledger says
    /// the next exchange won't fit — adopting it costs nothing observable.
    private var spare: LanguageModelSession?
    private var ledger = AutopilotTokenLedger(instructionTokens: AutopilotEngine.instructionTokens)

    /// The translation stage's own session — different instructions, its own
    /// ledger. It is the FIRST thing every free-form command hits, so it is
    /// prewarmed as eagerly as the loop's session.
    private var translationSession: LanguageModelSession?
    private var translationLedger = AutopilotTokenLedger(
        instructionTokens: AutopilotEngine.translationInstructionTokens)

    private let screenContext = ScreenContextProvider()

    /// Called when voice control starts, so the first command doesn't pay
    /// the ~5 s cold cost.
    func prewarm() {
        guard Self.isSupported else { return }
        if session == nil {
            session = Self.freshSession()
            ledger.reset()
        }
        if translationSession == nil {
            translationSession = Self.freshTranslationSession()
            translationLedger.reset()
        }
    }

    private static func freshSession() -> LanguageModelSession {
        let fresh = LanguageModelSession(instructions: instructions)
        fresh.prewarm()
        return fresh
    }

    private static func freshTranslationSession() -> LanguageModelSession {
        let fresh = LanguageModelSession(instructions: TranslationPolicy.instructions)
        fresh.prewarm()
        return fresh
    }

    // MARK: - Translation (free-form → one primitive)

    /// One screen-free guided-generation round: what single primitive does
    /// this utterance mean? Returns nil on model failure — the caller falls
    /// through to the visual loop, never the other way around. This stage
    /// exists because the on-device model is small: constrained one-sentence
    /// translation is the job it does reliably; sequencing GUI actions isn't.
    func translate(goal: String) async -> IntentTranslation? {
        guard Self.isSupported else { return nil }
        let prompt = TranslationPolicy.prompt(for: goal)
        let promptTokens = AutopilotPolicy.estimatedTokens(prompt)
        if translationSession == nil
            || translationLedger.shouldRecycle(nextPromptTokens: promptTokens) {
            translationSession = Self.freshTranslationSession()
            translationLedger.reset()
        }
        for attempt in 0..<2 {
            guard let session = translationSession else { return nil }
            do {
                translationLedger.record(promptTokens: promptTokens)
                let response = try await session.respond(
                    to: prompt, generating: TranslationChoice.self,
                    options: GenerationOptions(sampling: .greedy))
                return Self.mirror(response.content)
            } catch {
                if Task.isCancelled || error is CancellationError { return nil }
                Log.voice.error("Intent translation failed (attempt \(attempt + 1)): \(error.localizedDescription, privacy: .public)")
                // One retry on a fresh session (covers a filled window the
                // ledger's estimate missed); a second failure means the loop.
                translationSession = Self.freshTranslationSession()
                translationLedger.reset()
            }
        }
        return nil
    }

    private static func mirror(_ choice: TranslationChoice) -> IntentTranslation {
        IntentTranslation(
            intent: TranslatedIntent(rawValue: choice.action.rawValue) ?? .needsScreen,
            argument: choice.argument,
            app: choice.app)
    }

    private func activeSession() -> LanguageModelSession {
        if let session { return session }
        let adopted = spare ?? Self.freshSession()
        spare = nil
        session = adopted
        return adopted
    }

    private func adoptFreshSession() {
        session = spare ?? Self.freshSession()
        spare = nil
        ledger.reset()
    }

    /// During the settle wait, build the replacement the ledger already
    /// knows the next step will need — prewarming overlaps the wait.
    private func recycleAheadIfNeeded() {
        guard spare == nil,
              ledger.shouldRecycle(nextPromptTokens: 900) else { return }
        spare = Self.freshSession()
    }

    // MARK: - The loop

    /// Runs one goal to completion. Cancellation (a new command, "Pawvis
    /// stop", voice turning off) is checked at every boundary; clicks are
    /// synchronous down/up pairs inside the executor, so a cancel can never
    /// wedge a button down.
    func run(
        goal: String,
        executor: CommandExecutor,
        onStep: @escaping @MainActor (Int, String) -> Void
    ) async -> Outcome {
        let start = Date()
        var history: [AutopilotHistoryEntry] = []
        var proposals: [AutopilotPolicy.ProposedRecord] = []
        var consecutiveFailures = 0

        for stepIndex in 1...AutopilotPolicy.stepCap {
            if Task.isCancelled { return .cancelled }
            if Date().timeIntervalSince(start) > AutopilotPolicy.wallClockCap {
                return .failed("Ran out of time on “\(goal)”")
            }

            var scope = AutopilotPolicy.scope(stepIndex: stepIndex, goal: goal)
            var screen = await snapshot(scope: scope)
            if Task.isCancelled { return .cancelled }

            var step: AutopilotStep
            do {
                step = try await decide(goal: goal, history: history, screen: screen)
            } catch {
                if Task.isCancelled || error is CancellationError { return .cancelled }
                Log.voice.error("Autopilot step failed: \(error.localizedDescription, privacy: .public)")
                return .failed("Couldn't work out “\(goal)”")
            }
            if Task.isCancelled { return .cancelled }

            // Step-1 region escalation, straight from the old resolver: the
            // model says the target isn't nearby, or it "found" a click
            // target whose label doesn't resemble the goal (it force-matches
            // semantically adjacent requests). One retry on the full screen.
            if scope == .nearPointer {
                let suspicious = AutopilotPolicy.guardApplies(stepIndex: stepIndex, step: step)
                    && !AutopilotPolicy.labelResemblesGoal(
                        label: targetLabel(of: step, in: screen) ?? "",
                        goal: goal)
                if step.targetNotInContext || suspicious {
                    scope = .fullScreen
                    screen = await snapshot(scope: .fullScreen)
                    if Task.isCancelled { return .cancelled }
                    do {
                        step = try await decide(goal: goal, history: history, screen: screen)
                    } catch {
                        if Task.isCancelled || error is CancellationError { return .cancelled }
                        Log.voice.error("Autopilot escalation failed: \(error.localizedDescription, privacy: .public)")
                        return .failed("Couldn't work out “\(goal)”")
                    }
                    if Task.isCancelled { return .cancelled }
                }
            }

            switch step.action {
            case .done:
                // First-step done means there was nothing to do at all;
                // mid-run it's the natural finish for a goal whose last
                // action didn't announce itself.
                return .finished(notice: stepIndex == 1 ? "Already done" : "✓ \(goal)")

            case .cannotProceed:
                if step.targetNotInContext, scope == .fullScreen {
                    // The whole screen didn't contain the target. Record the
                    // miss and give the model another look — content may
                    // still be loading, or it may choose to scroll.
                    let entry = AutopilotPolicy.historyLine(
                        index: stepIndex, step: step, targetLabel: nil,
                        failure: "target not visible")
                    history.append(entry)
                    onStep(stepIndex, entry.line)
                    consecutiveFailures += 1
                    if consecutiveFailures > AutopilotPolicy.consecutiveFailureCap {
                        return .failed("Couldn't find what “\(goal)” needs on screen")
                    }
                    try? await Task.sleep(
                        for: .milliseconds(AutopilotPolicy.waitActionMilliseconds))
                    continue
                }
                return .failed("Couldn't see a way to do “\(goal)”")

            default:
                break
            }

            if case .invalid(let reason) = AutopilotPolicy.validate(
                step, elementCount: screen.elements.count) {
                let entry = AutopilotPolicy.historyLine(
                    index: stepIndex, step: step, targetLabel: nil, failure: reason)
                history.append(entry)
                onStep(stepIndex, entry.line)
                consecutiveFailures += 1
                if consecutiveFailures > AutopilotPolicy.consecutiveFailureCap {
                    return .failed("Couldn't finish “\(goal)” (\(reason))")
                }
                continue
            }

            let label = targetLabel(of: step, in: screen)
            let frontmostBefore = NSWorkspace.shared.frontmostApplication?.processIdentifier

            // Baseline for click-family completion claims. Always full
            // screen: the near-pointer region recenters on the moved
            // pointer, so a same-scope comparison would trivially differ.
            var completionBaseline: Int?
            if step.goalComplete,
               AutopilotPolicy.completionCheck(for: step) == .screenChanged {
                let baseline = screen.isFullScreen
                    ? screen : await snapshot(scope: .fullScreen)
                completionBaseline = AutopilotPolicy.screenSignature(baseline)
                if Task.isCancelled { return .cancelled }
            }

            let failure = await execute(step, screen: screen, executor: executor)

            // A completion claim is a hypothesis, not a result: settle, then
            // check the world before believing it. A click that changed
            // nothing, or an app that never came forward, is a failed step —
            // the run keeps going instead of ending on a fiction.
            var shortfall = failure
            var verifiedComplete = false
            if failure == nil, step.goalComplete {
                await settle(after: step.action, frontmostBefore: frontmostBefore,
                             executor: executor)
                if Task.isCancelled { return .cancelled }
                if let unmet = await completionShortfall(
                    of: step, baseline: completionBaseline, executor: executor) {
                    shortfall = unmet
                } else {
                    verifiedComplete = true
                }
            }

            let entry = AutopilotPolicy.historyLine(
                index: stepIndex, step: step, targetLabel: label, failure: shortfall)
            history.append(entry)
            onStep(stepIndex, entry.line)

            if verifiedComplete {
                return .finished(notice: "✓ \(goal)")
            }
            if let shortfall {
                consecutiveFailures += 1
                if consecutiveFailures > AutopilotPolicy.consecutiveFailureCap {
                    return .failed(shortfall)
                }
            } else {
                consecutiveFailures = 0
            }

            proposals.append(AutopilotPolicy.ProposedRecord(
                signature: AutopilotPolicy.screenSignature(screen), step: step))
            if AutopilotPolicy.shouldAbortNoProgress(proposals) {
                return .failed("Kept trying the same thing — stopped")
            }

            recycleAheadIfNeeded()
            // The verification path settled already; don't wait twice.
            if failure != nil || !step.goalComplete {
                await settle(after: step.action, frontmostBefore: frontmostBefore,
                             executor: executor)
            }
            if Task.isCancelled { return .cancelled }
        }
        return .failed("Stopped after \(AutopilotPolicy.stepCap) steps on “\(goal)”")
    }

    // MARK: - Deciding

    private func snapshot(scope: AutopilotScope) async -> AutopilotScreen {
        let snapshotScope: ScreenContextSnapshot.Scope =
            scope == .nearPointer ? .regionAroundPointer : .fullScreen
        return await screenContext.snapshot(scope: snapshotScope).coreScreen()
    }

    private func decide(
        goal: String, history: [AutopilotHistoryEntry], screen: AutopilotScreen
    ) async throws -> AutopilotStep {
        let prompt = AutopilotPolicy.buildPrompt(
            goal: goal, history: history, screen: screen,
            tokenBudget: Self.promptBudget)
        let promptTokens = AutopilotPolicy.estimatedTokens(prompt)
        if ledger.shouldRecycle(nextPromptTokens: promptTokens) {
            adoptFreshSession()
        }
        do {
            ledger.record(promptTokens: promptTokens)
            let response = try await activeSession().respond(
                to: prompt, generating: StepChoice.self,
                options: GenerationOptions(sampling: .greedy))
            return Self.mirror(response.content)
        } catch {
            // A cancelled run throws out of respond too — that's the user
            // braking, not a filled window. Never spend a retry round on it.
            if Task.isCancelled || error is CancellationError { throw error }
            // One retry on a fresh session (covers a filled-up transcript
            // window the ledger's estimate missed).
            adoptFreshSession()
            ledger.record(promptTokens: promptTokens)
            let response = try await activeSession().respond(
                to: prompt, generating: StepChoice.self,
                options: GenerationOptions(sampling: .greedy))
            return Self.mirror(response.content)
        }
    }

    /// @Generable types never cross into PawvisCore — the mirror is by raw
    /// value, and the two enums are kept case-identical.
    private static func mirror(_ choice: StepChoice) -> AutopilotStep {
        AutopilotStep(
            action: AutopilotAction(rawValue: choice.action.rawValue) ?? .cannotProceed,
            elementIndex: choice.elementIndex,
            argument: choice.argument,
            goalComplete: choice.goalComplete,
            targetNotInContext: choice.targetNotInContext)
    }

    private func targetLabel(of step: AutopilotStep, in screen: AutopilotScreen) -> String? {
        guard let index = step.elementIndex,
              screen.elements.indices.contains(index) else { return nil }
        return screen.elements[index].label
    }

    // MARK: - Executing

    /// Performs one validated step. Returns a failure message, or nil when
    /// the action went through.
    private func execute(
        _ step: AutopilotStep, screen: AutopilotScreen, executor: CommandExecutor
    ) async -> String? {
        func center(of index: Int?) -> CGPoint? {
            guard let index, screen.elements.indices.contains(index) else { return nil }
            let element = screen.elements[index]
            return CGPoint(x: element.centerX, y: element.centerY)
        }
        func outcome(_ result: ExecutionOutcome) -> String? {
            if case .failed(let message) = result { return message }
            return nil
        }

        switch step.action {
        case .click, .doubleClick, .rightClick:
            guard let point = center(of: step.elementIndex) else {
                return "couldn't find that on screen"
            }
            let kind: ClickKind = step.action == .doubleClick ? .double
                : step.action == .rightClick ? .right : .left
            executor.click(kind, at: point)
            return nil

        case .typeText:
            guard let text = step.argument, !text.isEmpty else { return "nothing to type" }
            if let point = center(of: step.elementIndex) {
                await executor.type(text, into: point)
            } else {
                executor.type(text)
            }
            return nil

        case .pressKey:
            guard let name = step.argument,
                  let chord = SpokenKeyParser.chord(
                    from: name.lowercased().split(separator: " ").map(String.init)) else {
                return "didn't recognize that key"
            }
            return outcome(await executor.execute(.press(chord)))

        case .openApp:
            guard let app = step.argument else { return "which app?" }
            return outcome(await executor.execute(.open(app: app)))

        case .switchToApp:
            guard let app = step.argument else { return "which app?" }
            return outcome(await executor.execute(.switchTo(app: app)))

        case .goToURL:
            guard let raw = step.argument,
                  let url = SpokenURLNormalizer.normalize(raw)
                    ?? (raw.contains(".") ? raw : nil) else {
                return "didn't catch the address"
            }
            return outcome(await executor.execute(.goTo(url: url, app: nil)))

        case .webSearch:
            guard let query = step.argument, !query.isEmpty else {
                return "nothing to search for"
            }
            return outcome(await executor.execute(.webSearch(query: query, app: nil)))

        case .scrollUp:
            return outcome(await executor.execute(.scroll(direction: .up, amount: .step)))

        case .scrollDown:
            return outcome(await executor.execute(.scroll(direction: .down, amount: .step)))

        case .wait:
            // The settle table applies the pause; nothing to do here.
            return nil

        case .done, .cannotProceed:
            // Terminal actions are handled in the loop, never executed.
            return nil
        }
    }

    /// Checks a goal-completing step's postcondition against the world.
    /// Returns nil when the claim holds, or a short reason it doesn't.
    /// Necessary, not sufficient — it can't prove the goal's semantics, but
    /// it catches the classic lie: "finished" after an action that visibly
    /// did nothing.
    private func completionShortfall(
        of step: AutopilotStep, baseline: Int?, executor: CommandExecutor
    ) async -> String? {
        switch AutopilotPolicy.completionCheck(for: step) {
        case .accept:
            return nil
        case .appFrontmost(let named):
            if AutopilotPolicy.frontmostSatisfies(
                target: named,
                frontmostAppName: executor.frontmostAppName,
                frontmostIsBrowser: executor.frontmostIsBrowser) {
                return nil
            }
            if let named { return "\(named) never came to the front" }
            return "no browser came to the front"
        case .screenChanged:
            guard let baseline else { return nil }
            let post = await snapshot(scope: .fullScreen)
            return AutopilotPolicy.screenSignature(post) == baseline
                ? "nothing on screen changed" : nil
        }
    }

    /// Lets the UI react before the next snapshot. App launches and switches
    /// wait for the frontmost app to actually change (dynamic, capped)
    /// before the fixed tail from the settle table.
    private func settle(
        after action: AutopilotAction, frontmostBefore: pid_t?,
        executor: CommandExecutor
    ) async {
        switch action {
        case .openApp:
            _ = await executor.waitForFrontmostChange(from: frontmostBefore, timeout: 3.0)
        case .switchToApp:
            _ = await executor.waitForFrontmostChange(from: frontmostBefore, timeout: 2.0)
        default:
            break
        }
        let ms = AutopilotPolicy.settleMilliseconds(after: action)
        if ms > 0 {
            try? await Task.sleep(for: .milliseconds(ms))
        }
    }
}
