import XCTest
@testable import PawvisCore

final class VoiceControlParserTests: XCTestCase {
    var parser: VoiceControlParser!

    override func setUp() {
        super.setUp()
        parser = VoiceControlParser()
        parser.beginListening()
    }

    private func complete(_ transcript: String, item: String = UUID().uuidString) -> VoiceParseResult {
        parser.handleCompleted(itemId: item, transcript: transcript)
    }

    @discardableResult
    private func startTyping(_ payload: String = "hello") -> VoiceParseResult {
        complete("Pawvis type \(payload)")
    }

    // MARK: - Wake word

    func testWakeWordThenTypeStartsTypingAndTypesRemainder() {
        let result = complete("Pawvis type hello world.")
        XCTAssertEqual(result.typing, [.type("hello world.")])
        XCTAssertNil(result.command)
        XCTAssertEqual(parser.state, .typing)
    }

    func testBareWakeWordDoesNothing() {
        let result = complete("Pawvis")
        XCTAssertEqual(result, VoiceParseResult())
        XCTAssertEqual(parser.state, .listening)
    }

    func testWakeWordWithPunctuationAndCase() {
        let result = complete("Pawvis, type Hello there!")
        XCTAssertEqual(result.typing, [.type("Hello there!")])
    }

    func testNonWakeSpeechIsIgnoredWhileListening() {
        let result = complete("hello this should not be typed")
        XCTAssertEqual(result, VoiceParseResult())
        XCTAssertEqual(parser.state, .listening)
    }

    func testFuzzyWakeMishearings() {
        // Edit distance 1 and the default alias list.
        for heard in ["Pavis", "Pawviz", "Paw vis", "Pawbis", "Jarvis", "Purvis"] {
            parser.beginListening()
            let result = complete("\(heard) type hi")
            XCTAssertEqual(result.typing, [.type("hi")], "wake mishearing '\(heard)' must match")
            XCTAssertEqual(parser.state, .typing)
        }
    }

    func testUnrelatedWordsDoNotWake() {
        for heard in ["Practice typing now", "Office type hello", "Pause the video"] {
            parser.beginListening()
            let result = complete(heard)
            XCTAssertEqual(result, VoiceParseResult(), "'\(heard)' must not wake")
            XCTAssertEqual(parser.state, .listening)
        }
    }

    func testCustomWakeWord() {
        parser.config.wakeWord = "computer"
        parser.config.wakeWordAliases = []
        XCTAssertEqual(complete("Pawvis type hello"), VoiceParseResult())
        XCTAssertEqual(parser.state, .listening)
        XCTAssertEqual(complete("Computer type hello").typing, [.type("hello")])
        XCTAssertEqual(parser.state, .typing)
    }

    func testMultiWordWakeWord() {
        parser.config.wakeWord = "hey pawvis"
        XCTAssertEqual(complete("Hey Pawvis type hello world").typing, [.type("hello world")])
    }

    // MARK: - Commands: go to / search

    func testGoToSpokenURL() {
        let result = complete("Pawvis go to here's alexandria dot com")
        XCTAssertEqual(result.command, .goTo(url: "heresalexandria.com"))
        XCTAssertEqual(result.typing, [])
        XCTAssertEqual(parser.state, .listening)
    }

    func testGoToRecognizerFormattedURL() {
        let result = complete("Pawvis go to github.com/anthropics.")
        XCTAssertEqual(result.command, .goTo(url: "github.com/anthropics"))
    }

    func testGoToWithPathWords() {
        let result = complete("Pawvis go to github dot com slash anthropics")
        XCTAssertEqual(result.command, .goTo(url: "github.com/anthropics"))
    }

    func testGoToNonURLBecomesWebSearch() {
        let result = complete("Pawvis go to the apple store")
        XCTAssertEqual(result.command, .webSearch(query: "the apple store"))
    }

    func testSearchFor() {
        let result = complete("Pawvis search for sloth videos")
        XCTAssertEqual(result.command, .webSearch(query: "sloth videos"))
    }

    // MARK: - Commands: keys

    func testPressEnter() {
        XCTAssertEqual(complete("Pawvis press enter").command,
                       .press(KeyChord(key: "return")))
    }

    func testPressChordWithModifiers() {
        XCTAssertEqual(complete("Pawvis press command shift T").command,
                       .press(KeyChord(key: "t", modifiers: [.command, .shift])))
    }

    func testPressNamedKeys() {
        XCTAssertEqual(complete("Pawvis press escape").command,
                       .press(KeyChord(key: "escape")))
        XCTAssertEqual(complete("Pawvis hit page down").command,
                       .press(KeyChord(key: "pagedown")))
        XCTAssertEqual(complete("Pawvis press the up arrow").command,
                       .press(KeyChord(key: "up")))
        XCTAssertEqual(complete("Pawvis press F5").command,
                       .press(KeyChord(key: "f5")))
    }

