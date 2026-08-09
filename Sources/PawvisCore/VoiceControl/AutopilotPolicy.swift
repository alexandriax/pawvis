import Foundation

/// Where a step's screen snapshot should look.
public enum AutopilotScope: String, Equatable, Sendable {
    case nearPointer, fullScreen
}

/// The autopilot's pure decision rules: scopes, budgets, settles, guards,
/// no-progress detection, and prompt assembly. Everything here is clock-free
/// and model-free so the loop's behavior is unit-testable; the app layer
/// supplies screens and executes steps.
public enum AutopilotPolicy {
    /// A run never takes more than this many model-chosen steps…
    public static let stepCap = 8
    /// …or this much wall time, whichever comes first.
    public static let wallClockCap: TimeInterval = 45
    /// Consecutive failed/invalid steps tolerated before giving up — the
    /// third in a row aborts. More than two means the model is guessing,
    /// not progressing.
    public static let consecutiveFailureCap = 2
    /// The model's `wait` action pauses this long. Fixed — numeric arguments
    /// from guided generation are an unproven surface.
    public static let waitActionMilliseconds = 2000

    // MARK: - Goal shape

    /// Multi-clause goals ("open notes and start a new note") need the loop's
    /// sequencing; the one-shot translation stage never sees them.
    public static func isMultiClause(goal: String) -> Bool {
        let normalized = " " + VoiceControlParser.normalize(goal) + " "
        for marker in [" and ", " then ", " and then "] where normalized.contains(marker) {
            return true
        }
        return false
    }

    /// Click-family goals are inherently visual — the target is on the
    /// screen, usually near the pointer.
    public static func isClickPrefixed(goal: String) -> Bool {
        let normalized = VoiceControlParser.normalize(goal)
        for prefix in ["click ", "tap ", "double click ", "double tap ",
                       "right click ", "right tap "]
            where normalized.hasPrefix(prefix) {
            return true
        }
        return false
    }

    /// Goals that skip the translation stage and go straight to the visual
    /// loop: click-family (the screen IS the subject) and multi-clause (the
    /// translator is deliberately single-primitive). Everything else gets one
    /// cheap screen-free translation attempt first — the small model is far
    /// more reliable translating words than sequencing GUI actions.
    public static func goesStraightToLoop(goal: String) -> Bool {
        isClickPrefixed(goal: goal) || isMultiClause(goal: goal)
    }

    // MARK: - Scope

    /// Click-family goals keep the resolver's measured region-first behavior
    /// ("click sign in" → look near the pointer). Everything else that
    /// reaches the loop is there because it needs the screen at large —
    /// window controls, menus, another app — so the first look is the whole
    /// screen, not whatever happens to sit under the pointer.
    public static func initialScope(goal: String) -> AutopilotScope {
        isClickPrefixed(goal: goal) && !isMultiClause(goal: goal)
            ? .nearPointer : .fullScreen
    }

    /// From step 2 on, the loop is mid-task and the target can be anywhere —
    /// including a menu that just opened. Always the whole screen.
    public static func scope(stepIndex: Int, goal: String) -> AutopilotScope {
        stepIndex <= 1 ? initialScope(goal: goal) : .fullScreen
    }

    // MARK: - Settle

    /// How long to let the UI react before the next snapshot, per action.
    /// openApp/switchToApp get a dynamic frontmost-change wait in the app
    /// layer on top of this fixed tail.
    public static func settleMilliseconds(after action: AutopilotAction) -> Int {
        switch action {
        case .click, .doubleClick, .rightClick: return 300
        case .typeText: return 150
        case .pressKey: return 250
        case .openApp: return 800
        case .switchToApp: return 400
        case .goToURL, .webSearch: return 1500
        case .scrollUp, .scrollDown: return 300
        case .wait: return waitActionMilliseconds
        case .done, .cannotProceed: return 0
        }
    }

    // MARK: - Click guard

    /// The label-resemblance guard exists because the model force-matches
    /// semantically adjacent click targets ("click log out" → "Cancel"). It
    /// only applies to a first step that claims to finish the goal — the
    /// one-shot click case. Mid-loop clicks legitimately differ from the
    /// goal's words ("toggle dark mode" clicks "Appearance" on the way).
    public static func guardApplies(stepIndex: Int, step: AutopilotStep) -> Bool {
        guard stepIndex == 1, step.goalComplete else { return false }
        switch step.action {
        case .click, .doubleClick, .rightClick: return true
        default: return false
        }
    }

