import XCTest
@testable import PawvisCore

/// The autopilot's pure decision rules: scope, guards, settles, and the
/// abort conditions that keep a run from looping forever.
final class AutopilotPolicyTests: XCTestCase {
    private func step(
        _ action: AutopilotAction, index: Int? = nil, argument: String? = nil,
        goalComplete: Bool = false, notInContext: Bool = false
    ) -> AutopilotStep {
        AutopilotStep(action: action, elementIndex: index, argument: argument,
                      goalComplete: goalComplete, targetNotInContext: notInContext)
    }

    private func screen(elements: [AutopilotElement] = [],
                        app: String? = "Safari") -> AutopilotScreen {
        AutopilotScreen(appName: app, pointerX: 100, pointerY: 100,
                        elements: elements)
    }

    private func element(_ label: String, kind: String = "button",
                         actionable: Bool = true, x: Double = 10,
                         y: Double = 10) -> AutopilotElement {
        AutopilotElement(label: label, kind: kind, actionable: actionable,
                         x: x, y: y, width: 80, height: 24)
    }

    // MARK: - Scope

    func testInitialScopeClickGoalIsRegion() {
        // Click-family goals are the one case where the target is usually
        // near the pointer — the measured one-shot fast path.
        XCTAssertEqual(AutopilotPolicy.initialScope(goal: "click sign in"), .nearPointer)
        XCTAssertEqual(AutopilotPolicy.initialScope(goal: "tap the play button"), .nearPointer)
        XCTAssertEqual(AutopilotPolicy.initialScope(goal: "double click readme"), .nearPointer)
    }

    func testInitialScopeNonClickGoalIsFullScreen() {
        // Anything else that reaches the loop needs the screen at large —
        // window controls, menus, another app — not whatever happens to sit
        // under the pointer.
        XCTAssertEqual(AutopilotPolicy.initialScope(goal: "toggle dark mode"), .fullScreen)
        XCTAssertEqual(AutopilotPolicy.initialScope(goal: "make the text bigger"), .fullScreen)
    }

    func testInitialScopeMultiClauseGoalIsFullScreen() {
        XCTAssertEqual(
            AutopilotPolicy.initialScope(goal: "open notes and start a new note"),
            .fullScreen)
        XCTAssertEqual(
            AutopilotPolicy.initialScope(goal: "click save then close the window"),
            .fullScreen)
    }

    func testAndInsideAWordIsNotMultiClause() {
        // "command" contains "and" — only the standalone word counts.
        XCTAssertFalse(AutopilotPolicy.isMultiClause(goal: "press command s"))
        XCTAssertFalse(AutopilotPolicy.isMultiClause(goal: "click the handle"))
        XCTAssertTrue(AutopilotPolicy.isMultiClause(goal: "press command s and click save"))
    }

    func testGoesStraightToLoopOnlyForVisualOrMultiClauseGoals() {
        XCTAssertTrue(AutopilotPolicy.goesStraightToLoop(goal: "click sign in"))
        XCTAssertTrue(AutopilotPolicy.goesStraightToLoop(goal: "right click the file"))
        XCTAssertTrue(AutopilotPolicy.goesStraightToLoop(goal: "open notes and start a new note"))
        XCTAssertFalse(AutopilotPolicy.goesStraightToLoop(goal: "open discord dot com in chrome"))
        XCTAssertFalse(AutopilotPolicy.goesStraightToLoop(goal: "make the text bigger"))
    }

    func testScopeFromStepTwoIsAlwaysFullScreen() {
        XCTAssertEqual(AutopilotPolicy.scope(stepIndex: 2, goal: "click sign in"), .fullScreen)
        XCTAssertEqual(AutopilotPolicy.scope(stepIndex: 5, goal: "click sign in"), .fullScreen)
        XCTAssertEqual(AutopilotPolicy.scope(stepIndex: 1, goal: "click sign in"), .nearPointer)
    }

    // MARK: - Click guard

    func testGuardAppliesOnlyToFirstStepGoalCompletingClicks() {
        XCTAssertTrue(AutopilotPolicy.guardApplies(
            stepIndex: 1, step: step(.click, index: 0, goalComplete: true)))
        XCTAssertTrue(AutopilotPolicy.guardApplies(
            stepIndex: 1, step: step(.rightClick, index: 0, goalComplete: true)))
    }

