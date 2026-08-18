import XCTest
@testable import PawvisCore

final class CameraStallClockTests: XCTestCase {
    func testUnArmedClockNeverConvicts() {
        let clock = CameraStallClock()
        // No arm, no frames, any amount of time: a watchdog nobody armed
        // accuses nobody.
        XCTAssertFalse(clock.isStalled(at: 0))
        XCTAssertFalse(clock.isStalled(at: 60))
        XCTAssertFalse(clock.isStalled(at: 100_000))
    }

    func testFramesAloneNeverConvictBeforeTheFirstArm() {
        var clock = CameraStallClock()
        clock.noteFrame(at: 10)
        // Long silence after an un-armed frame: still no verdict.
        XCTAssertFalse(clock.isStalled(at: 500))
    }

    func testArmGivesTheWarmUpGrace() {
        var clock = CameraStallClock()
        clock.arm(at: 0, grace: 5)
        // A cold camera owes nothing during the grace, even with no frames.
        XCTAssertFalse(clock.isStalled(at: 4.9))
        // Past the grace with still no frames since the arm: stalled.
        XCTAssertTrue(clock.isStalled(at: 5.0))
    }

    func testThrottledCadenceHoldsOffTheVerdict() {
        var clock = CameraStallClock()
        clock.arm(at: 0, grace: 0)
        // The idle throttle's sparsest probe (~2 fps in Low Power Mode)
        // still means captured frames every 1/30 s — the tap stamps them
        // all, skipped or not. Model a camera delivering only 2 fps to make
        // the point at the policy's own scale: 0.5 s gaps never stall.
        var time: TimeInterval = 0
        while time < 60 {
            time += 0.5
            XCTAssertFalse(clock.isStalled(at: time), "false stall at \(time)")
            clock.noteFrame(at: time)
        }
    }

    func testSilenceAfterFramesConvicts() {
        var clock = CameraStallClock()
        clock.arm(at: 0, grace: 0)
        clock.noteFrame(at: 10)
        XCTAssertFalse(clock.isStalled(at: 11.9))
        XCTAssertTrue(clock.isStalled(at: 12.0))
    }

    func testRearmRestartsTheCountdownFromNow() {
        var clock = CameraStallClock()
        clock.arm(at: 0, grace: 0)
        clock.noteFrame(at: 10)
        // Minutes of deliberate pause (the lock screen), then a resume that
        // arms synchronously: the verdict must count from the arm, never
        // from the last frame before the pause — the unlock flap's exact
        // shape.
        clock.arm(at: 300, grace: 5)
        XCTAssertFalse(clock.isStalled(at: 300))
        XCTAssertFalse(clock.isStalled(at: 304.9))
        // The camera never delivered after the resume: an honest stall.
        XCTAssertTrue(clock.isStalled(at: 305.0))
    }

    func testArmStampsEvidenceEvenWithZeroGrace() {
        var clock = CameraStallClock()
        clock.arm(at: 0, grace: 0)
        clock.noteFrame(at: 10)
        clock.arm(at: 300, grace: 0)
        // Even with no grace, the countdown restarts at the arm: the camera
        // gets the full stall window from "now", not a verdict on the
        // pre-pause past.
        XCTAssertFalse(clock.isStalled(at: 301.9))
        XCTAssertTrue(clock.isStalled(at: 302.0))
    }

    func testFrameDuringGraceCarriesLivenessPastIt() {
        var clock = CameraStallClock()
        clock.arm(at: 0, grace: 5)
        clock.noteFrame(at: 4.9)
        // The warm-up frame arrived just inside the grace; the stall window
        // now runs from that frame, not from the grace's edge.
        XCTAssertFalse(clock.isStalled(at: 6.8))
        XCTAssertTrue(clock.isStalled(at: 7.0))
    }

    func testStallWindowIsConfigurable() {
        var clock = CameraStallClock(stallSeconds: 10)
        clock.arm(at: 0, grace: 0)
        clock.noteFrame(at: 1)
        XCTAssertFalse(clock.isStalled(at: 10.9))
        XCTAssertTrue(clock.isStalled(at: 11.0))
    }
}
