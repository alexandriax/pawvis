import XCTest
@testable import PawvisCore

final class VoiceControlParserTests: XCTestCase {
    var parser: VoiceControlParser!

    override func setUp() {
        super.setUp()
        parser = VoiceControlParser()
    }

    private func parse(_ transcript: String) -> VoiceParseResult {
        parser.parse(transcript)
    }

    // MARK: - Wake word gating

    func testWakeWordThenTypeTypesRemainderOneShot() {
        let result = parse("Pawvis type hello world.")
        XCTAssertEqual(result.typing, [.type("hello world.")])
        XCTAssertNil(result.command)
    }

    func testBareWakeWordDoesNothing() {
        XCTAssertEqual(parse("Pawvis"), VoiceParseResult())
    }

    func testWakeWordWithPunctuationAndCase() {
        XCTAssertEqual(parse("Pawvis, type Hello there!").typing, [.type("Hello there!")])
    }

    func testSpeechWithoutWakeWordIsIgnored() {
        XCTAssertEqual(parse("type hello world"), VoiceParseResult())
        XCTAssertEqual(parse("open safari"), VoiceParseResult())
        XCTAssertEqual(parse("hello this should not be typed"), VoiceParseResult())
    }

    func testEachCommandNeedsItsOwnWakeWord() {
        // A type command does NOT arm any mode: the next utterance without
        // the wake word does nothing.
        XCTAssertEqual(parse("Pawvis type first line").typing, [.type("first line")])
        XCTAssertEqual(parse("second line"), VoiceParseResult())
        XCTAssertEqual(parse("Pawvis type second line").typing, [.type("second line")])
    }

    func testFuzzyWakeMishearings() {
        for heard in ["Pavis", "Pawviz", "Paw vis", "Pawbis", "Jarvis", "Purvis"] {
            let result = parse("\(heard) type hi")
            XCTAssertEqual(result.typing, [.type("hi")], "wake mishearing '\(heard)' must match")
        }
    }

    func testUnrelatedWordsDoNotWake() {
        for heard in ["Practice typing now", "Office type hello", "Pause the video"] {
            XCTAssertEqual(parse(heard), VoiceParseResult(), "'\(heard)' must not wake")
        }
    }

    func testCustomWakeWord() {
        parser.config.wakeWord = "computer"
        parser.config.wakeWordAliases = []
        XCTAssertEqual(parse("Pawvis type hello"), VoiceParseResult())
        XCTAssertEqual(parse("Computer type hello").typing, [.type("hello")])
    }

    func testMultiWordWakeWord() {
        parser.config.wakeWord = "hey pawvis"
        XCTAssertEqual(parse("Hey Pawvis type hello world").typing, [.type("hello world")])
    }

    func testHasWakePrefix() {
        XCTAssertTrue(parser.hasWakePrefix("Pawvis open safari"))
        XCTAssertTrue(parser.hasWakePrefix("Pavis"))
        XCTAssertTrue(parser.hasWakePrefix("paw viz go to reddit.com"))
        XCTAssertFalse(parser.hasWakePrefix("open safari"))
        XCTAssertFalse(parser.hasWakePrefix("talking about something else"))
        XCTAssertFalse(parser.hasWakePrefix(""))
    }

    // The near tier nominates borderline mishearings for on-device AI
    // confirmation on the agent path — it must be wider than the strict
    // gate but still reject plainly unrelated speech.
    func testNearWakeCatchesMishearingsTheStrictGateRejects() {
        XCTAssertNil(parser.wakeRemainder("Paw this open Safari"))
        XCTAssertEqual(parser.nearWakeRemainder("Paw this open Safari"), "open Safari")
    }

    func testNearWakeIncludesStrictMatches() {
        XCTAssertEqual(parser.nearWakeRemainder("Pawvis open Safari"), "open Safari")
        XCTAssertEqual(parser.nearWakeRemainder("Pavis type hi"), "type hi")
    }

    func testNearWakeStillRejectsUnrelatedSpeech() {
        for heard in ["Practice typing now", "Pause the video", "open safari",
                      "talking about something else", ""] {
            XCTAssertNil(parser.nearWakeRemainder(heard), "'\(heard)' must not near-wake")
        }
    }

    // MARK: - Commands: go to / search

    func testGoToSpokenURL() {
        let result = parse("Pawvis go to here's alexandria dot com")
        XCTAssertEqual(result.command, .goTo(url: "heresalexandria.com"))
        XCTAssertEqual(result.typing, [])
    }

    func testGoToRecognizerFormattedURL() {
        XCTAssertEqual(parse("Pawvis go to github.com/anthropics.").command,
                       .goTo(url: "github.com/anthropics"))
    }

