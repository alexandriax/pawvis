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

    func testInitialScopeSimpleGoalIsRegion() {
        XCTAssertEqual(AutopilotPolicy.initialScope(goal: "click sign in"), .nearPointer)
        XCTAssertEqual(AutopilotPolicy.initialScope(goal: "toggle dark mode"), .nearPointer)
    }

    func testInitialScopeMultiClauseGoalIsFullScreen() {
        XCTAssertEqual(
            AutopilotPolicy.initialScope(goal: "open notes and start a new note"),
            .fullScreen)
        XCTAssertEqual(
            AutopilotPolicy.initialScope(goal: "click save then close the window"),
            .fullScreen)
    }

    func testAndInsideAWordDoesNotTriggerFullScreen() {
        // "command" contains "and" — only the standalone word counts.
        XCTAssertEqual(AutopilotPolicy.initialScope(goal: "press command s"), .nearPointer)
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
}
