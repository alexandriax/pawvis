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
}
