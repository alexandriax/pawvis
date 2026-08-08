import XCTest
@testable import PawvisCore

/// Prompt assembly and the token ledger: every prompt is self-contained, the
/// goal sits last, and the budget trims passive elements before anything
/// else — the 4096-token window is the hardest constraint in the loop.
final class AutopilotPromptTests: XCTestCase {
    private func element(_ label: String, kind: String = "button",
                         actionable: Bool = true) -> AutopilotElement {
        AutopilotElement(label: label, kind: kind, actionable: actionable,
                         x: 10, y: 20, width: 80, height: 24)
    }

    private func screen(_ elements: [AutopilotElement]) -> AutopilotScreen {
        AutopilotScreen(appName: "Notes", windowTitle: "Untitled",
                        focusedElement: nil, pointerX: 312, pointerY: 480,
                        elements: elements)
    }

    func testStepOnePromptOmitsHistoryBlock() {
        let prompt = AutopilotPolicy.buildPrompt(
            goal: "click sign in", history: [],
            screen: screen([element("Sign in")]), tokenBudget: 2000)
        XCTAssertFalse(prompt.contains("Steps already taken"))
    }

    func testPromptOrdersScreenThenHistoryThenGoalLast() {
        let history = [AutopilotHistoryEntry(line: "1. opened Notes", succeeded: true)]
        let prompt = AutopilotPolicy.buildPrompt(
            goal: "open notes and start a new note", history: history,
            screen: screen([element("New Note")]), tokenBudget: 2000)

        guard let screenAt = prompt.range(of: "Visible elements"),
              let historyAt = prompt.range(of: "Steps already taken"),
              let goalAt = prompt.range(of: "Goal:") else {
            return XCTFail("prompt is missing a section")
        }
        XCTAssertLessThan(screenAt.lowerBound, historyAt.lowerBound)
        XCTAssertLessThan(historyAt.lowerBound, goalAt.lowerBound)
        XCTAssertTrue(prompt.hasSuffix("Goal: “open notes and start a new note”"))
    }

    func testElementLinesUsePlainKindWords() {
        let prompt = AutopilotPolicy.buildPrompt(
            goal: "test", history: [],
            screen: screen([element("File", kind: "menu")]), tokenBudget: 2000)
        XCTAssertTrue(prompt.contains("0. menu “File” at 10,20 size 80×24"))
        XCTAssertFalse(prompt.contains("AXMenu"))
    }

    func testPassiveElementsDroppedFirstWhenOverBudget() {
        // Actionable elements come first from curation; a tight budget must
        // keep the head of the list and lose the tail.
        var elements = (0..<10).map { element("Button \($0)") }
        elements += (0..<10).map { element("Paragraph \($0)", kind: "text", actionable: false) }
        let prompt = AutopilotPolicy.buildPrompt(
            goal: "click button 3", history: [], screen: screen(elements),
            tokenBudget: 260)
        XCTAssertTrue(prompt.contains("Button 0"))
        XCTAssertFalse(prompt.contains("Paragraph 9"))
        // The goal always survives trimming.
        XCTAssertTrue(prompt.hasSuffix("Goal: “click button 3”"))
    }

    func testLabelsTruncatedAtEightyChars() {
        let long = String(repeating: "x", count: 200)
        let prompt = AutopilotPolicy.buildPrompt(
            goal: "test", history: [], screen: screen([element(long)]),
            tokenBudget: 2000)
        XCTAssertFalse(prompt.contains(String(repeating: "x", count: 81)))
        XCTAssertTrue(prompt.contains(String(repeating: "x", count: 80) + "…"))
    }

    // MARK: - Ledger

    func testTokenLedgerRecyclesBeforeWindowOverflow() {
        var ledger = AutopilotTokenLedger(instructionTokens: 450)
        XCTAssertFalse(ledger.shouldRecycle(nextPromptTokens: 900))

        // Two 960-token exchanges still fit a third (450 + 1920 + 900 + 700
        // headroom = 3970); a third exchange pushes the next one over.
        ledger.record(promptTokens: 900)
        ledger.record(promptTokens: 900)
        XCTAssertFalse(ledger.shouldRecycle(nextPromptTokens: 900))
        ledger.record(promptTokens: 900)
        XCTAssertTrue(ledger.shouldRecycle(nextPromptTokens: 900))

        ledger.reset()
        XCTAssertFalse(ledger.shouldRecycle(nextPromptTokens: 900))
    }

    func testEstimatedTokensIsConservative() {
        // ~4 chars/token English text must estimate high, never low.
        let text = String(repeating: "word ", count: 100) // 500 chars
        XCTAssertGreaterThanOrEqual(AutopilotPolicy.estimatedTokens(text), 125)
    }
}
