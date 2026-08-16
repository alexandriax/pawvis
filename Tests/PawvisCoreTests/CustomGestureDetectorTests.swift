import XCTest
@testable import PawvisCore

final class CustomGestureDetectorTests: XCTestCase {
    var detector: CustomGestureDetector!

    override func setUp() {
        super.setUp()
        detector = CustomGestureDetector()
    }

    private func enable(_ gestures: CustomGesture...) {
        var config = CustomGestureDetector.Config()
        config.enabled = Set(gestures)
        detector.config = config
    }

    private func context(at time: TimeInterval,
                         press: Bool = false,
                         crissCross: Bool = false) -> CustomGestureDetector.Context {
        CustomGestureDetector.Context(
            time: time,
            thresholds: PoseThresholds(),
            minJointConfidence: 0.25,
            trackingLossGrace: 0.30,
            pressOrScrollActive: press,
            crissCrossEngaged: crissCross)
    }

    @discardableResult
    private func feed(_ hands: [(Int, Hand)], at time: TimeInterval,
                      press: Bool = false, crissCross: Bool = false) -> [CustomGesture] {
        detector.process(
            hands: hands.map { CustomGestureDetector.HandInput(slot: $0.0, hand: $0.1) },
            context: context(at: time, press: press, crissCross: crissCross))
    }

    /// Frames at 30 fps: three still open frames (builds the strict-open
    /// streak), then `steps` frames translating by `delta` each.
    @discardableResult
    private func sweep(slot: Int = 0, from wrist: Vec2, delta: Vec2, steps: Int,
                       startAt t0: TimeInterval = 0,
                       press: Bool = false, crissCross: Bool = false) -> [CustomGesture] {
        var fired: [CustomGesture] = []
        var t = t0
        for _ in 0..<3 {
            fired += feed([(slot, SyntheticHand.openRelaxed(wrist: wrist))], at: t,
                          press: press, crissCross: crissCross)
            t += 1.0 / 30
        }
        var w = wrist
        for _ in 0..<steps {
            w = w + delta
            fired += feed([(slot, SyntheticHand.openRelaxed(wrist: w))], at: t,
                          press: press, crissCross: crissCross)
            t += 1.0 / 30
        }
        return fired
    }

    // MARK: - Swipes

    func testSwipeRightFires() {
        enable(.swipeRight)
        let fired = sweep(from: Vec2(0.2, 0.6), delta: Vec2(0.05, 0), steps: 9)
        XCTAssertEqual(fired, [.swipeRight])
    }

    func testSwipeLeftFires() {
        enable(.swipeLeft)
        let fired = sweep(from: Vec2(0.8, 0.6), delta: Vec2(-0.05, 0), steps: 9)
        XCTAssertEqual(fired, [.swipeLeft])
    }

    func testSwipeUpAndDownFire() {
        enable(.swipeUp)
        XCTAssertEqual(sweep(from: Vec2(0.5, 0.85), delta: Vec2(0, -0.05), steps: 9),
                       [.swipeUp])
        detector.reset()
        enable(.swipeDown)
        XCTAssertEqual(sweep(from: Vec2(0.5, 0.15), delta: Vec2(0, 0.05), steps: 9),
                       [.swipeDown])
    }

    func testSlowMovementDoesNotSwipe() {
        enable(.swipeRight)
        // 0.02/frame = 0.6/s, under the 1.1/s floor, even over a long travel.
        let fired = sweep(from: Vec2(0.2, 0.6), delta: Vec2(0.02, 0), steps: 25)
        XCTAssertEqual(fired, [])
    }

    func testClosedHandDoesNotSwipe() {
        enable(.swipeRight)
        var fired: [CustomGesture] = []
        var w = Vec2(0.2, 0.6)
        for i in 0..<12 {
            fired += feed([(0, SyntheticHand.fist(wrist: w))], at: Double(i) / 30)
            w = w + Vec2(0.05, 0)
        }
        XCTAssertEqual(fired, [])
    }

    func testDiagonalSweepIsRejected() {
        enable(.swipeRight, .swipeUp)
        let fired = sweep(from: Vec2(0.2, 0.8), delta: Vec2(0.04, -0.04), steps: 10)
        XCTAssertEqual(fired, [])
    }