    func testGoToWithPathWords() {
        XCTAssertEqual(parse("Pawvis go to github dot com slash anthropics").command,
                       .goTo(url: "github.com/anthropics"))
    }

    func testGoToNonURLBecomesWebSearch() {
        XCTAssertEqual(parse("Pawvis go to the apple store").command,
                       .webSearch(query: "the apple store"))
    }

    func testSearchFor() {
        XCTAssertEqual(parse("Pawvis search for sloth videos").command,
                       .webSearch(query: "sloth videos"))
    }

    // MARK: - Commands: keys

    func testPressEnter() {
        XCTAssertEqual(parse("Pawvis press enter").command,
                       .press(KeyChord(key: "return")))
    }

    func testPressChordWithModifiers() {
        XCTAssertEqual(parse("Pawvis press command shift T").command,
                       .press(KeyChord(key: "t", modifiers: [.command, .shift])))
    }

    func testPressNamedKeys() {
        XCTAssertEqual(parse("Pawvis press escape").command,
                       .press(KeyChord(key: "escape")))
        XCTAssertEqual(parse("Pawvis hit page down").command,
                       .press(KeyChord(key: "pagedown")))
        XCTAssertEqual(parse("Pawvis press the up arrow").command,
                       .press(KeyChord(key: "up")))
        XCTAssertEqual(parse("Pawvis press F5").command,
                       .press(KeyChord(key: "f5")))
    }

    func testPressUnknownKeyFallsBackToResolve() {
        XCTAssertEqual(parse("Pawvis press the big red button").command,
                       .resolve(transcript: "press the big red button"))
    }

    // MARK: - Commands: apps

    func testOpenApp() {
        XCTAssertEqual(parse("Pawvis open Safari").command, .open(app: "Safari"))
    }

    func testOpenAppMultiWord() {
        XCTAssertEqual(parse("Pawvis open Google Chrome.").command,
                       .open(app: "Google Chrome"))
    }

    func testSwitchToApp() {
        XCTAssertEqual(parse("Pawvis switch to Notes").command, .switchTo(app: "Notes"))
    }

    func testSwitchToNeverParsesAsGoTo() {
        XCTAssertEqual(parse("Pawvis switch back to chrome").command,
                       .switchTo(app: "chrome"))
    }

    // MARK: - Commands: click / scroll / stop

    func testBareClicks() {
        XCTAssertEqual(parse("Pawvis click").command, .click(.left))
        XCTAssertEqual(parse("Pawvis right click").command, .click(.right))
        XCTAssertEqual(parse("Pawvis double click").command, .click(.double))
    }

    func testClickWithTargetGoesToResolver() {
        XCTAssertEqual(parse("Pawvis click sign in").command,
                       .resolve(transcript: "click sign in"))
    }

    func testScroll() {
        XCTAssertEqual(parse("Pawvis scroll down").command,
                       .scroll(direction: .down, amount: .step))
        XCTAssertEqual(parse("Pawvis scroll up a little").command,
                       .scroll(direction: .up, amount: .nudge))
        XCTAssertEqual(parse("Pawvis scroll down a page").command,
                       .scroll(direction: .down, amount: .page))
    }

    func testStopListening() {
        XCTAssertEqual(parse("Pawvis stop listening").command, .stopVoiceControl)
        XCTAssertEqual(parse("Pawvis go to sleep").command, .stopVoiceControl)
    }

    func testBareStopIsCancelNotStopListening() {
        // "stop" brakes whatever is running; only the explicit sleep
        // phrases turn voice control off.
        for phrase in ["stop", "stop it", "cancel", "cancel that", "never mind", "nevermind"] {
            XCTAssertEqual(parse("Pawvis \(phrase)").command, .cancelActivity,
                           "'\(phrase)' must cancel")
        }
    }

    func testPaddedStopPhrasesStillBrake() {
        // Politeness padding must never turn a safety phrase into an
        // autopilot goal.
        XCTAssertEqual(parse("Pawvis please stop listening").command, .stopVoiceControl)
        XCTAssertEqual(parse("Pawvis ok stop now").command, .cancelActivity)
        XCTAssertEqual(parse("Pawvis hey stop").command, .cancelActivity)
        XCTAssertEqual(parse("Pawvis go to sleep now").command, .stopVoiceControl)
        // But padding words inside a real request stay a request.
        XCTAssertEqual(parse("Pawvis stop the music").command,
                       .resolve(transcript: "stop the music"))
    }

    func testUnknownCommandFallsBackToResolve() {
        XCTAssertEqual(parse("Pawvis make it bigger").command,
                       .resolve(transcript: "make it bigger"))
    }

