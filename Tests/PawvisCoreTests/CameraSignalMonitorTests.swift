import XCTest
@testable import PawvisCore

final class CameraSignalMonitorTests: XCTestCase {
    private func monitor() -> CameraSignalMonitor {
        CameraSignalMonitor(config: .init(darkLuma: 8, darkDelay: 2.0))
    }

    /// A feed black from the first frame trips after the delay, timed from
    /// the first sample — the iPhone-face-down case. The first dark frame
    /// only starts the clock; it does not trip on its own.
    func testAFeedDarkFromTheStartTripsAfterTheDelay() {
        var m = monitor()
        XCTAssertFalse(m.sample(luma: 2, at: 0.0)) // clock starts, not yet dark
        XCTAssertFalse(m.sample(luma: 2, at: 1.9))
        XCTAssertTrue(m.sample(luma: 2, at: 2.0))
        XCTAssertTrue(m.isDark)
    }

    /// A bright scene never trips, however long it runs.
    func testABrightFeedNeverTrips() {
        var m = monitor()
        for i in 0...100 {
            XCTAssertFalse(m.sample(luma: 105, at: Double(i) * 0.1))
        }
    }

    /// A blackout shorter than the delay (a hand over the lens, uncovered in
    /// time) is not a dark feed: the clock runs from the last bright frame.
    func testABriefBlackoutDoesNotTrip() {
        var m = monitor()
        XCTAssertFalse(m.sample(luma: 105, at: 0.0)) // bright: resets the clock
        XCTAssertFalse(m.sample(luma: 2, at: 0.5))
        XCTAssertFalse(m.sample(luma: 2, at: 1.0))
        XCTAssertFalse(m.sample(luma: 105, at: 1.5)) // uncovered 1.5s after bright
        XCTAssertFalse(m.isDark)
    }

    /// The delay is measured from the last bright frame, not from the start.
    func testDarkRunIsTimedFromTheLastBrightFrame() {
        var m = monitor()
        XCTAssertFalse(m.sample(luma: 105, at: 10.0))
        XCTAssertFalse(m.sample(luma: 2, at: 11.0))
        XCTAssertFalse(m.sample(luma: 2, at: 11.9)) // only 1.9s since bright
        XCTAssertTrue(m.sample(luma: 2, at: 12.0))  // now 2.0s since bright
    }

    /// The first real image clears the warning with no lag.
    func testRecoveryIsInstantaneous() {
        var m = monitor()
        XCTAssertFalse(m.sample(luma: 2, at: 0.0))
        XCTAssertTrue(m.sample(luma: 2, at: 2.0)) // dark now
        XCTAssertFalse(m.sample(luma: 90, at: 2.1))
        XCTAssertFalse(m.isDark)
    }

    /// An unmeasurable frame holds whatever the verdict already was.
    func testUnreadableFrameHoldsTheVerdict() {
        var m = monitor()
        XCTAssertFalse(m.sample(luma: 2, at: 0.0))
        XCTAssertTrue(m.sample(luma: 2, at: 2.0))    // dark
        XCTAssertTrue(m.sample(luma: -1, at: 2.1))   // unreadable: still dark
        XCTAssertFalse(m.sample(luma: 100, at: 2.2)) // recovered
        XCTAssertFalse(m.sample(luma: -1, at: 2.3))  // unreadable: still fine
    }

    /// Reset re-arms: the next dark run times from scratch.
    func testResetForgetsHistory() {
        var m = monitor()
        XCTAssertFalse(m.sample(luma: 2, at: 0.0))
        XCTAssertTrue(m.sample(luma: 2, at: 2.0)) // dark
        m.reset()
        XCTAssertFalse(m.isDark)
        XCTAssertFalse(m.sample(luma: 2, at: 10.0)) // clock restarts here
        XCTAssertTrue(m.sample(luma: 2, at: 12.0))
    }

    /// The threshold is a boundary: exactly darkLuma counts as bright.
    func testThresholdBoundary() {
        var m = monitor()
        XCTAssertFalse(m.sample(luma: 8, at: 0.0))    // == darkLuma: bright
        XCTAssertFalse(m.sample(luma: 8, at: 5.0))
        XCTAssertFalse(m.sample(luma: 7.99, at: 6.0)) // just below: clock starts
        XCTAssertTrue(m.sample(luma: 7.99, at: 8.0))
    }
}