    func testUnboundDirectionDoesNotFire() {
        enable(.swipeLeft)
        let fired = sweep(from: Vec2(0.2, 0.6), delta: Vec2(0.05, 0), steps: 9)
        XCTAssertEqual(fired, [])
    }

    func testOneLongSweepFiresOnce() {
        enable(.swipeRight)
        // Twice the travel of a full swipe, continuous: the must-slow re-arm
        // keeps it to one fire.
        let fired = sweep(from: Vec2(0.05, 0.6), delta: Vec2(0.05, 0), steps: 17)
        XCTAssertEqual(fired, [.swipeRight])
    }

    func testTwoHandSwipeFiresInsteadOfOneHand() {
        enable(.swipeRight, .twoHandSwipeRight)
        var fired: [CustomGesture] = []
        var t = 0.0
        var left = Vec2(0.15, 0.6)
        var right = Vec2(0.45, 0.6)
        for _ in 0..<3 {
            fired += feed([(0, SyntheticHand.openRelaxed(wrist: left)),
                           (1, SyntheticHand.openRelaxed(wrist: right))], at: t)
            t += 1.0 / 30
        }
        for _ in 0..<10 {
            left = left + Vec2(0.05, 0)
            right = right + Vec2(0.05, 0)
            fired += feed([(0, SyntheticHand.openRelaxed(wrist: left)),
                           (1, SyntheticHand.openRelaxed(wrist: right))], at: t)
            t += 1.0 / 30
        }
        XCTAssertEqual(fired, [.twoHandSwipeRight])
    }

    func testLoneHandStillFiresOneHandAfterPairWindow() {
        enable(.swipeRight, .twoHandSwipeRight)
        var fired = sweep(from: Vec2(0.2, 0.6), delta: Vec2(0.05, 0), steps: 9)
        // The candidate waits out the pair window, then decides it was
        // one-handed; later empty frames deliver the resolution.
        var t = 0.5
        for _ in 0..<8 {
            fired += feed([], at: t)
            t += 1.0 / 30
        }
        XCTAssertEqual(fired, [.swipeRight])
    }

    func testPressBlocksSwipe() {
        enable(.swipeRight)
        let fired = sweep(from: Vec2(0.2, 0.6), delta: Vec2(0.05, 0), steps: 9, press: true)
        XCTAssertEqual(fired, [])
    }

    func testCrissCrossBlocksSwipe() {
        enable(.swipeRight)
        let fired = sweep(from: Vec2(0.2, 0.6), delta: Vec2(0.05, 0), steps: 9, crissCross: true)
        XCTAssertEqual(fired, [])
    }

    // MARK: - Wiggle

    @discardableResult
    private func wiggle(slot: Int = 0, wrist: Vec2 = Vec2(0.5, 0.7), frames: Int,
                        moving delta: Vec2 = .zero, startAt t0: TimeInterval = 0,
                        crissCross: Bool = false) -> [CustomGesture] {
        var fired: [CustomGesture] = []
        var w = wrist
        for i in 0..<frames {
            fired += feed([(slot, SyntheticHand.wigglePhase(contracted: i % 2 == 1, wrist: w))],
                          at: t0 + Double(i) / 30, crissCross: crissCross)
            w = w + delta
        }
        return fired
    }

    func testFingerWiggleFires() {
        enable(.fingerWiggle)
        XCTAssertEqual(wiggle(frames: 12), [.fingerWiggle])
    }

    func testWiggleFiresOnceThenRefractory() {
        enable(.fingerWiggle)
        XCTAssertEqual(wiggle(frames: 30), [.fingerWiggle])
    }

    func testStillHandDoesNotWiggle() {
        enable(.fingerWiggle)
        var fired: [CustomGesture] = []
        for i in 0..<30 {
            fired += feed([(0, SyntheticHand.openSplayed())], at: Double(i) / 30)
        }
        XCTAssertEqual(fired, [])
    }

