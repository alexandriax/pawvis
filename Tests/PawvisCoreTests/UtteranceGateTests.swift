import XCTest
@testable import PawvisCore

/// The wake-window stitcher: a bare wake-word final opens a capture window
/// and the next final becomes the command — the fix for the speech engine
/// finalizing "Pawvis" on the pause before the command.
final class UtteranceGateTests: XCTestCase {
    var gate = UtteranceGate(windowSeconds: 8)

    override func setUp() {
        super.setUp()
        gate = UtteranceGate(windowSeconds: 8)
    }

    func testWakeAndCommandInOneFinalDispatchesImmediately() {
        XCTAssertEqual(
            gate.decide(remainder: "open safari", transcript: "Pawvis open safari", now: 0),
            .command("open safari"))
        XCTAssertFalse(gate.isArmed(now: 0))
    }

    func testBareWakeWordArmsThenNextFinalIsTheCommand() {
        XCTAssertEqual(gate.decide(remainder: "", transcript: "Pawvis", now: 0), .armed)
        XCTAssertTrue(gate.isArmed(now: 5))
        XCTAssertEqual(
            gate.decide(remainder: nil, transcript: "open safari", now: 5),
            .command("open safari"))
        // One-shot: the window is consumed.
        XCTAssertEqual(gate.decide(remainder: nil, transcript: "and then", now: 6), .ignored)
    }

    func testWindowExpiresAfterWindowSeconds() {
        XCTAssertEqual(gate.decide(remainder: "", transcript: "Pawvis", now: 0), .armed)
        XCTAssertFalse(gate.isArmed(now: 8.5))
        XCTAssertEqual(gate.decide(remainder: nil, transcript: "open safari", now: 8.5), .ignored)
    }

    func testAmbientSpeechWithoutWakeIsIgnored() {
        XCTAssertEqual(gate.decide(remainder: nil, transcript: "totally unrelated", now: 0), .ignored)
    }

    func testWakeWithCommandWhileArmedWinsAndDisarms() {
        XCTAssertEqual(gate.decide(remainder: "", transcript: "Pawvis", now: 0), .armed)
        XCTAssertEqual(
            gate.decide(remainder: "scroll down", transcript: "Pawvis scroll down", now: 2),
            .command("scroll down"))
        XCTAssertEqual(gate.decide(remainder: nil, transcript: "hello", now: 3), .ignored)
    }

    func testSecondBareWakeWordReArmsTheWindow() {
        XCTAssertEqual(gate.decide(remainder: "", transcript: "Pawvis", now: 0), .armed)
        XCTAssertEqual(gate.decide(remainder: "  ", transcript: "Pawvis", now: 7), .armed)
        // Window now runs from the second wake word.
        XCTAssertEqual(
            gate.decide(remainder: nil, transcript: "open mail", now: 12),
            .command("open mail"))
    }

    func testWhitespaceOnlyContinuationIsIgnoredNotDispatched() {
        XCTAssertEqual(gate.decide(remainder: "", transcript: "Pawvis", now: 0), .armed)
        XCTAssertEqual(gate.decide(remainder: nil, transcript: "   ", now: 1), .ignored)
    }

    func testCommandRemainderIsTrimmed() {
        XCTAssertEqual(
            gate.decide(remainder: "  open safari \n", transcript: "Pawvis open safari", now: 0),
            .command("open safari"))
    }

    func testDisarmClosesTheWindow() {
        XCTAssertEqual(gate.decide(remainder: "", transcript: "Pawvis", now: 0), .armed)
        gate.disarm()
        XCTAssertEqual(gate.decide(remainder: nil, transcript: "open safari", now: 1), .ignored)
    }
}
