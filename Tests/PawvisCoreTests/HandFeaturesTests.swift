import XCTest
@testable import PawvisCore

final class HandFeaturesTests: XCTestCase {
    private func features(_ hand: Hand) -> HandFeatures {
        HandFeatures(hand: hand)!
    }

    func testScaleIsWristToMiddleMCP() {
        let f = features(SyntheticHand.openRelaxed(scale: 0.15))
        XCTAssertEqual(f.scale, 0.15, accuracy: 1e-9)
    }

    func testScaleFallsBackToKnuckleSpanWhenWristMissing() {
        var hand = SyntheticHand.openRelaxed(scale: 0.15)
        var joints: [HandJoint: Vec2] = [:]
        for joint in HandJoint.allCases where joint != .wrist {
            if let p = hand[joint] { joints[joint] = p }
        }
        hand = Hand(joints: joints)
        let f = HandFeatures(hand: hand)
        XCTAssertNotNil(f)
        // Knuckle span is 0.67·scale in the synthetic geometry; the fallback
        // divides by 0.7, so it lands near the true scale.
        XCTAssertEqual(f!.scale, 0.15, accuracy: 0.02)
    }

    func testFeaturesNilWhenNoUsableJoints() {
        XCTAssertNil(HandFeatures(hand: Hand()))
    }

    // MARK: Pinch ratios

    func testPinchRatioTracksGap() {
        let tight = features(SyntheticHand.pinchIndex(gap: 0.1))
        let open = features(SyntheticHand.openRelaxed())
        XCTAssertEqual(tight.pinchRatio(to: .index)!, 0.1, accuracy: 1e-6)
        XCTAssertGreaterThan(open.pinchRatio(to: .index)!, 0.68,
                             "relaxed open hand must be clearly outside the release threshold")
    }

    func testPinchPointIsMidpoint() {
        let hand = SyntheticHand.pinchIndex(gap: 0.2)
        let f = features(hand)
        let expected = hand[.thumbTip]!.midpoint(with: hand[.indexTip]!)
        XCTAssertEqual(f.pinchPoint(with: .index)!.distance(to: expected), 0, accuracy: 1e-9)
    }

    func testMiddlePinchLeavesIndexOpen() {
        let f = features(SyntheticHand.pinchFinger(.middle, gap: 0.1))
        XCTAssertLessThan(f.pinchRatio(to: .middle)!, 0.45)
        XCTAssertGreaterThan(f.pinchRatio(to: .index)!, 0.68,
                             "index must read clearly open during a middle-finger pinch")
    }

    // MARK: Thumb curl

    func testThumbCurlRatioDropsWhenTucked() {
        let hand = SyntheticHand.highFive(thumbTucked: true)
        let f = features(hand)
        let expected = hand[.thumbTip]!.distance(to: hand[.indexMCP]!) / f.scale
        XCTAssertEqual(f.thumbCurlRatio()!, expected, accuracy: 1e-9)
        XCTAssertLessThan(f.thumbCurlRatio()!, 0.36, "a tucked thumb clears the default engage threshold")
        XCTAssertGreaterThan(features(SyntheticHand.highFive(thumbTucked: false)).thumbCurlRatio()!, 0.6)
    }

    func testThumbCurlRatioNilWhenJointMissing() {
        var hand = SyntheticHand.highFive(thumbTucked: true)
        hand.setPoint(hand[.indexMCP]!, for: .indexMCP, confidence: 0.1)
        XCTAssertNil(HandFeatures(hand: hand, minJointConfidence: 0.25)!.thumbCurlRatio())
    }

    func testThumbExtendedStillThresholdsTheCurlRatio() {
        // The shared metric must not have moved isThumbExtended's line.
        XCTAssertEqual(features(SyntheticHand.openRelaxed()).isThumbExtended(), true)
        XCTAssertEqual(features(SyntheticHand.fist()).isThumbExtended(), false)
        XCTAssertEqual(features(SyntheticHand.highFive(thumbTucked: true)).isThumbExtended(), false)
    }

    // MARK: Finger extension

    func testExtensionOnOpenHand() {
        let f = features(SyntheticHand.openRelaxed())
        for finger in Finger.allCases {
            XCTAssertEqual(f.isExtended(finger), true, "\(finger) should be extended")
            XCTAssertEqual(f.isCurled(finger), false)
        }
        XCTAssertEqual(f.isThumbExtended(), true)
    }

    func testCurlOnFist() {
        let f = features(SyntheticHand.fist())
        for finger in Finger.allCases {
            XCTAssertEqual(f.isCurled(finger), true, "\(finger) should be curled in a fist")
        }
        XCTAssertEqual(f.isThumbExtended(), false)
    }