    /// True when at least one meaningful goal word matches the label (prefix
    /// match either way, so "sign" ~ "signing" and OCR misreads within
    /// reason still pass). Purely semantic matches ("gear icon" →
    /// "Settings") fail and trigger the full-screen retry.
    public static func labelResemblesGoal(label: String, goal: String) -> Bool {
        let stopWords: Set<String> = [
            "click", "tap", "press", "the", "on", "button", "link", "that",
            "this", "it", "a", "an", "to", "double", "right", "open", "and",
            "then",
        ]
        let spoken = tokens(of: goal).filter { $0.count >= 3 && !stopWords.contains($0) }
        guard !spoken.isEmpty else { return true } // nothing to compare — trust the model
        let labelTokens = tokens(of: label)
        for s in spoken {
            for l in labelTokens where l.hasPrefix(s) || s.hasPrefix(l) {
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

    // MARK: - Progress

    /// A stable fingerprint of what the screen looks like. Frames are
    /// rounded to 8 pt so sub-pixel relayout jitter doesn't read as change.
    public static func screenSignature(_ screen: AutopilotScreen) -> Int {
        var hasher = Hasher()
        hasher.combine(screen.appName)
        hasher.combine(screen.windowTitle)
        for element in screen.elements {
            hasher.combine(element.label)
            hasher.combine(Int((element.x / 8).rounded()))
            hasher.combine(Int((element.y / 8).rounded()))
        }
        return hasher.finalize()
    }

    public struct ProposedRecord: Equatable, Sendable {
        public var signature: Int
        public var step: AutopilotStep

        public init(signature: Int, step: AutopilotStep) {
            self.signature = signature
            self.step = step
        }
    }

    /// The model proposing the same action on an unchanged screen means the
    /// action isn't doing anything (a click that lands nowhere, a scroll at
    /// the end of a page). Three identical proposals in a row is the line.
    public static func shouldAbortNoProgress(_ proposals: [ProposedRecord]) -> Bool {
        guard proposals.count >= 3 else { return false }
        let last = proposals.suffix(3)
        guard let first = last.first else { return false }
        return last.allSatisfy { $0 == first }
    }

    // MARK: - Validation

    /// Whether a step is executable against the screen it was chosen from.
    /// Key names and URLs are checked with the same parsers that will
    /// execute them, so a step that validates can't fail on decode.
    public static func validate(_ step: AutopilotStep, elementCount: Int) -> AutopilotStepValidation {
        func indexValid() -> Bool {
            guard let index = step.elementIndex else { return false }
            return index >= 0 && index < elementCount
        }
        switch step.action {
        case .click, .doubleClick, .rightClick:
            guard indexValid() else {
                return .invalid(reason: "no such element to click")
            }
        case .typeText:
            guard let text = step.argument, !text.isEmpty else {
                return .invalid(reason: "nothing to type")
            }
            if step.elementIndex != nil, !indexValid() {
                return .invalid(reason: "no such field to type into")
            }
        case .pressKey:
            let tokens = (step.argument ?? "").lowercased()
                .split(separator: " ").map(String.init)
            guard SpokenKeyParser.chord(from: tokens) != nil else {
                return .invalid(reason: "unrecognized key “\(step.argument ?? "")”")
            }
        case .goToURL:
            let raw = step.argument ?? ""
            guard SpokenURLNormalizer.normalize(raw) != nil || raw.contains(".") else {
                return .invalid(reason: "no usable address")
            }
        case .openApp, .switchToApp:
            guard let app = step.argument, !app.isEmpty else {
                return .invalid(reason: "no app named")
            }
        case .webSearch:
            guard let query = step.argument, !query.isEmpty else {
                return .invalid(reason: "nothing to search for")
            }
        case .scrollUp, .scrollDown, .wait, .done, .cannotProceed:
            break
        }
        return .valid
    }

    // MARK: - Completion verification

    /// How a step's claim of finishing the goal is checked against reality.
    /// The model asserting `goalComplete` is a hypothesis, not a result — a
    /// click that landed nowhere must not end the run as a success.
    public enum CompletionCheck: Equatable, Sendable {
        /// The named app (nil = any browser) must be frontmost.
        case appFrontmost(named: String?)
        /// Something visible must have changed (full-screen signature).
        case screenChanged
        /// No independent check available — accept the claim. Used for
        /// actions whose blind repetition would be destructive (typing,
        /// key presses), where a false "unverified" is worse than a false
        /// "done".
        case accept
    }

    public static func completionCheck(for step: AutopilotStep) -> CompletionCheck {
        switch step.action {
        case .openApp, .switchToApp:
            return .appFrontmost(named: step.argument)
        case .goToURL, .webSearch:
            return .appFrontmost(named: nil)
        case .click, .doubleClick, .rightClick, .scrollUp, .scrollDown:
            return .screenChanged
        case .typeText, .pressKey, .wait, .done, .cannotProceed:
            return .accept
        }
    }

    /// Whether the frontmost app satisfies an `appFrontmost` check.
    public static func frontmostSatisfies(
        target: String?, frontmostAppName: String?, frontmostIsBrowser: Bool
    ) -> Bool {
        guard let target, !target.isEmpty else { return frontmostIsBrowser }
        guard let name = frontmostAppName else { return false }
        return AppNameMatch.matches(spoken: target, appName: name)
    }

    // MARK: - History

    public static func historyLine(
        index: Int, step: AutopilotStep, targetLabel: String?, failure: String?
    ) -> AutopilotHistoryEntry {
        let base = step.describe(targetLabel: targetLabel)
        if let failure, !failure.isEmpty {
            return AutopilotHistoryEntry(
                line: "\(index). \(base) failed: \(failure)", succeeded: false)
        }
        return AutopilotHistoryEntry(line: "\(index). \(base)", succeeded: true)
    }

    // MARK: - Prompt assembly

    /// Character budget → rough tokens. Conservative (English UI text runs
    /// ~4 chars/token; 3.5 overestimates) so the ledger recycles early, never
    /// late.
    public static func estimatedTokens(_ text: String) -> Int {
        max(1, Int((Double(text.count) / 3.5).rounded(.up)))
    }

    static let maxLabelLength = 80

    /// The per-step prompt. Layout, in order: screen state, steps already
    /// taken (omitted entirely on step 1, so a one-shot command's prompt is
    /// byte-for-byte as small as the old resolver's), then the goal last —
    /// recency bias puts the instruction closest to the answer.
    ///
    /// Over budget, passive elements are dropped from the end of the list
    /// first (the list arrives actionable-first from curation).
    public static func buildPrompt(
        goal: String,
        history: [AutopilotHistoryEntry],
        screen: AutopilotScreen,
        tokenBudget: Int
    ) -> String {
        var headLines: [String] = []
        if let app = screen.appName {
            headLines.append("Frontmost app: \(app)")
        }
        if let title = screen.windowTitle, !title.isEmpty {
            headLines.append("Window: \(title)")
        }
        if let focused = screen.focusedElement {
            headLines.append("Focused element: \(focused)")
        }
        headLines.append(
            "Pointer position: (\(Int(screen.pointerX)), \(Int(screen.pointerY)))")
        headLines.append("Visible elements (index. kind “label” at x,y size w×h):")

        var tailLines: [String] = []
        if !history.isEmpty {
            tailLines.append("")
            tailLines.append("Steps already taken:")
            tailLines.append(contentsOf: history.map(\.line))
        }
        tailLines.append("")
        tailLines.append("Goal: “\(goal)”")

        let fixedCost = estimatedTokens(
            (headLines + tailLines).joined(separator: "\n"))
        var remaining = tokenBudget - fixedCost

        var elementLines: [String] = []
        for (index, element) in screen.elements.enumerated() {
            let label = element.label.count > maxLabelLength
                ? String(element.label.prefix(maxLabelLength)) + "…"
                : element.label
            let line = "\(index). \(element.kind) “\(label)” at "
                + "\(Int(element.x)),\(Int(element.y)) size "
                + "\(Int(element.width))×\(Int(element.height))"
            let cost = estimatedTokens(line)
            if remaining - cost < 0 {
                // The list is actionable-first; everything from here on is
                // the cheapest to lose.
                break
            }
            remaining -= cost
            elementLines.append(line)
        }

        return (headLines + elementLines + tailLines).joined(separator: "\n")
    }
}

/// Tracks how full the model session's 4096-token window is, so the loop
/// recycles the session before an overflow instead of after one. Every
/// prompt is self-contained (goal + history + fresh elements), which makes
/// the transcript disposable — recycling is always safe.
public struct AutopilotTokenLedger: Equatable, Sendable {
    /// The model's whole context window.
    public static let windowTokens = 4096
    /// Response + safety headroom reserved per exchange.
    public static let reservedTokens = 700

    public let instructionTokens: Int
    public private(set) var spentTokens: Int

    public init(instructionTokens: Int) {
        self.instructionTokens = instructionTokens
        self.spentTokens = 0
    }

    /// True when the next exchange wouldn't fit — recycle before sending.
    public func shouldRecycle(nextPromptTokens: Int) -> Bool {
        instructionTokens + spentTokens + nextPromptTokens
            + Self.reservedTokens > Self.windowTokens
    }

    public mutating func record(promptTokens: Int, responseTokens: Int = 60) {
        spentTokens += promptTokens + responseTokens
    }

    public mutating func reset() {
        spentTokens = 0
    }
}
