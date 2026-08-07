import XCTest
@testable import PawvisCore

final class StatusPillPolicyTests: XCTestCase {
    func testMessageAutoDismissesAfterTimeout() {
        var policy = StatusPillPolicy(autoDismissAfter: 5)
        let hint = "🎤 Say “pawvis …”"
        XCTAssertEqual(policy.display(hint, now: 0), hint)
        XCTAssertEqual(policy.display(hint, now: 4.9), hint)
        XCTAssertNil(policy.display(hint, now: 5.0))
        // And stays gone: the caller keeps handing us the same text every frame.
        XCTAssertNil(policy.display(hint, now: 5.1))
        XCTAssertNil(policy.display(hint, now: 60))
    }

    func testDismissHidesImmediatelyAndSticks() {
        var policy = StatusPillPolicy(autoDismissAfter: 5)
        XCTAssertEqual(policy.display("warning", now: 0), "warning")
        policy.dismiss()
        // The next frame is ~16 ms later — without retirement the click undoes itself.
        XCTAssertNil(policy.display("warning", now: 0.016))
        XCTAssertNil(policy.display("warning", now: 4))
    }

    func testDifferentTextRestartsTheCountdown() {
        var policy = StatusPillPolicy(autoDismissAfter: 5)
        XCTAssertEqual(policy.display("first", now: 0), "first")
        XCTAssertNil(policy.display("first", now: 6))
        XCTAssertEqual(policy.display("second", now: 6), "second")
        XCTAssertEqual(policy.display("second", now: 10.9), "second")
        XCTAssertNil(policy.display("second", now: 11))
    }

    func testDismissedTextReturnsOnlyAfterSomethingElse() {
        var policy = StatusPillPolicy(autoDismissAfter: 5)
        XCTAssertEqual(policy.display("hint", now: 0), "hint")
        policy.dismiss()
        XCTAssertNil(policy.display("hint", now: 1))
        XCTAssertEqual(policy.display("notice", now: 2), "notice")
        XCTAssertEqual(policy.display("hint", now: 3), "hint")
    }

    func testLiveTextKeepsTheCapsuleAlive() {
        // A typing snippet changes on every utterance delta: each change is a
        // new message, so the capsule never times out mid-sentence.
        var policy = StatusPillPolicy(autoDismissAfter: 5)
        var now = 0.0
        for snippet in ["h", "he", "hel", "hell", "hello"] {
            XCTAssertEqual(policy.display(snippet, now: now), snippet)
            now += 3
        }
        XCTAssertEqual(policy.display("hello", now: now + 1), "hello")
        XCTAssertNil(policy.display("hello", now: now + 5))
    }

    func testNilClearsSoTheNextMessageShowsFresh() {
        var policy = StatusPillPolicy(autoDismissAfter: 5)
        XCTAssertEqual(policy.display("hint", now: 0), "hint")
        policy.dismiss()
        XCTAssertNil(policy.display(nil, now: 1))
        // Voice control restarted: the same hint is new again.
        XCTAssertEqual(policy.display("hint", now: 2), "hint")
        XCTAssertEqual(policy.display("hint", now: 6.9), "hint")
        XCTAssertNil(policy.display("hint", now: 7))
    }

    func testEmptyTextIsNothingToShow() {
        var policy = StatusPillPolicy(autoDismissAfter: 5)
        XCTAssertNil(policy.display("", now: 0))
    }

    func testZeroTimeoutKeepsTheMessageUp() {
        var policy = StatusPillPolicy(autoDismissAfter: 0)
        XCTAssertEqual(policy.display("pinned", now: 0), "pinned")
        XCTAssertEqual(policy.display("pinned", now: 10_000), "pinned")
        policy.dismiss()
        XCTAssertNil(policy.display("pinned", now: 10_001))
    }
}