    func testTravellingHandDoesNotWiggle() {
        enable(.fingerWiggle)
        // Same oscillation, but the palm crosses a third of the screen.
        XCTAssertEqual(wiggle(frames: 14, moving: Vec2(0.03, 0)), [])
    }

    func testTwoHandWiggleFires() {
        enable(.fingerWiggle, .twoHandFingerWiggle)
        var fired: [CustomGesture] = []
        for i in 0..<14 {
            let contracted = i % 2 == 1
            fired += feed(
                [(0, SyntheticHand.wigglePhase(contracted: contracted, wrist: Vec2(0.3, 0.7))),
                 (1, SyntheticHand.wigglePhase(contracted: contracted, wrist: Vec2(0.7, 0.7)))],
                at: Double(i) / 30)
        }
        XCTAssertEqual(fired, [.twoHandFingerWiggle])
    }

    func testWiggleRunsDuringCrissCrossEngage() {
        // Two splayed hands held still engage the wave; wiggling fingers are
        // not a wave, so the in-place family keeps running.
        enable(.fingerWiggle)
        XCTAssertEqual(wiggle(frames: 12, crissCross: true), [.fingerWiggle])
    }

    // MARK: - Held poses

    func testThumbsUpHoldFiresOnce() {
        enable(.thumbsUp)
        var fired: [CustomGesture] = []
        for i in 0..<20 {
            fired += feed([(0, SyntheticHand.thumbSignal(up: true))], at: Double(i) / 30)
        }
        XCTAssertEqual(fired, [.thumbsUp])
    }

    func testThumbsDownHoldFires() {
        enable(.thumbsDown)
        var fired: [CustomGesture] = []
        for i in 0..<20 {
            fired += feed([(0, SyntheticHand.thumbSignal(up: false))], at: Double(i) / 30)
        }
        XCTAssertEqual(fired, [.thumbsDown])
    }

    func testBriefThumbsUpDoesNotFire() {
        enable(.thumbsUp)
        var fired: [CustomGesture] = []
        for i in 0..<6 { // 0.2 s, under the 0.35 s dwell
            fired += feed([(0, SyntheticHand.thumbSignal(up: true))], at: Double(i) / 30)
        }
        for i in 6..<20 {
            fired += feed([(0, SyntheticHand.openRelaxed())], at: Double(i) / 30)
        }
        XCTAssertEqual(fired, [])
    }

    func testThumbsUpRearmsAfterRelease() {
        enable(.thumbsUp)
        var fired: [CustomGesture] = []
        var t = 0.0
        for _ in 0..<15 {
            fired += feed([(0, SyntheticHand.thumbSignal(up: true))], at: t)
            t += 1.0 / 30
        }
        // Open up well past the hold refractory, then pose again.
        for _ in 0..<30 {
            fired += feed([(0, SyntheticHand.openRelaxed())], at: t)
            t += 1.0 / 30
        }
        for _ in 0..<15 {
            fired += feed([(0, SyntheticHand.thumbSignal(up: true))], at: t)
            t += 1.0 / 30
        }
        XCTAssertEqual(fired, [.thumbsUp, .thumbsUp])
    }

    func testShakaHoldFires() {
        enable(.shaka)
        var fired: [CustomGesture] = []
        for i in 0..<20 {
            fired += feed([(0, SyntheticHand.shaka())], at: Double(i) / 30)
        }
        XCTAssertEqual(fired, [.shaka])
    }

    func testPressBlocksHeldPose() {
        enable(.thumbsUp)
        var fired: [CustomGesture] = []
        for i in 0..<20 {
            fired += feed([(0, SyntheticHand.thumbSignal(up: true))],
                          at: Double(i) / 30, press: true)
        }
        XCTAssertEqual(fired, [])
    }

    // MARK: - Grab & fling