    func testExtensionNilWhenJointsMissing() {
        var joints: [HandJoint: Vec2] = [:]
        let full = SyntheticHand.openRelaxed()
        for joint in HandJoint.allCases where joint != .indexPIP {
            if let p = full[joint] { joints[joint] = p }
        }
        let f = features(Hand(joints: joints))
        XCTAssertNil(f.isExtended(.index))
        XCTAssertNotNil(f.isExtended(.middle))
    }

    func testIndexTapRatio() {
        // Both fingers up → extents match → idles at 1.0 exactly (synthetic
        // fingers share segment lengths; real hands idle slightly below).
        XCTAssertEqual(features(SyntheticHand.mouseTap(indexDown: false)).indexTapRatio()!,
                       1.0, accuracy: 1e-2)
        // Index dipped → its extent collapses → ratio drops well below engage.
        XCTAssertLessThan(features(SyntheticHand.mouseTap(indexDown: true)).indexTapRatio()!, 0.4)
        // Whole-hand curl moves both fingers together → differential stays ~1.
        XCTAssertEqual(features(SyntheticHand.fist()).indexTapRatio()!, 1.0, accuracy: 0.1)
    }

    func testTapReferencePairsArePinned() {
        // Each finger measures against a neighbor that holds still while it
        // dips — and the pairing is what keeps two dip-driven buttons apart.
        XCTAssertEqual(HandFeatures.tapReference(for: .index), .middle)
        XCTAssertEqual(HandFeatures.tapReference(for: .middle), .index)
        XCTAssertEqual(HandFeatures.tapReference(for: .ring), .middle)
        XCTAssertEqual(HandFeatures.tapReference(for: .little), .ring)
    }

    func testIndexTapRatioIsTheIndexFingerTapRatio() {
        for hand in [SyntheticHand.mouseTap(indexDown: false),
                     SyntheticHand.mouseTap(indexDown: true),
                     SyntheticHand.fist()] {
            let f = features(hand)
            XCTAssertEqual(f.indexTapRatio()!, f.fingerTapRatio(.index)!, accuracy: 1e-12,
                           "the index tap is just the general differential, pinned to index→middle")
        }
    }

    func testFingerTapRatioReadsTheDippedFinger() {
        let f = features(SyntheticHand.fingerDip(.little))
        XCTAssertLessThan(f.fingerTapRatio(.little)!, 0.4, "a dipped pinky reads as a tap")
        XCTAssertEqual(f.fingerTapRatio(.index)!, 1.0, accuracy: 1e-2,
                       "…while the index finger idles")
        XCTAssertLessThan(features(SyntheticHand.fingerDip(.ring)).fingerTapRatio(.ring)!, 0.4)
    }

    func testFingerTapRatiosAreIndependent() {
        // The whole point of the pinned pairs (index→middle, little→ring): one
        // finger's dip must never push another's ratio toward engagement, or
        // left- and right-click would trip each other.
        let indexDipped = features(SyntheticHand.fingerDip(.index))
        XCTAssertLessThan(indexDipped.fingerTapRatio(.index)!, 0.4)
        XCTAssertEqual(indexDipped.fingerTapRatio(.little)!, 1.0, accuracy: 1e-2,
                       "the little finger references the ring, so an index dip leaves it flat")

        let littleDipped = features(SyntheticHand.fingerDip(.little))
        XCTAssertLessThan(littleDipped.fingerTapRatio(.little)!, 0.4)
        XCTAssertEqual(littleDipped.fingerTapRatio(.index)!, 1.0, accuracy: 1e-2)
    }

    func testFingerTapRatioNilWithoutItsReference() {
        var joints: [HandJoint: Vec2] = [:]
        let full = SyntheticHand.fingerDip(.little)
        for joint in HandJoint.allCases where joint != .ringTip {
            if let p = full[joint] { joints[joint] = p }
        }
        let f = features(Hand(joints: joints))
        XCTAssertNil(f.fingerTapRatio(.little), "the little finger needs the ring as its reference")
        XCTAssertNotNil(f.fingerTapRatio(.index))
    }

    func testIndexTapRatioNilWithoutMiddleFinger() {
        var joints: [HandJoint: Vec2] = [:]
        let full = SyntheticHand.mouseTap(indexDown: false)
        for joint in HandJoint.allCases where joint != .middleTip {
            if let p = full[joint] { joints[joint] = p }
        }
        XCTAssertNil(features(Hand(joints: joints)).indexTapRatio(),
                     "the differential needs the middle finger as its reference")
    }

    // MARK: Poses

    func testSplayDetection() {
        XCTAssertTrue(features(SyntheticHand.openSplayed()).isOpenPalmSplayed())
        XCTAssertFalse(features(SyntheticHand.openRelaxed()).isOpenPalmSplayed(),
                       "relaxed fingers-together hand must not read as splayed")
        XCTAssertFalse(features(SyntheticHand.fist()).isOpenPalmSplayed())
    }