    func testPressUnknownKeyFallsBackToResolve() {
        XCTAssertEqual(complete("Pawvis press the big red button").command,
                       .resolve(transcript: "press the big red button"))
    }

    // MARK: - Commands: apps

    func testOpenApp() {
        XCTAssertEqual(complete("Pawvis open Safari").command, .open(app: "Safari"))
    }

    func testOpenAppMultiWord() {
        XCTAssertEqual(complete("Pawvis open Google Chrome.").command,
                       .open(app: "Google Chrome"))
    }

    func testSwitchToApp() {
        XCTAssertEqual(complete("Pawvis switch to Notes").command, .switchTo(app: "Notes"))
    }

    func testSwitchToNeverParsesAsGoTo() {
        XCTAssertEqual(complete("Pawvis switch back to chrome").command,
                       .switchTo(app: "chrome"))
    }

    // MARK: - Commands: click / scroll / stop

    func testBareClicks() {
        XCTAssertEqual(complete("Pawvis click").command, .click(.left))
        XCTAssertEqual(complete("Pawvis right click").command, .click(.right))
        XCTAssertEqual(complete("Pawvis double click").command, .click(.double))
    }

    func testClickWithTargetGoesToResolver() {
        XCTAssertEqual(complete("Pawvis click sign in").command,
                       .resolve(transcript: "click sign in"))
    }

    func testScroll() {
        XCTAssertEqual(complete("Pawvis scroll down").command,
                       .scroll(direction: .down, amount: .step))
        XCTAssertEqual(complete("Pawvis scroll up a little").command,
                       .scroll(direction: .up, amount: .nudge))
        XCTAssertEqual(complete("Pawvis scroll down a page").command,
                       .scroll(direction: .down, amount: .page))
    }

    func testStopListening() {
        XCTAssertEqual(complete("Pawvis stop listening").command, .stopVoiceControl)
        XCTAssertEqual(complete("Pawvis go to sleep").command, .stopVoiceControl)
    }

    func testUnknownCommandFallsBackToResolve() {
        XCTAssertEqual(complete("Pawvis close this window").command,
                       .resolve(transcript: "close this window"))
        XCTAssertEqual(parser.state, .listening)
    }

    // MARK: - Typing mode

    func testUtterancesAreTypedWithSmartSpacing() {
        startTyping("Hello world.")
        let second = complete("This is Pawvis speaking.")
        XCTAssertEqual(second.typing, [.type(" This is Pawvis speaking.")],
                       "a space joins utterances when the last char wasn't whitespace")
    }

    func testNoLeadingSpaceForPunctuationStart() {
        startTyping("Hello")
        XCTAssertEqual(complete(", world").typing, [.type(", world")])
    }

    func testTypeVerbMidTypingIsTypedLiterally() {
        startTyping("start")
        let result = complete("this is not a command")
        XCTAssertEqual(result.typing, [.type(" this is not a command")])
    }

    func testWakeCommandWhileTypingExecutesInsteadOfTyping() {
        startTyping("dear diary")
        let result = complete("Pawvis press enter")
        XCTAssertEqual(result.typing, [])
        XCTAssertEqual(result.command, .press(KeyChord(key: "return")))
        XCTAssertEqual(parser.state, .typing, "command execution stays in typing mode")
    }

    func testWakeStopTypingWhileTyping() {
        startTyping("note")
        let result = complete("Pawvis stop typing")
        XCTAssertEqual(result, VoiceParseResult())
        XCTAssertEqual(parser.state, .listening)
    }

    func testPauseTimeoutEndsTyping() {
        startTyping("hello")
        XCTAssertTrue(parser.handlePauseTimeout())
        XCTAssertEqual(parser.state, .listening)
        XCTAssertFalse(parser.handlePauseTimeout(), "already listening")
        XCTAssertEqual(complete("this must not be typed"), VoiceParseResult())
    }

    // MARK: - Stop phrases

    func testStopPhraseAloneStopsWithoutTyping() {
        startTyping()
        let result = complete("Stop typing.")
        XCTAssertEqual(result.typing, [])
        XCTAssertEqual(parser.state, .listening)
    }

    func testStopPhraseAtEndTypesPrefixThenStops() {
        startTyping("note to self")
        let result = complete("buy more coffee, stop typing")
        XCTAssertEqual(result.typing, [.type(" buy more coffee")])
        XCTAssertEqual(parser.state, .listening)
    }

    func testSpeechAfterStopIsIgnoredUntilNextWake() {
        startTyping()
        _ = complete("stop typing")
        XCTAssertEqual(complete("this must not be typed"), VoiceParseResult())
        XCTAssertEqual(complete("Pawvis write but this must").typing, [.type("but this must")])
    }

