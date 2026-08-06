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
        XCTAssertFalse(features(SyntheticHand.twoFingerPoint()).isFist())
    }

    func testShakaDetection() {
        XCTAssertTrue(features(SyntheticHand.shaka()).isShaka())
        XCTAssertFalse(features(SyntheticHand.openSplayed()).isShaka())
        XCTAssertFalse(features(SyntheticHand.fist()).isShaka(),
                       "fist has no extended thumb/little, must not read as shaka")
    }

    func testTwoFingerPointDetection() {
        XCTAssertTrue(features(SyntheticHand.twoFingerPoint()).isTwoFingerPoint())
        XCTAssertFalse(features(SyntheticHand.openRelaxed()).isTwoFingerPoint())
        XCTAssertFalse(features(SyntheticHand.fist()).isTwoFingerPoint())
        XCTAssertFalse(features(SyntheticHand.shaka()).isTwoFingerPoint())
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
}