    func testSplayAmountOrdering() {
        let splayed = features(SyntheticHand.openSplayed()).splayAmount()!
        let relaxed = features(SyntheticHand.openRelaxed()).splayAmount()!
        XCTAssertGreaterThan(splayed, relaxed * 1.5)
    }

    func testFistDetection() {
        XCTAssertTrue(features(SyntheticHand.fist()).isFist())
        XCTAssertFalse(features(SyntheticHand.openRelaxed()).isFist())
        XCTAssertFalse(features(SyntheticHand.scrollPose()).isFist())
    }

    func testShakaDetection() {
        XCTAssertTrue(features(SyntheticHand.shaka()).isShaka())
        XCTAssertFalse(features(SyntheticHand.openSplayed()).isShaka())
        XCTAssertFalse(features(SyntheticHand.fist()).isShaka(),
                       "fist has no extended thumb/little, must not read as shaka")
    }

    func testScrollPoseDetection() {
        XCTAssertTrue(features(SyntheticHand.scrollPose()).isScrollPose())
        XCTAssertFalse(features(SyntheticHand.openRelaxed()).isScrollPose())
        XCTAssertFalse(features(SyntheticHand.fist()).isScrollPose())
        XCTAssertFalse(features(SyntheticHand.shaka()).isScrollPose(),
                       "a curled index is not the scroll pose")
        XCTAssertFalse(features(SyntheticHand.mouseTap(indexDown: true)).isScrollPose())
        XCTAssertFalse(features(SyntheticHand.scrollPoseHalf()).isScrollPose(),
                       "half-bent fingers must not *start* a scroll")
    }

    func testScrollPoseHeldIsTheLooseBand() {
        XCTAssertTrue(features(SyntheticHand.scrollPose()).isScrollPoseHeld())
        XCTAssertTrue(features(SyntheticHand.scrollPoseHalf()).isScrollPoseHeld(),
                      "the neutral band keeps a scroll alive — hysteresis for free")
        XCTAssertFalse(features(SyntheticHand.openRelaxed()).isScrollPoseHeld(),
                       "re-extending the folded fingers ends the pose")
        XCTAssertFalse(features(SyntheticHand.fist()).isScrollPoseHeld(),
                       "…and so does dropping the index and pinky")
    }

    func testCasualPinchHasLowOpennessButIsNotAFist() {
        // Documents the old bug: this natural pinch pose scores low on
        // openness (the old engagement guard blocked it) yet is clearly not
        // a fist — no finger is fully curled.
        let f = features(SyntheticHand.pinchIndexCasual(gap: 0.1))
        XCTAssertLessThan(f.openness()!, 0.30)
        XCTAssertFalse(f.isFist())
        for finger in [Finger.middle, .ring, .little] {
            XCTAssertEqual(f.isCurled(finger), false, "\(finger) is half-bent, not curled")
        }
    }

    func testOpennessOrdering() {
        let open = features(SyntheticHand.openRelaxed()).openness()!
        let fist = features(SyntheticHand.fist()).openness()!
        XCTAssertGreaterThan(open, 0.4)
        XCTAssertLessThan(fist, 0.1)
    }

    // MARK: Pointer

    func testPointerSources() {
        let hand = SyntheticHand.openRelaxed()
        let f = features(hand)
        XCTAssertEqual(f.pointerPoint(.indexTip), hand[.indexTip])
        XCTAssertEqual(
            f.pointerPoint(.pinchMidpoint)!,
            hand[.thumbTip]!.midpoint(with: hand[.indexTip]!))
        let palm = f.pointerPoint(.palmCenter)!
        // Palm center sits between the wrist and the fingertips.
        XCTAssertLessThan(palm.y, hand[.wrist]!.y)
        XCTAssertGreaterThan(palm.y, hand[.middleTip]!.y)
    }

    func testThumbTipPointerSource() {
        let hand = SyntheticHand.openRelaxed()
        XCTAssertEqual(features(hand).pointerPoint(.thumbTip), hand[.thumbTip])
    }

    func testPalmCenterIsStableWristKnuckleMidpoint() {
        let hand = SyntheticHand.openRelaxed()
        let f = features(hand)
        let expected = hand[.wrist]!.midpoint(with: hand[.middleMCP]!)
        XCTAssertEqual(f.pointerPoint(.palmCenter)!.distance(to: expected), 0, accuracy: 1e-9,
                       "palm pointer anchors on wrist↔middleMCP so its composition never varies")
    }

    func testPalmCenterFallsBackToThumbWhenPalmOccluded() {
        // Middle knuckle missing → the palm anchor is unavailable; scale comes
        // from the knuckle span and the pointer falls back to the thumb.
        let full = SyntheticHand.openRelaxed()
        var joints: [HandJoint: Vec2] = [:]
        for joint in [HandJoint.wrist, .indexMCP, .littleMCP, .thumbTip, .indexTip] {
            if let p = full[joint] { joints[joint] = p }
        }
        let f = HandFeatures(hand: Hand(joints: joints))!
        XCTAssertEqual(f.pointerPoint(.palmCenter), full[.thumbTip],
                       "palm pointer must fall back to the thumb tip")
    }