    // MARK: - Inline commands while typing

    func testNewLineCommand() {
        startTyping()
        XCTAssertEqual(complete("new line").typing, [.type("\n")])
        // After a newline, no smart space.
        XCTAssertEqual(complete("world").typing, [.type("world")])
    }

    func testNewParagraphCommand() {
        startTyping()
        XCTAssertEqual(complete("New paragraph.").typing, [.type("\n\n")])
    }

    func testPressEnterInline() {
        startTyping("ship it")
        XCTAssertEqual(complete("press enter").typing, [.key(KeyChord(key: "return"))])
        XCTAssertEqual(parser.state, .typing, "pressing enter stays in typing mode")
    }

    func testPressTabInline() {
        startTyping("field one")
        XCTAssertEqual(complete("press tab").typing, [.key(KeyChord(key: "tab"))])
    }

    func testInlineCommandsDisabled() {
        parser.config.inlineCommandsEnabled = false
        startTyping()
        XCTAssertEqual(complete("new line").typing, [.type(" new line")],
                       "with inline commands off, command phrases are typed literally")
    }

    func testCommandWordsInsideSentenceAreTypedLiterally() {
        startTyping("the")
        XCTAssertEqual(complete("new line of products").typing,
                       [.type(" new line of products")])
    }

    // MARK: - Empty / noise

    func testEmptyAndWhitespaceTranscriptsDoNothing() {
        XCTAssertEqual(complete(""), VoiceParseResult())
        XCTAssertEqual(complete("   "), VoiceParseResult())
        startTyping()
        XCTAssertEqual(complete("  "), VoiceParseResult())
    }

    // MARK: - Delta mode

    func testDeltasNotTypedWhileListening() {
        parser.config.typeDeltasImmediately = true
        XCTAssertEqual(parser.handleDelta(itemId: "a", delta: "random"), [])
        XCTAssertEqual(parser.state, .listening)
    }

    func testDeltasTypedLiveWhileTyping() {
        parser.config.typeDeltasImmediately = true
        startTyping("start")
        let d1 = parser.handleDelta(itemId: "b", delta: "Hello")
        XCTAssertEqual(d1, [.type(" Hello")], "first delta gets the smart space")
        let d2 = parser.handleDelta(itemId: "b", delta: " world")
        XCTAssertEqual(d2, [.type(" world")])
        // Final matches what was typed → nothing more.
        XCTAssertEqual(parser.handleCompleted(itemId: "b", transcript: "Hello world"),
                       VoiceParseResult())
    }

    func testDeltaFinalExtendsTyped() {
        parser.config.typeDeltasImmediately = true
        startTyping("go")
        _ = parser.handleDelta(itemId: "c", delta: "Hello")
        let result = parser.handleCompleted(itemId: "c", transcript: "Hello world.")
        XCTAssertEqual(result.typing, [.type(" world.")])
    }

    func testDeltaFinalRevisionBackspacesAndRetypes() {
        parser.config.typeDeltasImmediately = true
        startTyping("go")
        _ = parser.handleDelta(itemId: "d", delta: "recognize speech")
        let result = parser.handleCompleted(itemId: "d", transcript: "wreck a nice beach")
        XCTAssertEqual(result.typing, [.backspace(17), .type(" wreck a nice beach")],
                       "typed ' recognize speech' (17 chars) must be replaced")
    }

    func testDeltaStopPhraseGetsUntyped() {
        parser.config.typeDeltasImmediately = true
        startTyping("go")
        _ = parser.handleDelta(itemId: "e", delta: "stop ")
        _ = parser.handleDelta(itemId: "e", delta: "typing")
        let result = parser.handleCompleted(itemId: "e", transcript: "stop typing")
        XCTAssertEqual(result.typing, [.backspace(12)], "' stop typing' (12 chars) must vanish")
        XCTAssertEqual(parser.state, .listening)
    }

    func testDeltaInlineCommandBackspacesThenPressesKey() {
        parser.config.typeDeltasImmediately = true
        startTyping("go")
        _ = parser.handleDelta(itemId: "f", delta: "press enter")
        let result = parser.handleCompleted(itemId: "f", transcript: "press enter")
        XCTAssertEqual(result.typing, [.backspace(12), .key(KeyChord(key: "return"))])
    }

    func testDeltaWakeCommandGetsUntyped() {
        parser.config.typeDeltasImmediately = true
        startTyping("go")
        _ = parser.handleDelta(itemId: "g", delta: "Pawvis stop typing")
        let result = parser.handleCompleted(itemId: "g", transcript: "Pawvis stop typing")
        XCTAssertEqual(result.typing, [.backspace(19)], "' Pawvis stop typing' (19 chars) must vanish")
        XCTAssertEqual(parser.state, .listening)
    }

