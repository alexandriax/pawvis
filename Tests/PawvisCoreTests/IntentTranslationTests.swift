import XCTest
@testable import PawvisCore

/// The translation stage compiles the on-device model's structured intent
/// into an executable `VoiceCommand`. Arguments are checked with the same
/// parsers that will execute them, so a compiled command can't fail on
/// decode later — these tests exercise that compilation directly, without
/// any model in the loop.
final class IntentTranslationTests: XCTestCase {
    private func command(
        _ intent: TranslatedIntent, argument: String? = nil, app: String? = nil
    ) -> VoiceCommand? {
        TranslationPolicy.command(
            from: IntentTranslation(intent: intent, argument: argument, app: app))
    }

    // MARK: - goToURL

    func testGoToURLSpokenAddressWithAppQualifier() {
        XCTAssertEqual(command(.goToURL, argument: "discord dot com", app: "Chrome"),
                       .goTo(url: "discord.com", app: "Chrome"))
    }

    func testGoToURLAlreadyURLShapedNoQualifier() {
        XCTAssertEqual(command(.goToURL, argument: "discord.com"),
                       .goTo(url: "discord.com", app: nil))
    }

    func testGoToURLUnparseableArgumentFallsToVisualLoop() {
        // No dot, no scheme — not a real address, so the caller must fall
        // back to the visual autopilot loop instead of executing garbage.
        XCTAssertNil(command(.goToURL, argument: "no address here"))
    }

    // MARK: - openApp

    func testOpenAppWithName() {
        XCTAssertEqual(command(.openApp, argument: "Notes"), .open(app: "Notes"))
    }

    func testOpenAppEmptyOrWhitespaceArgumentIsNil() {
        XCTAssertNil(command(.openApp, argument: ""))
        XCTAssertNil(command(.openApp, argument: "   "))
    }

    // MARK: - switchToApp

    func testSwitchToApp() {
        XCTAssertEqual(command(.switchToApp, argument: "chrome"), .switchTo(app: "chrome"))
    }

    // MARK: - webSearch

    func testWebSearchWithAppQualifier() {
        XCTAssertEqual(command(.webSearch, argument: "sloth videos", app: "safari"),
                       .webSearch(query: "sloth videos", app: "safari"))
    }

    func testWebSearchEmptyArgumentIsNil() {
        XCTAssertNil(command(.webSearch, argument: ""))
    }

    // MARK: - pressKey

    func testPressKeyChord() {
        XCTAssertEqual(command(.pressKey, argument: "command shift t"),
                       .press(KeyChord(key: "t", modifiers: [.command, .shift])))
    }

    func testPressKeyUnrecognizedIsNil() {
        XCTAssertNil(command(.pressKey, argument: "the blue button"))
    }

    // MARK: - quitApp

    func testQuitAppEmptyArgumentQuitsFrontmost() {
        XCTAssertEqual(command(.quitApp, argument: ""), .quit(app: nil))
    }

    func testQuitAppWithName() {
        XCTAssertEqual(command(.quitApp, argument: "Safari"), .quit(app: "Safari"))
    }

    // MARK: - needsScreen

    func testNeedsScreenAlwaysNilRegardlessOfArgument() {
        // needsScreen is the admission that the model can't help — there is
        // no argument shape that turns it into an executable command.
        XCTAssertNil(command(.needsScreen, argument: "click sign in"))
        XCTAssertNil(command(.needsScreen))
        XCTAssertNil(command(.needsScreen, argument: ""))
    }

    // MARK: - App qualifier

    func testEmptyOrWhitespaceAppQualifierBecomesNil() {
        XCTAssertEqual(command(.webSearch, argument: "sloth videos", app: ""),
                       .webSearch(query: "sloth videos", app: nil))
        XCTAssertEqual(command(.webSearch, argument: "sloth videos", app: "   "),
                       .webSearch(query: "sloth videos", app: nil))
    }

    func testGenericWebQualifierBecomesNil() {
        // Measured live: the model names "the web" as an app on plain
        // search requests. That means "the default browser", i.e. no app.
        XCTAssertEqual(command(.webSearch, argument: "wikipedia", app: "web"),
                       .webSearch(query: "wikipedia", app: nil))
        XCTAssertEqual(command(.goToURL, argument: "apple.com", app: "the web"),
                       .goTo(url: "apple.com", app: nil))
        // A real browser name survives.
        XCTAssertEqual(command(.webSearch, argument: "wikipedia", app: "Chrome"),
                       .webSearch(query: "wikipedia", app: "Chrome"))
        // Schema/placeholder bleed into the app field is noise too
        // (measured live: goToURL with app "needsScreen").
        XCTAssertEqual(command(.goToURL, argument: "wikipedia.org", app: "needsScreen"),
                       .goTo(url: "wikipedia.org", app: nil))
        XCTAssertEqual(command(.webSearch, argument: "cats", app: "unknown"),
                       .webSearch(query: "cats", app: nil))
    }

    func testIntentNameBleedingIntoArgumentIsDiscarded() {
        // Measured live: "get rid of this app" → quitApp with argument
        // "needsScreen" — schema bleed, not a target. Discarding it makes
        // quitApp mean the frontmost app, which is what was asked.
        XCTAssertEqual(command(.quitApp, argument: "needsScreen"), .quit(app: nil))
        // For intents that require an argument, bleed means unusable → loop.
        XCTAssertNil(command(.openApp, argument: "openApp"))
    }

    func testPlaceholderArgumentsMeanNoSpecificTarget() {
        // Measured live: quitApp with argument "unknown". Placeholders pin
        // quitApp to the frontmost app — the grammar's own "quit it" rule.
        XCTAssertEqual(command(.quitApp, argument: "unknown"), .quit(app: nil))
        XCTAssertEqual(command(.quitApp, argument: "this app"), .quit(app: nil))
        XCTAssertEqual(command(.quitApp, argument: "It"), .quit(app: nil))
        // Intents that need a real target become unusable instead.
        XCTAssertNil(command(.openApp, argument: "unknown"))
        XCTAssertNil(command(.switchToApp, argument: "that app"))
    }

    // MARK: - Prompt / instructions guards

    // Cheap guards against accidental edits: the model needs the literal
    // goal in its prompt, and needsScreen documented as the escape hatch.
    func testPromptContainsGoalVerbatim() {
        let goal = "open the pod bay doors"
        XCTAssertTrue(TranslationPolicy.prompt(for: goal).contains(goal))
    }

    func testInstructionsMentionNeedsScreen() {
        XCTAssertTrue(TranslationPolicy.instructions.contains("needsScreen"))
    }
}
