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

    // MARK: - Pointed wiggle

    @discardableResult
    private func pointedWiggle(slot: Int = 0, wrist: Vec2 = Vec2(0.5, 0.7), frames: Int,
                               moving delta: Vec2 = .zero,
                               startAt t0: TimeInterval = 0) -> [CustomGesture] {
        var fired: [CustomGesture] = []
        var w = wrist
        for i in 0..<frames {
            fired += feed([(slot, SyntheticHand.pointedHand(struck: i % 2 == 1, wrist: w))],
                          at: t0 + Double(i) / 30)
            w = w + delta
        }
        return fired
    }

    func testPointedWiggleFires() {
        enable(.pointedWiggle)
        XCTAssertEqual(pointedWiggle(frames: 12), [.pointedWiggle])
    }

    func testPointedMotionNeverFiresTheRaisedGesture() {
        // Only the raised wiggle is bound: drumming a pointed hand is a
        // different gesture and must stay silent.
        enable(.fingerWiggle)
        XCTAssertEqual(pointedWiggle(frames: 30), [])
    }

    func testRaisedMotionNeverFiresThePointedGesture() {
        enable(.pointedWiggle)
        XCTAssertEqual(wiggle(frames: 30), [])
    }

    func testTravellingPointedHandDoesNotWiggle() {
        enable(.pointedWiggle)
        XCTAssertEqual(pointedWiggle(frames: 14, moving: Vec2(0.03, 0)), [])
    }

    func testTwoHandPointedWiggleFires() {
        enable(.pointedWiggle, .twoHandPointedWiggle)
        var fired: [CustomGesture] = []
        for i in 0..<14 {
            let struck = i % 2 == 1
            fired += feed(
                [(0, SyntheticHand.pointedHand(struck: struck, wrist: Vec2(0.3, 0.7))),
                 (1, SyntheticHand.pointedHand(struck: struck, wrist: Vec2(0.7, 0.7)))],
                at: Double(i) / 30)
        }
        XCTAssertEqual(fired, [.twoHandPointedWiggle])
    }

    func testMixedOrientationsDoNotPair() {
        // One hand raised and wiggling, the other pointed and drumming:
        // two different gestures at once, not a two-hand pair. Exactly one
        // single fires (the family refractory holds the other back).
        enable(.fingerWiggle, .twoHandFingerWiggle, .pointedWiggle, .twoHandPointedWiggle)
        var fired: [CustomGesture] = []
        for i in 0..<25 {
            let phase = i % 2 == 1
            fired += feed(
                [(0, SyntheticHand.wigglePhase(contracted: phase, wrist: Vec2(0.3, 0.7))),
                 (1, SyntheticHand.pointedHand(struck: phase, wrist: Vec2(0.7, 0.7)))],
                at: Double(i) / 30)
        }
        XCTAssertEqual(fired.count, 1)
        XCTAssertFalse(fired.contains(.twoHandFingerWiggle))
        XCTAssertFalse(fired.contains(.twoHandPointedWiggle))
    }

    func testPointedHandNeverReadsAsThumbSignal() {
        // The pointed hand's tips collapse onto the palm (the closed-hand
        // read matches) and its thumb juts sideways — without the
        // orientation guard, drumming at the screen dwells a phantom
        // thumbs-left.
        enable(.thumbsLeft)
        XCTAssertEqual(pointedWiggle(frames: 30), [])
    }

    func testThumbSignalFiresFacingTheCamera() {
        // A knuckles-on fist: the curled chains project straight, so the
        // angle-band fist never matches — the collapsed-tips read is what
        // lets the natural thumbs-up engage.
        enable(.thumbsUp)
        var fired: [CustomGesture] = []
        var t = 0.0
        for _ in 0..<20 {
            fired += feed([(0, SyntheticHand.thumbSignalTowardCamera(.up))], at: t)
            t += 1.0 / 30
        }
        XCTAssertEqual(fired, [.thumbsUp])
    }

    func testHoldProgressCountsDownAndClears() {
        enable(.thumbsUp)
        var t = 0.0
        for _ in 0..<4 {
            _ = feed([(0, SyntheticHand.thumbSignal(.up))], at: t)
            t += 1.0 / 30
        }
        guard let progress = detector.holdProgress else {
            return XCTFail("a dwelling hold must be visible")
        }
        XCTAssertEqual(progress.gesture, .thumbsUp)
        XCTAssertEqual(progress.remaining, 0.35 - 3.0 / 30, accuracy: 0.02)

        // Fires at the dwell; a fired hold no longer counts down.
        for _ in 0..<10 {
            _ = feed([(0, SyntheticHand.thumbSignal(.up))], at: t)
            t += 1.0 / 30
        }
        XCTAssertNil(detector.holdProgress)
    }

    func testOrientationSwitchRestartsTheCount() {
        // A few raised phases, then the hand drops into the pointed pose:
        // the buffers restart with the pose, so only the pointed wiggle
        // fires — and only from pointed-pose motion.
        enable(.fingerWiggle, .pointedWiggle)
        var fired: [CustomGesture] = []
        for i in 0..<4 {
            fired += feed([(0, SyntheticHand.wigglePhase(contracted: i % 2 == 1))],
                          at: Double(i) / 30)
        }
        for i in 4..<22 {
            fired += feed([(0, SyntheticHand.pointedHand(struck: i % 2 == 1))],
                          at: Double(i) / 30)
        }
        XCTAssertEqual(fired, [.pointedWiggle])
    }

    // MARK: - Held poses

    private func holdPose(_ hand: @autoclosure () -> Hand, frames: Int,
                          startAt t0: TimeInterval = 0, press: Bool = false) -> [CustomGesture] {
        var fired: [CustomGesture] = []
        for i in 0..<frames {
            fired += feed([(0, hand())], at: t0 + Double(i) / 30, press: press)
        }
        return fired
    }

    func testEachThumbDirectionFires() {
        let cases: [(HandFeatures.ThumbDirection, CustomGesture)] = [
            (.up, .thumbsUp), (.down, .thumbsDown), (.left, .thumbsLeft), (.right, .thumbsRight),
        ]
        for (direction, gesture) in cases {
            detector.reset()
            enable(.thumbsUp, .thumbsDown, .thumbsLeft, .thumbsRight)
            let fired = holdPose(SyntheticHand.thumbSignal(direction), frames: 20)
            XCTAssertEqual(fired, [gesture], "direction \(direction)")
        }
    }

    func testThumbsUpHoldFiresOnce() {
        enable(.thumbsUp)
        XCTAssertEqual(holdPose(SyntheticHand.thumbSignal(.up), frames: 20), [.thumbsUp])
    }

    func testBriefThumbsUpDoesNotFire() {
        enable(.thumbsUp)
        var fired = holdPose(SyntheticHand.thumbSignal(.up), frames: 6) // 0.2 s < dwell
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
            fired += feed([(0, SyntheticHand.thumbSignal(.up))], at: t)
            t += 1.0 / 30
        }
        for _ in 0..<30 { // open up well past the hold refractory
            fired += feed([(0, SyntheticHand.openRelaxed())], at: t)
            t += 1.0 / 30
        }
        for _ in 0..<15 {
            fired += feed([(0, SyntheticHand.thumbSignal(.up))], at: t)
            t += 1.0 / 30
        }
        XCTAssertEqual(fired, [.thumbsUp, .thumbsUp])
    }

    func testShakaHoldFires() {
        enable(.shaka)
        XCTAssertEqual(holdPose(SyntheticHand.shaka(), frames: 20), [.shaka])
    }

    func testPressBlocksHeldPose() {
        enable(.thumbsUp)
        XCTAssertEqual(holdPose(SyntheticHand.thumbSignal(.up), frames: 20, press: true), [])
    }

    // MARK: - Grab & fling

    @discardableResult
    private func grabFling(delta: Vec2, steps: Int = 8, openFirst: Bool = true,
                           hand: (Vec2) -> Hand = { SyntheticHand.gathered(wrist: $0) },
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
            fired += feed([(0, hand(w))], at: t)
            t += 1.0 / 30
        }
        for _ in 0..<steps { // fling
            w = w + delta
            fired += feed([(0, hand(w))], at: t)
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

    func testForwardGatherFlings() {
        // The fingertips bunch in front of the palm, chains projecting
        // straight — the real-world grab that palm-relative measures missed.
        enable(.grabFlingRight)
        let fired = grabFling(delta: Vec2(0.03, 0),
                              hand: { SyntheticHand.gatheredForward(wrist: $0) })
        XCTAssertEqual(fired, [.grabFlingRight])
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

    func testClosedHandTravellingDoesNotEngageGrab() {
        // A relaxed closed hand moving through the frame (the return stroke
        // shape): closing mid-flight fails the engage stillness gate.
        enable(.grabFlingLeft, .grabFlingRight)
        var fired: [CustomGesture] = []
        var t = 0.0
        var w = Vec2(0.75, 0.6)
        for _ in 0..<3 {
            fired += feed([(0, SyntheticHand.openRelaxed(wrist: w))], at: t)
            t += 1.0 / 30
        }
        for _ in 0..<10 { // closes and travels in the same breath
            w = w + Vec2(-0.04, 0)
            fired += feed([(0, SyntheticHand.gathered(wrist: w))], at: t)
            t += 1.0 / 30
        }
        XCTAssertEqual(fired, [])
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
            fired += feed([(0, SyntheticHand.thumbSignal(.up, wrist: w))], at: t)
            w = w + Vec2(0.02, 0)
            t += 1.0 / 30
        }
        XCTAssertFalse(fired.contains(.grabFlingRight))
    }

    func testShakaMotionDoesNotFling() {
        // A held shaka drifting across the frame must not read as a grab &
        // fling: its extended thumb keeps the tip bunch wide open.
        enable(.grabFlingRight, .shaka)
        var fired: [CustomGesture] = []
        var t = 0.0
        var w = Vec2(0.4, 0.55)
        for _ in 0..<3 {
            fired += feed([(0, SyntheticHand.openRelaxed(wrist: w))], at: t)
            t += 1.0 / 30
        }
        for _ in 0..<12 {
            fired += feed([(0, SyntheticHand.shaka(wrist: w))], at: t)
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

    func testCrissCrossBlocksGrab() {
        enable(.grabFlingRight)
        var fired: [CustomGesture] = []
        var t = 0.0
        let wrist = Vec2(0.5, 0.55)
        for _ in 0..<3 {
            fired += feed([(0, SyntheticHand.openRelaxed(wrist: wrist))], at: t, crissCross: true)
            t += 1.0 / 30
        }
        var w = wrist
        for _ in 0..<11 {
            fired += feed([(0, SyntheticHand.gathered(wrist: w))], at: t, crissCross: true)
            w = w + Vec2(0.03, 0)
            t += 1.0 / 30
        }
        XCTAssertEqual(fired, [])
    }

    func testEmptyConfigDetectsNothing() {
        var fired: [CustomGesture] = []
        for i in 0..<20 {
            fired += feed([(0, SyntheticHand.thumbSignal(.up))], at: Double(i) / 30)
        }
        fired += grabFling(delta: Vec2(0.03, 0), startAt: 1.0)
        XCTAssertEqual(fired, [])
    }

    func testConfigChangeResetsInFlightState() {
        enable(.thumbsUp)
        for i in 0..<8 {
            feed([(0, SyntheticHand.thumbSignal(.up))], at: Double(i) / 30)
        }
        enable(.thumbsUp, .shaka) // any config change resets the dwell
        var fired: [CustomGesture] = []
        for i in 8..<12 {
            fired += feed([(0, SyntheticHand.thumbSignal(.up))], at: Double(i) / 30)
        }
        XCTAssertEqual(fired, []) // dwell restarted; 4 frames isn't 0.35 s
    }
}

// MARK: - Pose predicates

final class CustomPoseFeatureTests: XCTestCase {
    private func features(_ hand: Hand) -> HandFeatures {
        HandFeatures(hand: hand, thresholds: PoseThresholds(), minJointConfidence: 0.25)!
    }

    func testThumbDirections() {
        for direction in HandFeatures.ThumbDirection.allCases {
            let hand = SyntheticHand.thumbSignal(direction)
            XCTAssertEqual(features(hand).thumbDirection(), direction)
            XCTAssertTrue(features(hand).isThumbSignal(direction))
            XCTAssertTrue(features(hand).isThumbSignalHeld(direction))
            for other in HandFeatures.ThumbDirection.allCases where other != direction {
                XCTAssertFalse(features(hand).isThumbSignal(other),
                               "\(direction) must not read as \(other)")
            }
        }
        // An open hand and a plain tucked-thumb fist are no signal at all.
        XCTAssertNil(features(SyntheticHand.fist()).thumbDirection())
        XCTAssertFalse(features(SyntheticHand.openRelaxed()).isThumbSignal(.up))
    }

    func testGatherSpreadSeparatesPoses() {
        let forward = features(SyntheticHand.gatheredForward()).fingertipGatherSpread()
        let open = features(SyntheticHand.openRelaxed()).fingertipGatherSpread()
        let thumbs = features(SyntheticHand.thumbSignal(.up)).fingertipGatherSpread()
        XCTAssertNotNil(forward)
        XCTAssertNotNil(open)
        XCTAssertNotNil(thumbs)
        XCTAssertLessThan(forward!, 0.2, "a bunched hand is tight")
        XCTAssertGreaterThan(open!, 0.5, "an open hand is wide")
        XCTAssertGreaterThan(thumbs!, 0.32, "the out-thumb keeps a thumb signal wide")
    }

    func testGatherPose() {
        let limit = CustomGestureDetector.Config().gatherSpread
        XCTAssertTrue(features(SyntheticHand.gathered()).isGathered(spreadLimit: limit))
        XCTAssertTrue(features(SyntheticHand.gatheredForward()).isGathered(spreadLimit: limit))
        XCTAssertFalse(features(SyntheticHand.openRelaxed()).isGathered(spreadLimit: limit))
        // The shaka's out-thumb and pinky keep its bunch wide, and its
        // extended thumb blocks the openness path.
        XCTAssertFalse(features(SyntheticHand.shaka()).isGathered(spreadLimit: limit))
        // Thumb signals stay out of the grab the same two ways.
        XCTAssertFalse(features(SyntheticHand.thumbSignal(.up)).isGathered(spreadLimit: limit))
        XCTAssertFalse(features(SyntheticHand.thumbSignal(.left)).isGathered(spreadLimit: limit))
    }

    func testGatherPointRidesTheBunch() {
        let wrist = Vec2(0.5, 0.7)
        let hand = SyntheticHand.gatheredForward(wrist: wrist)
        guard let point = features(hand).gatherPoint() else {
            return XCTFail("no gather point")
        }
        let bunch = wrist + Vec2(-0.35, -1.55) * 0.15
        XCTAssertLessThan(point.distance(to: bunch), 0.02,
                          "the fling must track the bunch, not the palm")
        if let palm = features(hand).pointerPoint(.palmCenter) {
            XCTAssertGreaterThan(point.distance(to: palm), 0.08,
                                 "the bunch stands away from the palm in a forward gather")
        }
    }

    func testGatherHeldHoldsOnUnreadableGeometry() {
        // Only thumb + index tracked: neither spread (needs 4 tips) nor
        // openness (needs all four fingertips) is readable → nil, which the
        // detector treats as "hold", never "released".
        var joints: [HandJoint: Vec2] = [
            .wrist: Vec2(0.5, 0.7), .middleMCP: Vec2(0.5, 0.55),
            .indexMCP: Vec2(0.46, 0.56), .littleMCP: Vec2(0.56, 0.58),
            .thumbTip: Vec2(0.45, 0.5), .indexTip: Vec2(0.46, 0.5),
        ]
        joints[.indexPIP] = Vec2(0.455, 0.53)
        let hand = Hand(chirality: .right, confidence: 1, joints: joints)
        let limit = CustomGestureDetector.Config().gatherSpread
        XCTAssertNil(features(hand).isGatherHeld(spreadLimit: limit))
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

    func testWiggleOrientationSeparatesThePoses() {
        // Raised through both wiggle phases; pointed through both drum
        // phases — the classification must hold across the whole motion,
        // not just its stillest frame.
        XCTAssertEqual(features(SyntheticHand.wigglePhase(contracted: false)).wiggleOrientation(), .raised)
        XCTAssertEqual(features(SyntheticHand.wigglePhase(contracted: true)).wiggleOrientation(), .raised)
        XCTAssertEqual(features(SyntheticHand.openRelaxed()).wiggleOrientation(), .raised)
        XCTAssertEqual(features(SyntheticHand.pointedHand(struck: false)).wiggleOrientation(), .pointed)
        XCTAssertEqual(features(SyntheticHand.pointedHand(struck: true)).wiggleOrientation(), .pointed)
        // A fist commits to neither pose: its curled tips sit in the gap
        // between the bands, and a pose that isn't clearly one wiggle or
        // the other must not feed either machine.
        XCTAssertNil(features(SyntheticHand.fist()).wiggleOrientation())
    }

    func testFingertipDropSwingClearsThePointedNoiseFloor() {
        let lifted = features(SyntheticHand.pointedHand(struck: false))
        let struck = features(SyntheticHand.pointedHand(struck: true))
        for finger in Finger.allCases {
            let a = lifted.fingertipDrop(finger)
            let b = struck.fingertipDrop(finger)
            XCTAssertNotNil(a)
            XCTAssertNotNil(b)
            XCTAssertGreaterThan(b! - a!, 0.10, "drum swing must clear the pointed noise floor")
        }
    }
}
