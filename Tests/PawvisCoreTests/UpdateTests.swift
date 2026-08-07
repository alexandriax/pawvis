import XCTest
@testable import PawvisCore

final class SemanticVersionTests: XCTestCase {
    func testParsesCommonForms() {
        XCTAssertEqual(SemanticVersion("1.2.3"), SemanticVersion(major: 1, minor: 2, patch: 3))
        XCTAssertEqual(SemanticVersion("v1.2.3"), SemanticVersion(major: 1, minor: 2, patch: 3))
        XCTAssertEqual(SemanticVersion("1.2"), SemanticVersion(major: 1, minor: 2, patch: 0))
        XCTAssertEqual(SemanticVersion("2"), SemanticVersion(major: 2, minor: 0, patch: 0))
        XCTAssertEqual(SemanticVersion(" 1.0.1 "), SemanticVersion(major: 1, minor: 0, patch: 1))
    }

    func testParsesPrereleaseAndDropsBuildMetadata() {
        let beta = SemanticVersion("1.2.0-beta.2")
        XCTAssertEqual(beta?.prerelease, ["beta", "2"])
        XCTAssertTrue(beta!.isPrerelease)
        // Build metadata is ignored for ordering, so it must not survive parsing.
        XCTAssertEqual(SemanticVersion("1.2.0+abc123"), SemanticVersion(major: 1, minor: 2, patch: 0))
    }

    func testRejectsGarbage() {
        XCTAssertNil(SemanticVersion(""))
        XCTAssertNil(SemanticVersion("banana"))
        XCTAssertNil(SemanticVersion("1.2.3.4"))
        XCTAssertNil(SemanticVersion("1.-2.3"))
    }

    func testOrdering() {
        func lt(_ a: String, _ b: String) -> Bool { SemanticVersion(a)! < SemanticVersion(b)! }
        XCTAssertTrue(lt("1.0.0", "1.0.1"))
        XCTAssertTrue(lt("1.0.9", "1.1.0"))
        XCTAssertTrue(lt("1.9.0", "2.0.0"))
        XCTAssertTrue(lt("1.0.0", "10.0.0"), "components compare numerically, not as strings")
        XCTAssertFalse(lt("1.0.1", "1.0.1"))
    }

    func testPrereleaseSortsBeforeItsRelease() {
        func lt(_ a: String, _ b: String) -> Bool { SemanticVersion(a)! < SemanticVersion(b)! }
        XCTAssertTrue(lt("1.2.0-beta.1", "1.2.0"))
        XCTAssertTrue(lt("1.2.0-beta.1", "1.2.0-beta.2"))
        XCTAssertTrue(lt("1.2.0-alpha", "1.2.0-beta"))
        XCTAssertTrue(lt("1.2.0-beta.2", "1.2.0-beta.10"), "numeric identifiers compare numerically")
        XCTAssertTrue(lt("1.2.0-1", "1.2.0-alpha"), "numeric identifiers rank below alphanumeric")
        XCTAssertTrue(lt("1.2.0-beta", "1.2.0-beta.1"), "a longer identifier list is greater")
    }

    func testDescriptionRoundTrips() {
        for text in ["1.2.3", "0.1.0", "2.0.0-beta.4"] {
            XCTAssertEqual(SemanticVersion(text)!.description, text)
        }
    }
}

final class UpdatePolicyTests: XCTestCase {
    private let now = Date(timeIntervalSince1970: 1_800_000_000)

    func testNeverCheckedIsDue() {
        XCTAssertTrue(UpdatePolicy.shouldAutoCheck(lastChecked: nil, now: now))
    }

    func testWaitsAFullDayBetweenChecks() {
        let hourAgo = now.addingTimeInterval(-3600)
        XCTAssertFalse(UpdatePolicy.shouldAutoCheck(lastChecked: hourAgo, now: now))

        let dayAgo = now.addingTimeInterval(-UpdatePolicy.checkInterval)
        XCTAssertTrue(UpdatePolicy.shouldAutoCheck(lastChecked: dayAgo, now: now))

        let twoDaysAgo = now.addingTimeInterval(-2 * UpdatePolicy.checkInterval)
        XCTAssertTrue(UpdatePolicy.shouldAutoCheck(lastChecked: twoDaysAgo, now: now))
    }

    func testFutureTimestampIsTreatedAsDue() {
        // A clock change can leave a "last checked" in the future; waiting it
        // out could suppress checks for arbitrarily long.
        let tomorrow = now.addingTimeInterval(UpdatePolicy.checkInterval)
        XCTAssertTrue(UpdatePolicy.shouldAutoCheck(lastChecked: tomorrow, now: now))
    }

    func testOffersOnlyNewerVersions() {
        let current = SemanticVersion("1.2.0")!
        XCTAssertTrue(UpdatePolicy.shouldOffer(candidate: SemanticVersion("1.2.1")!, current: current))
        XCTAssertFalse(UpdatePolicy.shouldOffer(candidate: SemanticVersion("1.2.0")!, current: current))
        XCTAssertFalse(UpdatePolicy.shouldOffer(candidate: SemanticVersion("1.1.9")!, current: current))
    }

    func testStableInstallsAreNotOfferedPrereleases() {
        let stable = SemanticVersion("1.2.0")!
        XCTAssertFalse(UpdatePolicy.shouldOffer(candidate: SemanticVersion("1.3.0-beta.1")!, current: stable))

        // …but someone already on a beta keeps getting betas.
        let beta = SemanticVersion("1.3.0-beta.1")!
        XCTAssertTrue(UpdatePolicy.shouldOffer(candidate: SemanticVersion("1.3.0-beta.2")!, current: beta))
        XCTAssertTrue(UpdatePolicy.shouldOffer(candidate: SemanticVersion("1.3.0")!, current: beta))
    }

    func testSkippedVersionStaysHiddenUntilSomethingNewer() {
        let current = SemanticVersion("1.0.0")!
        let skipped = SemanticVersion("1.1.0")!
        XCTAssertFalse(UpdatePolicy.shouldOffer(
            candidate: SemanticVersion("1.1.0")!, current: current, skipped: skipped))
        XCTAssertTrue(UpdatePolicy.shouldOffer(
            candidate: SemanticVersion("1.2.0")!, current: current, skipped: skipped))
    }

    func testFirstSightingOfAVersionNotifies() {
        XCTAssertTrue(UpdatePolicy.shouldNotify(
            candidate: SemanticVersion("1.1.0")!, lastNotified: nil))
    }

    func testTheSameVersionOnlyNotifiesOnce() {
        // Every launch re-checks and re-offers the same release; only the first
        // one is allowed to interrupt the user.
        let offered = SemanticVersion("1.1.0")!
        XCTAssertFalse(UpdatePolicy.shouldNotify(candidate: offered, lastNotified: offered))
    }

    func testANewerVersionNotifiesAgain() {
        XCTAssertTrue(UpdatePolicy.shouldNotify(
            candidate: SemanticVersion("1.2.0")!, lastNotified: SemanticVersion("1.1.0")!))
    }

    func testARepublishedLowerVersionStillNotifies() {
        // A release yanked and re-cut lower is news too, and `>` would bury it.
        XCTAssertTrue(UpdatePolicy.shouldNotify(
            candidate: SemanticVersion("1.1.0")!, lastNotified: SemanticVersion("1.2.0")!))
    }

    func testPrereleaseAndReleaseAreDistinctAnnouncements() {
        XCTAssertTrue(UpdatePolicy.shouldNotify(
            candidate: SemanticVersion("1.2.0")!, lastNotified: SemanticVersion("1.2.0-beta.1")!))
    }
}
