import XCTest
@testable import PawvisCore

final class IdleThrottleTests: XCTestCase {
    /// 30 fps worth of captured frames, returning how many processed.
    private func runSecond(_ throttle: inout IdleThrottle, from start: TimeInterval,
                           handsSeen: Bool, lowPower: Bool = false) -> Int {
        var processed = 0
        for frame in 0..<30 {
            let time = start + Double(frame) / 30
            if throttle.shouldRunInference(at: time, exempt: false, lowPower: lowPower) {
                processed += 1
                throttle.sawHands(handsSeen, at: time)
            }
        }
        return processed
    }

    func testFullRateWhileHandsInView() {
        var throttle = IdleThrottle()
        var time: TimeInterval = 0
        for _ in 0..<60 {
            XCTAssertEqual(runSecond(&throttle, from: time, handsSeen: true), 30)
            XCTAssertFalse(throttle.throttled)
            time += 1
        }
    }

    func testFullRateUntilTheNoHandsDelayPasses() {
        var throttle = IdleThrottle()
        // 9 seconds of empty frames: under the 10 s default, still full rate.
        for second in 0..<9 {
            XCTAssertEqual(runSecond(&throttle, from: Double(second), handsSeen: false), 30)
        }
        XCTAssertFalse(throttle.throttled)
    }

    func testThrottlesToTheStrideAfterTheDelay() {
        var throttle = IdleThrottle()
        for second in 0..<10 {
            _ = runSecond(&throttle, from: Double(second), handsSeen: false)
        }
        // Past the delay: one frame in six processes (~5 fps of the 30).
        let processed = runSecond(&throttle, from: 10, handsSeen: false)
        XCTAssertEqual(processed, 5)
        XCTAssertTrue(throttle.throttled)
    }

    func testFirstHandExitsTheThrottleImmediately() {
        var throttle = IdleThrottle()
        for second in 0..<12 {
            _ = runSecond(&throttle, from: Double(second), handsSeen: false)
        }
        XCTAssertTrue(throttle.throttled)
        // Walk frames until one processes; that frame sees a hand.
        var time: TimeInterval = 12
        var sawHandAt: TimeInterval?
        for frame in 0..<30 where sawHandAt == nil {
            let t = time + Double(frame) / 30
            if throttle.shouldRunInference(at: t, exempt: false, lowPower: false) {
                throttle.sawHands(true, at: t)
                sawHandAt = t
            }
        }
        XCTAssertNotNil(sawHandAt)
        XCTAssertFalse(throttle.throttled)
        // Every frame after the hand processes again, no ramp, no residue.
        time = sawHandAt! + 1.0 / 30
        XCTAssertEqual(runSecond(&throttle, from: time, handsSeen: true), 30)
    }

    func testExemptFramesNeverThrottle() {
        var throttle = IdleThrottle()
        // Way past the delay with no hands: throttled…
        for second in 0..<20 {
            _ = runSecond(&throttle, from: Double(second), handsSeen: false)
        }
        XCTAssertTrue(throttle.throttled)
        // …but an exempt frame (button held, scroll active, trainer open)
        // always processes, however stale the no-hands clock is.
        for frame in 0..<30 {
            let t = 20 + Double(frame) / 30
            XCTAssertTrue(throttle.shouldRunInference(at: t, exempt: true, lowPower: false))
        }
        XCTAssertFalse(throttle.throttled)
    }

    func testLowPowerShortensTheDelay() {
        var throttle = IdleThrottle()
        // 4 s of no hands: past the 3 s low-power delay, under the normal 10 s.
        for second in 0..<4 {
            _ = runSecond(&throttle, from: Double(second), handsSeen: false, lowPower: true)
        }
        XCTAssertTrue(throttle.throttled)

        var normal = IdleThrottle()
        for second in 0..<4 {
            _ = runSecond(&normal, from: Double(second), handsSeen: false, lowPower: false)
        }
        XCTAssertFalse(normal.throttled)
    }

    func testLowPowerSparsensTheStride() {
        var throttle = IdleThrottle()
        for second in 0..<10 {
            _ = runSecond(&throttle, from: Double(second), handsSeen: false, lowPower: true)
        }
        // One frame in fifteen (~2 fps of the 30).
        XCTAssertEqual(runSecond(&throttle, from: 10, handsSeen: false, lowPower: true), 2)
    }

    func testResetRestoresFullRate() {
        var throttle = IdleThrottle()
        for second in 0..<15 {
            _ = runSecond(&throttle, from: Double(second), handsSeen: false)
        }
        XCTAssertTrue(throttle.throttled)
        throttle.reset()
        XCTAssertFalse(throttle.throttled)
        XCTAssertEqual(runSecond(&throttle, from: 15, handsSeen: false), 30)
    }

    func testThrottleReengagesAfterHandsLeaveAgain() {
        var throttle = IdleThrottle()
        for second in 0..<12 {
            _ = runSecond(&throttle, from: Double(second), handsSeen: false)
        }
        XCTAssertTrue(throttle.throttled)
        // A hand visits: the first processed probe frame clears the throttle.
        var time: TimeInterval = 12.5
        while !throttle.shouldRunInference(at: time, exempt: false, lowPower: false) {
            time += 1.0 / 30
        }
        throttle.sawHands(true, at: time)
        XCTAssertFalse(throttle.throttled)
        XCTAssertEqual(runSecond(&throttle, from: time + 1.0 / 30, handsSeen: true), 30)
        // The hand leaves again: the no-hands clock starts over, so the next
        // ten seconds run at full rate before the throttle re-engages.
        let handLeft = time + 1.0 + 1.0 / 30
        for second in 0..<10 {
            XCTAssertEqual(
                runSecond(&throttle, from: handLeft + Double(second), handsSeen: false), 30)
        }
        _ = runSecond(&throttle, from: handLeft + 10, handsSeen: false)
        XCTAssertTrue(throttle.throttled)
    }
}