    // MARK: - Reset

    func testBeginListeningResetsState() {
        startTyping()
        XCTAssertEqual(parser.state, .typing)
        parser.beginListening()
        XCTAssertEqual(parser.state, .listening)
        XCTAssertEqual(complete("not typed"), VoiceParseResult())
    }

    // MARK: - Helpers

    func testNormalize() {
        XCTAssertEqual(VoiceControlParser.normalize("  Stop, Typing!  "), "stop typing")
        XCTAssertEqual(VoiceControlParser.normalize("TYPE"), "type")
        XCTAssertEqual(VoiceControlParser.normalize("new\n line"), "new line")
    }

    func testEditDistance() {
        XCTAssertTrue(VoiceControlParser.editDistanceAtMostOne("pawvis", "pawvis"))
        XCTAssertTrue(VoiceControlParser.editDistanceAtMostOne("pavis", "pawvis"))
        XCTAssertTrue(VoiceControlParser.editDistanceAtMostOne("pawbis", "pawvis"))
        XCTAssertFalse(VoiceControlParser.editDistanceAtMostOne("paws", "pawvis"))
        XCTAssertFalse(VoiceControlParser.editDistanceAtMostOne("practice", "pawvis"))
    }
}

final class SpokenURLNormalizerTests: XCTestCase {
    func testSpokenDotCom() {
        XCTAssertEqual(SpokenURLNormalizer.normalize("here's alexandria dot com"),
                       "heresalexandria.com")
    }

    func testAlreadyFormatted() {
        XCTAssertEqual(SpokenURLNormalizer.normalize("github.com/anthropics"),
                       "github.com/anthropics")
    }

    func testSpokenPathAndDashes() {
        XCTAssertEqual(SpokenURLNormalizer.normalize("my dash site dot io slash blog"),
                       "my-site.io/blog")
    }

    func testTrailingPunctuationStripped() {
        XCTAssertEqual(SpokenURLNormalizer.normalize("example.com."), "example.com")
    }

    func testLocalhost() {
        XCTAssertEqual(SpokenURLNormalizer.normalize("localhost colon 3000"),
                       "localhost:3000")
    }

    func testNonURLReturnsNil() {
        XCTAssertNil(SpokenURLNormalizer.normalize("the apple store"))
        XCTAssertNil(SpokenURLNormalizer.normalize(""))
    }
}

final class SpokenKeyParserTests: XCTestCase {
    private func chord(_ spoken: String) -> KeyChord? {
        SpokenKeyParser.chord(from: spoken.split(separator: " ").map(String.init))
    }

    func testNamedKeys() {
        XCTAssertEqual(chord("enter"), KeyChord(key: "return"))
        XCTAssertEqual(chord("return"), KeyChord(key: "return"))
        XCTAssertEqual(chord("escape"), KeyChord(key: "escape"))
        XCTAssertEqual(chord("space"), KeyChord(key: "space"))
        XCTAssertEqual(chord("backspace"), KeyChord(key: "delete"))
    }

    func testModifiers() {
        XCTAssertEqual(chord("command t"), KeyChord(key: "t", modifiers: [.command]))
        XCTAssertEqual(chord("command shift t"), KeyChord(key: "t", modifiers: [.command, .shift]))
        XCTAssertEqual(chord("control option delete"),
                       KeyChord(key: "delete", modifiers: [.control, .option]))
        XCTAssertEqual(chord("cmd q"), KeyChord(key: "q", modifiers: [.command]))
    }

    func testMultiWordKeys() {
        XCTAssertEqual(chord("page down"), KeyChord(key: "pagedown"))
        XCTAssertEqual(chord("up arrow"), KeyChord(key: "up"))
        XCTAssertEqual(chord("arrow left"), KeyChord(key: "left"))
        XCTAssertEqual(chord("forward delete"), KeyChord(key: "forwarddelete"))
    }

    func testFillerWords() {
        XCTAssertEqual(chord("the enter key"), KeyChord(key: "return"))
    }

    func testDigitsAndFunctionKeys() {
        XCTAssertEqual(chord("five"), KeyChord(key: "5"))
        XCTAssertEqual(chord("f5"), KeyChord(key: "f5"))
        XCTAssertEqual(chord("f twelve"), nil, "spelled multi-digit f-keys aren't supported")
        XCTAssertEqual(chord("command 1"), KeyChord(key: "1", modifiers: [.command]))
    }

    func testUnknownReturnsNil() {
        XCTAssertNil(chord("the big red button"))
        XCTAssertNil(chord(""))
        XCTAssertNil(chord("command"), "modifier with no key is not a chord")
    }
}
