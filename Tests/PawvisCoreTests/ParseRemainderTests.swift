import XCTest
@testable import PawvisCore

/// `parseRemainder` runs the grammar on an utterance whose wake word was
/// spoken in an earlier segment (stitched on by the utterance gate) — it must
/// behave exactly like `parse` behaves after stripping the wake word.
final class ParseRemainderTests: XCTestCase {
    var parser = VoiceControlParser()

    override func setUp() {
        super.setUp()
        parser = VoiceControlParser()
    }

    func testRemainderMatchesParseWithWakeWord() {
        for utterance in [
            "type hello world", "open safari", "scroll down",
            "go to github.com", "press enter", "stop listening",
            "do something freeform", "close the window", "quit safari",
            "copy", "stop",
        ] {
            XCTAssertEqual(
                parser.parseRemainder(utterance),
                parser.parse("Pawvis \(utterance)"),
                "parseRemainder(\"\(utterance)\") diverged from parse")
        }
    }

    func testStopPhraseParsesAsStop() {
        XCTAssertEqual(parser.parseRemainder("stop listening").command, .stopVoiceControl)
    }

    func testUnrecognizedRemainderFallsToResolve() {
        XCTAssertEqual(
            parser.parseRemainder("make this window bigger").command,
            .resolve(transcript: "make this window bigger"))
    }

    func testEmptyRemainderDoesNothing() {
        XCTAssertEqual(parser.parseRemainder(""), VoiceParseResult())
        XCTAssertEqual(parser.parseRemainder("  ."), VoiceParseResult())
    }
}
