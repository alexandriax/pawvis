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

    // MARK: - Strict capture (agent hand-off live)

    func testStrictBarRefusesAnArmedCaptureThatFailsIt() {
        // The 8-second window used to take the next final verbatim — in
        // agent mode that made any ambient sentence within it an
        // arbitrary-execution accept. With the bar passed, a wake-less
        // capture must parse deterministically or it is dropped.
        XCTAssertEqual(gate.decide(remainder: "", transcript: "Pawvis", now: 0), .armed)
        XCTAssertEqual(
            gate.decide(remainder: nil, transcript: "she went home yesterday", now: 2,
                        strictCommandBar: { _ in false }),
            .ignored)
        // The refusal consumed the one-shot window, same as any final.
        XCTAssertEqual(
            gate.decide(remainder: nil, transcript: "open safari", now: 3,
                        strictCommandBar: { _ in true }),
            .ignored)
    }

    func testStrictBarAcceptsAnArmedCaptureThatPassesIt() {
        XCTAssertEqual(gate.decide(remainder: "", transcript: "Pawvis", now: 0), .armed)
        XCTAssertEqual(
            gate.decide(remainder: nil, transcript: "open safari", now: 2,
                        strictCommandBar: { $0 == "open safari" }),
            .command("open safari"))
    }

    func testStrictBarNeverTouchesWakeCarryingFinals() {
        // A final with a remainder dispatches on the wake word itself —
        // free-form speech for the agent included. A bar that refuses
        // everything proves it is not consulted on this path.
        XCTAssertEqual(
            gate.decide(remainder: "make it bigger", transcript: "Pawvis make it bigger",
                        now: 0, strictCommandBar: { _ in false }),
            .command("make it bigger"))
        // Same while the window is armed: the wake-carrying final wins.
        XCTAssertEqual(gate.decide(remainder: "", transcript: "Pawvis", now: 1), .armed)
        XCTAssertEqual(
            gate.decide(remainder: "quit chrome", transcript: "pawvis quit chrome",
                        now: 2, strictCommandBar: { _ in false }),
            .command("quit chrome"))
    }

    func testStrictEndToEndWithTheRealParserBar() {
        // The exact wiring VoiceController uses in agent mode: the parser's
        // deterministic-command check is the bar.
        let parser = VoiceControlParser()
        parser.config.strictWake = true
        let bar: (String) -> Bool = { parser.remainderIsDeterministicCommand($0) }

        // Bare wake arms.
        XCTAssertEqual(
            gate.decide(remainder: parser.wakeRemainder("Pawvis"),
                        transcript: "Pawvis", now: 0, strictCommandBar: bar),
            .armed)
        // Ambient next final (previously taken verbatim, straight to the
        // agent) now refuses: no wake word, and it doesn't parse.
        XCTAssertEqual(
            gate.decide(remainder: parser.wakeRemainder("she went home yesterday"),
                        transcript: "she went home yesterday", now: 2,
                        strictCommandBar: bar),
            .ignored)
        // Re-arm; a deterministic next final still stitches.
        XCTAssertEqual(
            gate.decide(remainder: parser.wakeRemainder("Pawvis"),
                        transcript: "Pawvis", now: 3, strictCommandBar: bar),
            .armed)
        XCTAssertEqual(
            gate.decide(remainder: parser.wakeRemainder("open safari"),
                        transcript: "open safari", now: 4, strictCommandBar: bar),
            .command("open safari"))
        // And a wake-carrying final works exactly as before.
        XCTAssertEqual(
            gate.decide(remainder: parser.wakeRemainder("pawvis quit chrome"),
                        transcript: "pawvis quit chrome", now: 5, strictCommandBar: bar),
            .command("quit chrome"))
    }

    func testNilBarKeepsTheVerbatimCapture() {
        // Strict capture is opt-in per call: without the bar (the on-device
        // path), the window behaves exactly as the tests above pin it.
        XCTAssertEqual(gate.decide(remainder: "", transcript: "Pawvis", now: 0), .armed)
        XCTAssertEqual(
            gate.decide(remainder: nil, transcript: "she went home yesterday", now: 2),
            .command("she went home yesterday"))
    }
}
