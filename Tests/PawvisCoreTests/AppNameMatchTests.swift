import XCTest
@testable import PawvisCore

/// Pure spoken-name ↔ app-name scoring, shared by the app layer's fuzzy
/// catalog resolver and the autopilot's frontmost-app completion check.
final class AppNameMatchTests: XCTestCase {
    // MARK: - matchScore

    func testExactFoldedMatchScoresHighest() {
        XCTAssertEqual(
            AppNameMatch.matchScore(query: "google chrome", name: "Google Chrome"), 1000)
    }

    func testPrefixMatchScoresAboveZero() {
        XCTAssertGreaterThan(AppNameMatch.matchScore(query: "chrome", name: "Google Chrome"), 0)
    }

    func testTighterNameScoresHigherThanLongerNameContainingTheSameWord() {
        // "chrome" should prefer the app actually named Chrome over an
        // unrelated utility whose name merely contains the word "chrome".
        let tight = AppNameMatch.matchScore(query: "chrome", name: "Google Chrome")
        let loose = AppNameMatch.matchScore(
            query: "chrome", name: "Chrome Remote Desktop Host Uninstaller")
        XCTAssertGreaterThan(tight, loose)
    }

    func testInitialismMatch() {
        XCTAssertEqual(AppNameMatch.matchScore(query: "gc", name: "Google Chrome"), 300)
    }

    func testUnrelatedNameScoresZero() {
        XCTAssertEqual(AppNameMatch.matchScore(query: "slack", name: "Google Chrome"), 0)
    }

    func testEmptyQueryScoresZero() {
        XCTAssertEqual(AppNameMatch.matchScore(query: "", name: "Google Chrome"), 0)
    }

    // MARK: - Phonetic tier

    func testPhoneticMishearingsResolveClaude() {
        // The recognizer garbles names it doesn't know; the consonant
        // skeleton catches the common ones with no model round.
        for heard in ["clod", "clawed", "cloud", "clawd"] {
            XCTAssertGreaterThan(
                AppNameMatch.bestScore(spoken: heard, name: "Claude"), 0,
                "'\(heard)' should phonetically match Claude")
        }
    }

    func testPhoneticTierScoresBelowRealMatches() {
        XCTAssertLessThan(
            AppNameMatch.bestScore(spoken: "clod", name: "Claude"),
            AppNameMatch.matchScore(query: "claude", name: "Claude"))
    }

    func testPhoneticTierRejectsUnrelatedNames() {
        XCTAssertEqual(AppNameMatch.bestScore(spoken: "slack", name: "Claude"), 0)
        XCTAssertEqual(AppNameMatch.bestScore(spoken: "notion", name: "Claude"), 0)
    }

    func testShortTokensDoNotPhoneticallyMatch() {
        // One-consonant skeletons ("up" → "p") would collide with half the
        // catalog; they must stay out of the phonetic tier.
        XCTAssertEqual(AppNameMatch.bestScore(spoken: "up", name: "App Store"), 0)
    }

    // MARK: - Spoken-padding variants

    func testTrailingFillerWordsStripped() {
        XCTAssertGreaterThan(
            AppNameMatch.bestScore(spoken: "claude desktop app", name: "Claude"), 0)
        // Garbled AND padded — the user's actual failure case.
        XCTAssertGreaterThan(
            AppNameMatch.bestScore(spoken: "clod desktop app", name: "Claude"), 0)
    }

    func testLeadingArticleStripped() {
        XCTAssertGreaterThan(
            AppNameMatch.bestScore(spoken: "the claude app", name: "Claude"), 0)
    }

    func testFullerMatchOutranksStrippedVariant() {
        // "docker desktop app" names Docker Desktop; the variant stripped
        // down to "docker" must not outrank it for a hypothetical "Docker".
        XCTAssertGreaterThan(
            AppNameMatch.bestScore(spoken: "docker desktop app", name: "Docker Desktop"),
            AppNameMatch.bestScore(spoken: "docker desktop app", name: "Docker"))
    }

    func testDesktopOnlyStrippedAsPadding() {
        // "github desktop" IS the app name — direct match, no stripping.
        XCTAssertEqual(
            AppNameMatch.bestScore(spoken: "github desktop", name: "GitHub Desktop"), 1000)
    }

    // MARK: - matches

    func testMatchesTrueForPlausibleSpokenName() {
        XCTAssertTrue(AppNameMatch.matches(spoken: "chrome", appName: "Google Chrome"))
    }

    func testMatchesFalseWhenSpokenIsAWholeUnrelatedPhrase() {
        // A full navigation phrase must not fuzzy-match a one-word app name
        // just because "chrome" happens to appear in it.
        XCTAssertFalse(
            AppNameMatch.matches(spoken: "discord dot com in chrome", appName: "Discord"))
    }

    // MARK: - Generic web qualifiers

    func testResolvedAppQualifierNilsEveryGenericPhrase() {
        // The regression: "open discord dot com in the browser" must not
        // resolve "the browser" against an installed app (it used to
        // prefix-match Brave/Tor Browser once the leading article was
        // stripped). Every phrase the grammar or the model can produce for
        // "no app in particular" must come back nil.
        for spoken in AppNameMatch.genericWebQualifiers {
            XCTAssertNil(AppNameMatch.resolvedAppQualifier(spoken),
                         "'\(spoken)' should mean no app in particular")
        }
    }

    func testResolvedAppQualifierNilsGenericPhrasesRegardlessOfCase() {
        for spoken in ["The Browser", "My Browser", "Browser", "The Internet"] {
            XCTAssertNil(AppNameMatch.resolvedAppQualifier(spoken),
                         "'\(spoken)' should mean no app in particular")
        }
    }

    func testResolvedAppQualifierKeepsRealAppNames() {
        XCTAssertEqual(AppNameMatch.resolvedAppQualifier("chrome"), "chrome")
        XCTAssertEqual(AppNameMatch.resolvedAppQualifier("safari"), "safari")
        XCTAssertEqual(AppNameMatch.resolvedAppQualifier("Firefox"), "Firefox")
    }

    func testResolvedAppQualifierNilForNilOrBlank() {
        XCTAssertNil(AppNameMatch.resolvedAppQualifier(nil))
        XCTAssertNil(AppNameMatch.resolvedAppQualifier(""))
        XCTAssertNil(AppNameMatch.resolvedAppQualifier("   "))
    }

    func testResolvedAppQualifierTrimsWhitespace() {
        XCTAssertEqual(AppNameMatch.resolvedAppQualifier("  chrome  "), "chrome")
    }
}