    // MARK: - Commands: window / edit chords + quit

    func testWholePhraseWindowAndEditChords() {
        let cases: [(String, KeyChord)] = [
            ("close window", KeyChord(key: "w", modifiers: [.command])),
            ("close the window", KeyChord(key: "w", modifiers: [.command])),
            ("close this tab", KeyChord(key: "w", modifiers: [.command])),
            ("minimize", KeyChord(key: "m", modifiers: [.command])),
            ("hide", KeyChord(key: "h", modifiers: [.command])),
            ("new tab", KeyChord(key: "t", modifiers: [.command])),
            ("new window", KeyChord(key: "n", modifiers: [.command])),
            ("copy", KeyChord(key: "c", modifiers: [.command])),
            ("paste", KeyChord(key: "v", modifiers: [.command])),
            ("cut", KeyChord(key: "x", modifiers: [.command])),
            ("undo", KeyChord(key: "z", modifiers: [.command])),
            ("redo", KeyChord(key: "z", modifiers: [.command, .shift])),
            ("save", KeyChord(key: "s", modifiers: [.command])),
            ("select all", KeyChord(key: "a", modifiers: [.command])),
            ("full screen", KeyChord(key: "f", modifiers: [.control, .command])),
        ]
        for (phrase, chord) in cases {
            XCTAssertEqual(parse("Pawvis \(phrase)").command, .press(chord),
                           "'\(phrase)' must press \(chord.key)")
        }
    }

    func testChordPhrasesWithTrailingWordsFallToResolve() {
        // Whole-utterance only: extra words mean the user wants more than
        // the shortcut, and the autopilot should see the whole request.
        XCTAssertEqual(parse("Pawvis copy that file over there").command,
                       .resolve(transcript: "copy that file over there"))
        XCTAssertEqual(parse("Pawvis save the draft and close it").command,
                       .resolve(transcript: "save the draft and close it"))
    }

    func testMultiClauseUtteranceFallsThroughToResolve() {
        XCTAssertEqual(
            parse("Pawvis close the window and open Safari").command,
            .resolve(transcript: "close the window and open Safari"))
    }

    func testQuit() {
        XCTAssertEqual(parse("Pawvis quit").command, .quit(app: nil))
        XCTAssertEqual(parse("Pawvis quit this app").command, .quit(app: nil))
        XCTAssertEqual(parse("Pawvis quit Safari").command, .quit(app: "Safari"))
    }

    func testQuitPronounsNeverFuzzyMatchAnApp() {
        // "quit it" must pin to the frontmost app — a two-letter payload
        // would fuzzy-match a real app name ("it" → iTerm).
        for phrase in ["quit it", "quit this", "quit that", "quit the app"] {
            XCTAssertEqual(parse("Pawvis \(phrase)").command, .quit(app: nil),
                           "'\(phrase)' must quit the frontmost app")
        }
    }

    func testResolveTranscriptIsWakeStripped() {
        // The free-form path (agent CLI / intent mapper) must receive a
        // clean phrase without the wake word.
        guard case .resolve(let transcript)? =
                parse("Pawvis, make the window bigger please").command else {
            return XCTFail("expected .resolve")
        }
        XCTAssertEqual(transcript, "make the window bigger please")
        XCTAssertFalse(transcript.lowercased().contains("pawvis"))
    }

    // MARK: - Statelessness

    func testCommandsDoNotAffectLaterUtterances() {
        _ = parse("Pawvis type hello")
        _ = parse("Pawvis press enter")
        _ = parse("Pawvis open Safari")
        // After any command, plain speech still does nothing.
        XCTAssertEqual(parse("just chatting with a friend"), VoiceParseResult())
        // And the same command parses identically every time.
        XCTAssertEqual(parse("Pawvis type hello").typing, [.type("hello")])
    }

    // MARK: - Empty / noise

    func testEmptyAndWhitespaceTranscriptsDoNothing() {
        XCTAssertEqual(parse(""), VoiceParseResult())
        XCTAssertEqual(parse("   "), VoiceParseResult())
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

    func testBoundedEditDistance() {
        XCTAssertTrue(VoiceControlParser.editDistance("pawthis", "pawvis", isAtMost: 2))
        XCTAssertTrue(VoiceControlParser.editDistance("paws", "pawvis", isAtMost: 2))
        XCTAssertFalse(VoiceControlParser.editDistance("pause", "pawvis", isAtMost: 2))
        XCTAssertFalse(VoiceControlParser.editDistance("practice", "pawvis", isAtMost: 2))
        XCTAssertFalse(VoiceControlParser.editDistance("pawthis", "pawvis", isAtMost: 1))
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