    func testGuardSkippedMidLoopAndForNonClicks() {
        // Mid-loop clicks legitimately differ from the goal's words.
        XCTAssertFalse(AutopilotPolicy.guardApplies(
            stepIndex: 2, step: step(.click, index: 0, goalComplete: true)))
        // A first click that continues the goal is a stepping stone, not the
        // answer — the guard would wrongly compare it to the goal.
        XCTAssertFalse(AutopilotPolicy.guardApplies(
            stepIndex: 1, step: step(.click, index: 0, goalComplete: false)))
        XCTAssertFalse(AutopilotPolicy.guardApplies(
            stepIndex: 1, step: step(.typeText, argument: "hi", goalComplete: true)))
    }

    func testLabelResemblanceMatchesPrefixBothWays() {
        XCTAssertTrue(AutopilotPolicy.labelResemblesGoal(
            label: "Sign in", goal: "click sign in"))
        XCTAssertTrue(AutopilotPolicy.labelResemblesGoal(
            label: "Signing in…", goal: "click sign in"))
        XCTAssertFalse(AutopilotPolicy.labelResemblesGoal(
            label: "Cancel", goal: "click log out"))
        // Nothing meaningful to compare: trust the model.
        XCTAssertTrue(AutopilotPolicy.labelResemblesGoal(
            label: "Anything", goal: "click that"))
    }

    // MARK: - Settle

    func testSettleTableCoversEveryAction() {
        for action in AutopilotAction.allCases {
            let ms = AutopilotPolicy.settleMilliseconds(after: action)
            XCTAssertGreaterThanOrEqual(ms, 0, "\(action) settle must be defined")
        }
        // Terminal actions never wait.
        XCTAssertEqual(AutopilotPolicy.settleMilliseconds(after: .done), 0)
        XCTAssertEqual(AutopilotPolicy.settleMilliseconds(after: .cannotProceed), 0)
    }

    // MARK: - No progress

    func testNoProgressAbortsAfterThreeIdenticalProposalsOnUnchangedScreen() {
        let sig = AutopilotPolicy.screenSignature(screen(elements: [element("OK")]))
        let repeated = AutopilotPolicy.ProposedRecord(
            signature: sig, step: step(.click, index: 0))
        XCTAssertFalse(AutopilotPolicy.shouldAbortNoProgress([repeated, repeated]))
        XCTAssertTrue(AutopilotPolicy.shouldAbortNoProgress([repeated, repeated, repeated]))
    }

    func testNoProgressAllowsRepeatedActionWhenScreenChanges() {
        let a = AutopilotPolicy.screenSignature(screen(elements: [element("Page 1")]))
        let b = AutopilotPolicy.screenSignature(screen(elements: [element("Page 2")]))
        let scrollA = AutopilotPolicy.ProposedRecord(signature: a, step: step(.scrollDown))
        let scrollB = AutopilotPolicy.ProposedRecord(signature: b, step: step(.scrollDown))
        // Scrolling through a long page repeats the action on changing
        // screens — that's progress, not a loop.
        XCTAssertFalse(AutopilotPolicy.shouldAbortNoProgress([scrollA, scrollB, scrollA]))
    }

    func testScreenSignatureIgnoresSubEightPointFrameJitter() {
        let steady = screen(elements: [element("OK", x: 100, y: 100)])
        let jittered = screen(elements: [element("OK", x: 102, y: 101)])
        let moved = screen(elements: [element("OK", x: 300, y: 100)])
        XCTAssertEqual(AutopilotPolicy.screenSignature(steady),
                       AutopilotPolicy.screenSignature(jittered))
        XCTAssertNotEqual(AutopilotPolicy.screenSignature(steady),
                          AutopilotPolicy.screenSignature(moved))
    }

    // MARK: - History