    @discardableResult
    private func grabFling(delta: Vec2, steps: Int = 8, openFirst: Bool = true,
                           startAt t0: TimeInterval = 0) -> [CustomGesture] {
        var fired: [CustomGesture] = []
        var t = t0
        let wrist = Vec2(0.5, 0.55)
        if openFirst {
            for _ in 0..<3 {
                fired += feed([(0, SyntheticHand.openRelaxed(wrist: wrist))], at: t)
                t += 1.0 / 30
            }
        }
        var w = wrist
        for _ in 0..<3 { // gather in place: engage
            fired += feed([(0, SyntheticHand.gathered(wrist: w))], at: t)
            t += 1.0 / 30
        }
        for _ in 0..<steps { // fling
            w = w + delta
            fired += feed([(0, SyntheticHand.gathered(wrist: w))], at: t)
            t += 1.0 / 30
        }
        return fired
    }

    func testGrabFlingRightFires() {
        enable(.grabFlingRight)
        XCTAssertEqual(grabFling(delta: Vec2(0.03, 0)), [.grabFlingRight])
    }

    func testGrabFlingUpFires() {
        enable(.grabFlingUp)
        XCTAssertEqual(grabFling(delta: Vec2(0, -0.03)), [.grabFlingUp])
    }

    func testGrabFlingDiagonalFires() {
        enable(.grabFlingUpRight)
        XCTAssertEqual(grabFling(delta: Vec2(0.022, -0.022)), [.grabFlingUpRight])
    }

    func testGrabFiresOncePerGrab() {
        enable(.grabFlingRight)
        XCTAssertEqual(grabFling(delta: Vec2(0.03, 0), steps: 16), [.grabFlingRight])
    }

    func testRestingFistNeverFlings() {
        enable(.grabFlingRight)
        // No open hand first: the transition is what makes a grab deliberate.
        XCTAssertEqual(grabFling(delta: Vec2(0.03, 0), openFirst: false), [])
    }

    func testThumbSignalMotionDoesNotFling() {
        enable(.grabFlingRight, .thumbsUp)
        var fired: [CustomGesture] = []
        var t = 0.0
        var w = Vec2(0.4, 0.55)
        for _ in 0..<3 {
            fired += feed([(0, SyntheticHand.openRelaxed(wrist: w))], at: t)
            t += 1.0 / 30
        }
        // Thumbs-up held while the hand drifts: must not read as a grab.
        for _ in 0..<12 {
            fired += feed([(0, SyntheticHand.thumbSignal(up: true, wrist: w))], at: t)
            w = w + Vec2(0.02, 0)
            t += 1.0 / 30
        }
        XCTAssertFalse(fired.contains(.grabFlingRight))
    }

    func testFlingSectorMath() {
        XCTAssertEqual(CustomGestureDetector.flingGesture(for: Vec2(1, 0)), .grabFlingRight)
        XCTAssertEqual(CustomGestureDetector.flingGesture(for: Vec2(-1, 0)), .grabFlingLeft)
        XCTAssertEqual(CustomGestureDetector.flingGesture(for: Vec2(0, -1)), .grabFlingUp)
        XCTAssertEqual(CustomGestureDetector.flingGesture(for: Vec2(0, 1)), .grabFlingDown)
        XCTAssertEqual(CustomGestureDetector.flingGesture(for: Vec2(0.7, -0.7)), .grabFlingUpRight)
        XCTAssertEqual(CustomGestureDetector.flingGesture(for: Vec2(-0.7, -0.7)), .grabFlingUpLeft)
        XCTAssertEqual(CustomGestureDetector.flingGesture(for: Vec2(-0.7, 0.7)), .grabFlingDownLeft)
        XCTAssertEqual(CustomGestureDetector.flingGesture(for: Vec2(0.7, 0.7)), .grabFlingDownRight)
    }

    func testGrabParksReportedWhileEngaged() {
        enable(.grabFlingRight)
        var t = 0.0
        for _ in 0..<3 {
            feed([(0, SyntheticHand.openRelaxed(wrist: Vec2(0.5, 0.55)))], at: t)
            t += 1.0 / 30
        }
        for _ in 0..<3 {
            feed([(0, SyntheticHand.gathered(wrist: Vec2(0.5, 0.55)))], at: t)
            t += 1.0 / 30
        }
        XCTAssertTrue(detector.grabbingSlots.contains(0))
        // Open back up: the grab releases (debounced) and the park lifts.
        for _ in 0..<4 {
            feed([(0, SyntheticHand.openRelaxed(wrist: Vec2(0.5, 0.55)))], at: t)
            t += 1.0 / 30
        }
        XCTAssertFalse(detector.grabbingSlots.contains(0))
    }