    func testPinchMidpointFallsBackToIndexTipWithoutThumb() {
        var joints: [HandJoint: Vec2] = [:]
        let full = SyntheticHand.openRelaxed()
        for joint in HandJoint.allCases where joint != .thumbTip {
            if let p = full[joint] { joints[joint] = p }
        }
        let f = features(Hand(joints: joints))
        XCTAssertEqual(f.pointerPoint(.pinchMidpoint), full[.indexTip])
    }

    // MARK: Confidence gating

    func testLowConfidenceJointsAreIgnored() {
        var hand = SyntheticHand.openRelaxed()
        hand.setPoint(hand[.indexTip]!, for: .indexTip, confidence: 0.1)
        let f = HandFeatures(hand: hand, minJointConfidence: 0.25)!
        XCTAssertNil(f.pinchRatio(to: .index))
        XCTAssertNotNil(f.pinchRatio(to: .middle))
    }

    // MARK: Control-trigger poses

    func testIsOpenHandOnCanonicalPoses() {
        XCTAssertTrue(features(SyntheticHand.openRelaxed()).isOpenHand())
        XCTAssertTrue(features(SyntheticHand.openSplayed()).isOpenHand())
        XCTAssertTrue(features(SyntheticHand.highFive(thumbTucked: true)).isOpenHand(),
                      "the thumb is free — a thumb-curl click must not break the trigger pose")
        XCTAssertFalse(features(SyntheticHand.fist()).isOpenHand())
        XCTAssertFalse(features(SyntheticHand.halfClosed()).isOpenHand(),
                       "a relaxed half-curl is not the deliberate trigger")
        XCTAssertFalse(features(SyntheticHand.shaka()).isOpenHand())
        XCTAssertFalse(features(SyntheticHand.scrollPose()).isOpenHand())
        XCTAssertFalse(features(SyntheticHand.mouseTap(indexDown: true)).isOpenHand(),
                       "a dipped finger leaves the pose")
    }

    func testForeshortenedCurlDoesNotReadOpen() {
        // Fingers curled toward the camera: every 2D chain is dead straight,
        // so the angle bands alone call all four fingers extended…
        let f = features(SyntheticHand.curledTowardCamera())
        for finger in Finger.allCases {
            XCTAssertEqual(f.isExtended(finger), true,
                           "\(finger) must fool the angle check — that's the failure under test")
        }
        // …but the tips sit on the palm, and the openness floor catches it.
        XCTAssertLessThan(f.openness()!, PoseThresholds().openHandMinOpenness)
        XCTAssertFalse(f.isOpenHand(),
                       "a hand curled toward the camera is not the trigger pose")
    }

    func testOpenHandStrictnessThresholdIsTunable() {
        var strict = PoseThresholds()
        strict.openHandMinOpenness = 0.58
        let hand = SyntheticHand.openRelaxed()
        XCTAssertTrue(HandFeatures(hand: hand)!.isOpenHand(),
                      "the default strictness accepts a plain open hand")
        XCTAssertFalse(HandFeatures(hand: hand, thresholds: strict)!.isOpenHand(),
                       "at high strictness a relaxed open hand is not enough…")
        XCTAssertTrue(HandFeatures(hand: SyntheticHand.openSplayed(), thresholds: strict)!.isOpenHand(),
                      "…but a fully splayed one still is")
    }

    func testIsOpenHandNeedsEveryFingerTracked() {
        let full = SyntheticHand.openRelaxed()
        var joints: [HandJoint: Vec2] = [:]
        for joint in HandJoint.allCases where ![HandJoint.ringPIP, .ringTip].contains(joint) {
            if let p = full[joint] { joints[joint] = p }
        }
        XCTAssertFalse(features(Hand(joints: joints)).isOpenHand(),
                       "a half-tracked hand must not arm cursor control")
    }

    func testCurledFingerCountBands() {
        XCTAssertEqual(features(SyntheticHand.fist()).curledFingerCount(), 4)
        XCTAssertEqual(features(SyntheticHand.openRelaxed()).curledFingerCount(), 0)
        XCTAssertEqual(features(SyntheticHand.halfClosed()).curledFingerCount(), 0,
                       "the neutral band counts for neither pose — hysteresis for free")
        XCTAssertEqual(features(SyntheticHand.shaka()).curledFingerCount(), 3)
        XCTAssertEqual(features(SyntheticHand.mouseTap(indexDown: true)).curledFingerCount(), 1,
                       "a click's finger dip is nowhere near the disarm pose")
    }
}
