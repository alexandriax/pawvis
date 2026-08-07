import XCTest
@testable import PawvisCore

final class AgentVerdictTests: XCTestCase {
    func testDoneLineWins() {
        XCTAssertEqual(
            AgentVerdict.extract(from: "thinking...\nDONE: opened Safari"),
            .done("opened Safari"))
    }

    func testFailedLineWins() {
        XCTAssertEqual(
            AgentVerdict.extract(from: "tried a thing\nFAILED: no such app"),
            .failed("no such app"))
    }

    func testLastVerdictLineIsAuthoritative() {
        XCTAssertEqual(
            AgentVerdict.extract(from: "DONE: partial\nmore output\nFAILED: rolled back"),
            .failed("rolled back"))
    }

    func testVerdictSurroundedByWhitespaceStillParses() {
        XCTAssertEqual(
            AgentVerdict.extract(from: "  DONE: ok  \n"),
            .done("ok"))
    }

    func testNoVerdictReturnsNone() {
        XCTAssertEqual(AgentVerdict.extract(from: "just some output"), .none)
        XCTAssertEqual(AgentVerdict.extract(from: ""), .none)
    }

    func testEmptySummaryIsPreserved() {
        XCTAssertEqual(AgentVerdict.extract(from: "DONE:"), .done(""))
    }
}

/// Line shapes verified live against `claude -p --output-format stream-json
/// --verbose` (v2.1.216).
final class AgentStreamParserTests: XCTestCase {
    func testAssistantTextBecomesDisplayLines() {
        let line = """
        {"type":"assistant","message":{"role":"assistant","content":[{"type":"text","text":"Opening Safari now.\\nDone."}]}}
        """
        let output = AgentStreamParser.claudeLine(line)
        XCTAssertEqual(output.display, ["Opening Safari now.", "Done."])
        XCTAssertNil(output.resultText)
    }

    func testToolUseBecomesMarkerLine() {
        let line = """
        {"type":"assistant","message":{"content":[{"type":"tool_use","name":"Bash","input":{}},{"type":"text","text":"running"}]}}
        """
        XCTAssertEqual(AgentStreamParser.claudeLine(line).display, ["▸ Bash", "running"])
    }

    func testResultLineCarriesResultText() {
        let line = """
        {"type":"result","subtype":"success","is_error":false,"result":"DONE: probe ok"}
        """
        let output = AgentStreamParser.claudeLine(line)
        XCTAssertEqual(output.display, [])
        XCTAssertEqual(output.resultText, "DONE: probe ok")
        XCTAssertEqual(output.resultIsError, false)
    }

    func testSystemAndRateLimitLinesAreDropped() {
        XCTAssertEqual(
            AgentStreamParser.claudeLine(#"{"type":"system","subtype":"init","cwd":"/"}"#),
            AgentStreamParser.LineOutput())
        XCTAssertEqual(
            AgentStreamParser.claudeLine(#"{"type":"rate_limit_event"}"#),
            AgentStreamParser.LineOutput())
    }

    func testNonJSONLinePassesThrough() {
        XCTAssertEqual(
            AgentStreamParser.claudeLine("warning: something"),
            AgentStreamParser.LineOutput(display: ["warning: something"]))
    }

    func testBlankAndMalformedLinesAreSafe() {
        XCTAssertEqual(AgentStreamParser.claudeLine("   "), AgentStreamParser.LineOutput())
        XCTAssertEqual(
            AgentStreamParser.claudeLine("{not json"),
            AgentStreamParser.LineOutput(display: ["{not json"]))
    }
}
