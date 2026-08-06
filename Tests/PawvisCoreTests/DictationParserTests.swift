import XCTest
@testable import PawvisCore

final class DictationParserTests: XCTestCase {
    var parser: DictationParser!

    override func setUp() {
        super.setUp()
        parser = DictationParser()
        parser.beginListening()
    }

    private func complete(_ transcript: String, item: String = UUID().uuidString) -> [TypingAction] {
        parser.handleCompleted(itemId: item, transcript: transcript)
    }

    // MARK: - Wake words

    func testWakeWordStartsDictationAndTypesRemainder() {
        let actions = complete("Type hello world.")
        XCTAssertEqual(actions, [.type("hello world.")])
        XCTAssertEqual(parser.state, .dictating)
    }

    func testBareWakeWordJustArms() {
        let actions = complete("Type")
        XCTAssertEqual(actions, [])
        XCTAssertEqual(parser.state, .dictating)
    }

    func testWakeWordWithPunctuationAndCase() {
        let actions = complete("Type, Hello there!")
        XCTAssertEqual(actions, [.type("Hello there!")])
    }

    func testAllDefaultWakeWordsWork() {
        for wake in ["type", "text", "enter", "write", "dictate"] {
            parser.beginListening()
            _ = complete("\(wake) something")
            XCTAssertEqual(parser.state, .dictating, "wake word '\(wake)' must arm dictation")
        }
    }

    func testNonWakeSpeechIsIgnoredWhileListening() {
        let actions = complete("hello this should not be typed")
        XCTAssertEqual(actions, [])
        XCTAssertEqual(parser.state, .listening)
    }

    func testWakeWordAsPrefixOfLongerWordDoesNotTrigger() {
        let actions = complete("typewriter maintenance is due")
        XCTAssertEqual(actions, [])
        XCTAssertEqual(parser.state, .listening)
    }

    func testCustomWakeWords() {
        parser.config.wakeWords = ["computer"]
        XCTAssertEqual(complete("type hello"), [])
        XCTAssertEqual(parser.state, .listening)
        XCTAssertEqual(complete("Computer hello"), [.type("hello")])
        XCTAssertEqual(parser.state, .dictating)
    }

    func testMultiWordWakeWord() {
        parser.config.wakeWords = ["start typing"]
        XCTAssertEqual(complete("Start typing hello world"), [.type("hello world")])
    }

    // MARK: - Dictating

    func testUtterancesAreTypedWithSmartSpacing() {
        _ = complete("type Hello world.")
        let second = complete("This is Pawvis.")
        XCTAssertEqual(second, [.type(" This is Pawvis.")],
                       "a space joins utterances when the last char wasn't whitespace")
    }

    func testNoLeadingSpaceForPunctuationStart() {
        _ = complete("type Hello")
        let second = complete(", world")
        XCTAssertEqual(second, [.type(", world")])
    }

    func testWakeWordMidSentenceIsTypedLiterally() {
        _ = complete("type start")
        let actions = complete("type this literally")
        XCTAssertEqual(actions, [.type(" type this literally")],
                       "wake words have no special meaning while dictating")
    }

    // MARK: - Stop phrases

    func testStopPhraseAloneStopsWithoutTyping() {
        _ = complete("type hello")
        let actions = complete("Stop typing.")
        XCTAssertEqual(actions, [])
        XCTAssertEqual(parser.state, .listening)
    }

    func testStopPhraseAtEndTypesPrefixThenStops() {
        _ = complete("type note to self")
        let actions = complete("buy more coffee, stop typing")
        XCTAssertEqual(actions, [.type(" buy more coffee")])
        XCTAssertEqual(parser.state, .listening)
    }

    func testAllDefaultStopPhrasesWork() {
        for stop in ["stop typing", "stop dictating", "stop dictation", "done typing", "end dictation"] {
            parser.beginListening()
            _ = complete("type hello")
            _ = complete(stop)
            XCTAssertEqual(parser.state, .listening, "stop phrase '\(stop)' must disarm")
        }
    }

    func testSpeechAfterStopIsIgnoredUntilNextWake() {
        _ = complete("type hello")
        _ = complete("stop typing")
        XCTAssertEqual(complete("this must not be typed"), [])
        XCTAssertEqual(complete("write but this must"), [.type("but this must")])
    }

    // MARK: - Commands

    func testNewLineCommand() {
        _ = complete("type hello")
        XCTAssertEqual(complete("new line"), [.type("\n")])
        // After a newline, no smart space.
        XCTAssertEqual(complete("world"), [.type("world")])
    }