    func testHistoryLineRenderingForSuccessAndFailure() {
        let ok = AutopilotPolicy.historyLine(
            index: 1, step: step(.click, index: 0), targetLabel: "File", failure: nil)
        XCTAssertEqual(ok.line, "1. clicked “File”")
        XCTAssertTrue(ok.succeeded)

        let failed = AutopilotPolicy.historyLine(
            index: 2, step: step(.openApp, argument: "up safari please"),
            targetLabel: nil, failure: "no matching app")
        XCTAssertEqual(failed.line, "2. opened up safari please failed: no matching app")
        XCTAssertFalse(failed.succeeded)
    }

    func testHistoryLineTruncatesLongTypedText() {
        let long = String(repeating: "a", count: 60)
        let entry = AutopilotPolicy.historyLine(
            index: 1, step: step(.typeText, argument: long), targetLabel: nil,
            failure: nil)
        XCTAssertTrue(entry.line.contains("…"))
        XCTAssertLessThan(entry.line.count, 70)
    }

    // MARK: - Completion verification

    func testCompletionCheckForOpenAndSwitchIsAppFrontmostNamed() {
        XCTAssertEqual(
            AutopilotPolicy.completionCheck(for: step(.openApp, argument: "Notes")),
            .appFrontmost(named: "Notes"))
        XCTAssertEqual(
            AutopilotPolicy.completionCheck(for: step(.switchToApp, argument: "Safari")),
            .appFrontmost(named: "Safari"))
    }

    func testCompletionCheckForNavigationIsAppFrontmostWithNoNamedTarget() {
        // Any browser satisfies a goToURL/webSearch step — it doesn't matter
        // which one, so the argument (the URL/query) is never the target
        // name, unlike openApp/switchToApp above.
        XCTAssertEqual(
            AutopilotPolicy.completionCheck(for: step(.goToURL, argument: "github.com")),
            .appFrontmost(named: nil))
        XCTAssertEqual(
            AutopilotPolicy.completionCheck(for: step(.webSearch, argument: "sloth videos")),
            .appFrontmost(named: nil))
    }

    func testCompletionCheckForScreenActionsIsScreenChanged() {
        let actions: [AutopilotAction] = [.click, .doubleClick, .rightClick, .scrollUp, .scrollDown]
        for action in actions {
            XCTAssertEqual(AutopilotPolicy.completionCheck(for: step(action)), .screenChanged,
                           "\(action) must require a screen change")
        }
    }

    func testCompletionCheckForUnverifiableActionsIsAccept() {
        // A false "unverified" would be worse than a false "done" here —
        // blindly repeating a keystroke or retype would be destructive.
        let actions: [AutopilotAction] = [.typeText, .pressKey, .wait, .done, .cannotProceed]
        for action in actions {
            XCTAssertEqual(AutopilotPolicy.completionCheck(for: step(action)), .accept,
                           "\(action) must be accepted unverified")
        }
    }

    func testFrontmostSatisfiesFuzzyMatchesNamedTarget() {
        XCTAssertTrue(AutopilotPolicy.frontmostSatisfies(
            target: "chrome", frontmostAppName: "Google Chrome", frontmostIsBrowser: false))
    }

    func testFrontmostSatisfiesFalseWhenNameDoesNotMatch() {
        // frontmostIsBrowser is irrelevant once a named target is given —
        // only the name match decides.
        XCTAssertFalse(AutopilotPolicy.frontmostSatisfies(
            target: "notes", frontmostAppName: "Google Chrome", frontmostIsBrowser: true))
    }

    func testFrontmostSatisfiesNilTargetFallsBackToIsBrowser() {
        // goToURL/webSearch steps have no named target — any browser being
        // frontmost is the win condition, regardless of which one.
        XCTAssertTrue(AutopilotPolicy.frontmostSatisfies(
            target: nil, frontmostAppName: "Anything", frontmostIsBrowser: true))
        XCTAssertFalse(AutopilotPolicy.frontmostSatisfies(
            target: nil, frontmostAppName: "Anything", frontmostIsBrowser: false))
    }

    func testFrontmostSatisfiesFalseWhenNoFrontmostNameKnown() {
        XCTAssertFalse(AutopilotPolicy.frontmostSatisfies(
            target: "notes", frontmostAppName: nil, frontmostIsBrowser: false))
    }
}