    func testEmptyConfigDetectsNothing() {
        var fired = sweep(from: Vec2(0.2, 0.6), delta: Vec2(0.05, 0), steps: 9)
        for i in 0..<20 {
            fired += feed([(0, SyntheticHand.thumbSignal(up: true))], at: 1.0 + Double(i) / 30)
        }
        XCTAssertEqual(fired, [])
    }

    func testConfigChangeResetsInFlightState() {
        enable(.thumbsUp)
        for i in 0..<8 {
            feed([(0, SyntheticHand.thumbSignal(up: true))], at: Double(i) / 30)
        }
        enable(.thumbsUp, .shaka) // any config change resets the dwell
        var fired: [CustomGesture] = []
        for i in 8..<12 {
            fired += feed([(0, SyntheticHand.thumbSignal(up: true))], at: Double(i) / 30)
        }
        XCTAssertEqual(fired, []) // dwell restarted; 4 frames isn't 0.35 s
    }
}

// MARK: - Pose predicates

final class CustomPoseFeatureTests: XCTestCase {
    private func features(_ hand: Hand) -> HandFeatures {
        HandFeatures(hand: hand, thresholds: PoseThresholds(), minJointConfidence: 0.25)!
    }

    func testThumbSignalPoses() {
        XCTAssertTrue(features(SyntheticHand.thumbSignal(up: true)).isThumbSignal(up: true))
        XCTAssertFalse(features(SyntheticHand.thumbSignal(up: true)).isThumbSignal(up: false))
        XCTAssertTrue(features(SyntheticHand.thumbSignal(up: false)).isThumbSignal(up: false))
        // An open hand and a plain tucked-thumb fist are neither.
        XCTAssertFalse(features(SyntheticHand.openRelaxed()).isThumbSignal(up: true))
        XCTAssertFalse(features(SyntheticHand.fist()).isThumbSignal(up: true))
        XCTAssertFalse(features(SyntheticHand.fist()).isThumbSignal(up: false))
    }

    func testThumbSignalHeldIsLooser() {
        XCTAssertTrue(features(SyntheticHand.thumbSignal(up: true)).isThumbSignalHeld(up: true))
        XCTAssertFalse(features(SyntheticHand.openRelaxed()).isThumbSignalHeld(up: true))
    }

    func testGatherPose() {
        XCTAssertTrue(features(SyntheticHand.gathered()).isGathered())
        XCTAssertTrue(features(SyntheticHand.gathered()).isGatherHeld())
        XCTAssertFalse(features(SyntheticHand.openRelaxed()).isGathered())
        XCTAssertFalse(features(SyntheticHand.openRelaxed()).isGatherHeld())
        // The shaka's extended pinky keeps it out of the gather.
        XCTAssertFalse(features(SyntheticHand.shaka()).isGathered())
    }

    func testFistHasNoVerticalThumb() {
        XCTAssertNil(features(SyntheticHand.fist()).thumbVerticalSign())
        XCTAssertEqual(features(SyntheticHand.thumbSignal(up: true)).thumbVerticalSign(), 1)
        XCTAssertEqual(features(SyntheticHand.thumbSignal(up: false)).thumbVerticalSign(), -1)
    }

    func testShakaHeldIsLooser() {
        XCTAssertTrue(features(SyntheticHand.shaka()).isShakaHeld())
        XCTAssertFalse(features(SyntheticHand.openRelaxed()).isShakaHeld())
    }

    func testFingertipExtentTracksTipDistance() {
        let open = features(SyntheticHand.wigglePhase(contracted: false))
        let contracted = features(SyntheticHand.wigglePhase(contracted: true))
        for finger in Finger.allCases {
            let a = open.fingertipExtent(finger)
            let b = contracted.fingertipExtent(finger)
            XCTAssertNotNil(a)
            XCTAssertNotNil(b)
            XCTAssertGreaterThan(a! - b!, 0.045, "wiggle swing must clear the noise floor")
        }
    }
}