    func testNewParagraphCommand() {
        _ = complete("type hello")
        XCTAssertEqual(complete("New paragraph."), [.type("\n\n")])
    }

    func testPressEnterCommand() {
        _ = complete("type ship it")
        XCTAssertEqual(complete("press enter"), [.key(.return)])
        XCTAssertEqual(parser.state, .dictating, "pressing enter stays in dictation")
    }

    func testPressTabCommand() {
        _ = complete("type field one")
        XCTAssertEqual(complete("press tab"), [.key(.tab)])
    }

    func testCommandsDisabled() {
        parser.config.commandsEnabled = false
        _ = complete("type hello")
        XCTAssertEqual(complete("new line"), [.type(" new line")],
                       "with commands off, command phrases are typed literally")
    }

    func testCommandWordsInsideSentenceAreTypedLiterally() {
        _ = complete("type the")
        XCTAssertEqual(complete("new line of products"), [.type(" new line of products")])
    }

    // MARK: - Empty / noise

    func testEmptyAndWhitespaceTranscriptsDoNothing() {
        XCTAssertEqual(complete(""), [])
        XCTAssertEqual(complete("   "), [])
        _ = complete("type hello")
        XCTAssertEqual(complete("  "), [])
    }

    // MARK: - Delta mode

    func testDeltasNotTypedWhileListening() {
        parser.config.typeDeltasImmediately = true
        XCTAssertEqual(parser.handleDelta(itemId: "a", delta: "random"), [])
        XCTAssertEqual(parser.state, .listening)
    }

    func testDeltasTypedLiveWhileDictating() {
        parser.config.typeDeltasImmediately = true
        _ = complete("type start")
        let d1 = parser.handleDelta(itemId: "b", delta: "Hello")
        XCTAssertEqual(d1, [.type(" Hello")], "first delta gets the smart space")
        let d2 = parser.handleDelta(itemId: "b", delta: " world")
        XCTAssertEqual(d2, [.type(" world")])
        // Final matches what was typed → nothing more.
        XCTAssertEqual(parser.handleCompleted(itemId: "b", transcript: "Hello world"), [])
    }

    func testDeltaFinalExtendsTyped() {
        parser.config.typeDeltasImmediately = true
        _ = complete("type go")
        _ = parser.handleDelta(itemId: "c", delta: "Hello")
        let actions = parser.handleCompleted(itemId: "c", transcript: "Hello world.")
        XCTAssertEqual(actions, [.type(" world.")])
    }

    func testDeltaFinalRevisionBackspacesAndRetypes() {
        parser.config.typeDeltasImmediately = true
        _ = complete("type go")
        _ = parser.handleDelta(itemId: "d", delta: "recognize speech")
        let actions = parser.handleCompleted(itemId: "d", transcript: "wreck a nice beach")
        XCTAssertEqual(actions, [.backspace(17), .type(" wreck a nice beach")],
                       "typed ' recognize speech' (17 chars) must be replaced")
    }

    func testDeltaStopPhraseGetsUntyped() {
        parser.config.typeDeltasImmediately = true
        _ = complete("type go")
        _ = parser.handleDelta(itemId: "e", delta: "stop ")
        _ = parser.handleDelta(itemId: "e", delta: "typing")
        let actions = parser.handleCompleted(itemId: "e", transcript: "stop typing")
        XCTAssertEqual(actions, [.backspace(12)], "' stop typing' (12 chars) must vanish")
        XCTAssertEqual(parser.state, .listening)
    }

    func testDeltaCommandBackspacesThenPressesKey() {
        parser.config.typeDeltasImmediately = true
        _ = complete("type go")
        _ = parser.handleDelta(itemId: "f", delta: "press enter")
        let actions = parser.handleCompleted(itemId: "f", transcript: "press enter")
        XCTAssertEqual(actions, [.backspace(12), .key(.return)])
    }

    // MARK: - Reset

    func testBeginListeningResetsState() {
        _ = complete("type hello")
        XCTAssertEqual(parser.state, .dictating)
        parser.beginListening()
        XCTAssertEqual(parser.state, .listening)
        XCTAssertEqual(complete("not typed"), [])
    }

    // MARK: - Normalization helpers

    func testNormalize() {
        XCTAssertEqual(DictationParser.normalize("  Stop, Typing!  "), "stop typing")
        XCTAssertEqual(DictationParser.normalize("TYPE"), "type")
        XCTAssertEqual(DictationParser.normalize("new\n line"), "new line")
    }
}
