import XCTest
@testable import PawvisCore

final class GestureEngineTests: XCTestCase {
    var engine: GestureEngine!

    /// Test config: identity mapping (no mirror, full box) and effectively
    /// disabled smoothing, so positions are exact and assertions deterministic.
    static func testConfig() -> GestureConfig {
        var config = GestureConfig.default
        config.interactionBox = InteractionBox(xMin: 0, xMax: 1, yMin: 0, yMax: 1)
        config.mirrorCamera = false
        config.smoothing = OneEuroFilter.Params(minCutoff: 1e9, beta: 0, dCutoff: 1e9)
        return config
    }

    /// Well inside the engage zone (0.45) and tight enough that the index tip
    /// alone stays within `dragActivationDistance` of the midpoint.
    static let tightGap = 0.10
    /// Between the two thresholds — the hysteresis band (engage 0.45, release
    /// 0.45 + 0.08 = 0.53).
    static let bandGap = 0.49
    /// Above the release threshold (0.53).
    static let openGap = 0.90

    override func setUp() {
        super.setUp()
        engine = GestureEngine(config: Self.testConfig())
    }

    @discardableResult
    private func feed(_ hands: [Hand], at t: TimeInterval) -> (events: [GestureEvent], overlay: OverlayState) {
        engine.process(HandFrame(time: t, hands: hands))
    }

    /// Feed a sequence of identical frames at 30 fps starting at `from`.
    @discardableResult
    private func feedFrames(_ hands: [Hand], from: TimeInterval, count: Int) -> [GestureEvent] {
        var events: [GestureEvent] = []
        for i in 0..<count {
            events += feed(hands, at: from + Double(i) / 30).events
        }
        return events
    }

    private func downs(_ events: [GestureEvent]) -> [(Vec2, Int)] {
        events.compactMap {
            if case .buttonDown(.left, let at, let cc) = $0 { return (at, cc) }
            return nil
        }
    }

    private func ups(_ events: [GestureEvent]) -> [(Vec2, Int)] {
        events.compactMap {
            if case .buttonUp(.left, let at, let cc) = $0 { return (at, cc) }
            return nil
        }
    }

    private func drags(_ events: [GestureEvent]) -> [Vec2] {
        events.compactMap {
            if case .drag(.left, let to) = $0 { return to }
            return nil
        }
    }

    private func moves(_ events: [GestureEvent]) -> [Vec2] {
        events.compactMap {
            if case .move(let to) = $0 { return to }
            return nil
        }
    }

    /// One click: enough pinched frames to clear the debounce, then release.
    @discardableResult
    private func click(at wrist: Vec2, from: TimeInterval) -> [GestureEvent] {
        feedFrames([SyntheticHand.pinchIndex(gap: Self.tightGap, wrist: wrist)], from: from, count: 3)
            + feedFrames([SyntheticHand.openRelaxed(wrist: wrist)], from: from + 0.1, count: 3)
    }

    // MARK: - Config defaults

    func testDefaultConfigMatchesSporecasterPinch() {
        let c = GestureConfig.default
        XCTAssertEqual(c.smoothing, .landmark, "sporecaster smoothed every landmark at 1.4/0.014/1.0")
        XCTAssertEqual(c.pinchEngageRatio, 0.45)
        XCTAssertEqual(c.pinchReleaseRatio, 0.53, accuracy: 1e-9,
                       "release tracks engage + hysteresis, so it follows the sensitivity slider")
    }

    func testReleaseThresholdTracksSensitivity() {
        var c = GestureConfig.default
        c.pinchEngageRatio = 0.55
        XCTAssertEqual(c.pinchReleaseRatio, 0.63, accuracy: 1e-9,
                       "a tighter or looser click setting moves the release point with it")
    }

    // MARK: - Cursor movement

    func testCursorFollowsHand() {
        let e1 = feed([SyntheticHand.openRelaxed(wrist: Vec2(0.5, 0.7))], at: 0).events
        XCTAssertEqual(moves(e1).count, 1)

        let e2 = feed([SyntheticHand.openRelaxed(wrist: Vec2(0.6, 0.7))], at: 1 / 30.0).events
        let m2 = moves(e2)
        XCTAssertEqual(m2.count, 1)
        XCTAssertEqual(m2[0].x - moves(e1)[0].x, 0.1, accuracy: 1e-6)
    }

    func testNoMoveEventWhenStationary() {
        feed([SyntheticHand.openRelaxed()], at: 0)
        let e = feed([SyntheticHand.openRelaxed()], at: 1 / 30.0).events
        XCTAssertTrue(moves(e).isEmpty, "identical frame must not emit a move")
    }

    // MARK: - Overlay

    func testOverlayStateForOpenHand() {
        let (_, overlay) = feed([SyntheticHand.openRelaxed()], at: 0)
        XCTAssertEqual(overlay.hands.count, 1)
        XCTAssertEqual(overlay.hands[0].fingertips.count, 5, "all five tips still get dots")
        XCTAssertTrue(overlay.hands[0].isPrimary)
        XCTAssertNotNil(overlay.cursor)
        XCTAssertFalse(overlay.grabbed)
        XCTAssertEqual(overlay.closingProgress, 0, accuracy: 1e-9,
                       "an open hand sits at zero pinch strength")
    }

    func testClosingProgressRisesAsPinchCloses() {
        let (_, wide) = feed([SyntheticHand.pinchIndex(gap: Self.openGap)], at: 0)
        let (_, near) = feed([SyntheticHand.pinchIndex(gap: 0.6)], at: 1 / 30.0)
        XCTAssertGreaterThan(near.closingProgress, wide.closingProgress,
                             "strength ramps up as the tips close")
        XCTAssertFalse(near.grabbed, "still short of the engage threshold")

        let pinching = feedFrames([SyntheticHand.pinchIndex(gap: Self.tightGap)], from: 0.1, count: 3)
        XCTAssertEqual(downs(pinching).count, 1)
        // Held inside the hysteresis band, where the raw ramp would read ~0.7:
        // the ring must stay filled for as long as the button is down.
        let (_, held) = feed([SyntheticHand.pinchIndex(gap: Self.bandGap)], at: 0.25)
        XCTAssertTrue(held.grabbed)
        XCTAssertEqual(held.closingProgress, 1, "strength pins at 1 while pinched")
    }

    // MARK: - Click (pinch)

    func testPinchClicksAndReleaseFires() {
        feedFrames([SyntheticHand.openRelaxed()], from: 0, count: 4)

        // Two pinched frames clear the debounce → down.
        let closing = feedFrames([SyntheticHand.pinchIndex(gap: Self.tightGap)], from: 0.15, count: 3)
        let d = downs(closing)
        XCTAssertEqual(d.count, 1)
        XCTAssertEqual(d[0].1, 1)
        XCTAssertTrue(drags(closing).isEmpty, "a stationary pinch must not drag")

        let opening = feedFrames([SyntheticHand.openRelaxed()], from: 0.35, count: 3)
        let u = ups(opening)
        XCTAssertEqual(u.count, 1)
        XCTAssertEqual(u[0].1, 1)
        XCTAssertEqual(u[0].0.distance(to: d[0].0), 0, accuracy: 1e-2,
                       "the tips converge on the midpoint, so up lands on down")
    }

    func testSingleFrameBlipDoesNotClick() {
        feedFrames([SyntheticHand.openRelaxed()], from: 0, count: 4)
        // One pinched frame (debounce needs 2), then open again.
        var events = feed([SyntheticHand.pinchIndex(gap: Self.tightGap)], at: 0.15).events
        events += feedFrames([SyntheticHand.openRelaxed()], from: 0.1833, count: 3)
        XCTAssertTrue(downs(events).isEmpty, "a one-frame blip must not click")
    }

    func testSingleFrameReleaseSpikeDoesNotRelease() {
        feedFrames([SyntheticHand.openRelaxed()], from: 0, count: 3)
        XCTAssertEqual(downs(feedFrames([SyntheticHand.pinchIndex(gap: Self.tightGap)],
                                        from: 0.1, count: 3)).count, 1)

        // One frame of Vision noise spiking past the release threshold.
        var events = feed([SyntheticHand.pinchIndex(gap: Self.openGap)], at: 0.25).events
        events += feedFrames([SyntheticHand.pinchIndex(gap: Self.tightGap)], from: 0.2833, count: 3)
        XCTAssertTrue(ups(events).isEmpty, "debounce guards the release direction too")
    }

    func testMissingTipHoldsPinchState() {
        feedFrames([SyntheticHand.openRelaxed()], from: 0, count: 3)
        XCTAssertEqual(downs(feedFrames([SyntheticHand.pinchIndex(gap: Self.tightGap)],
                                        from: 0.1, count: 3)).count, 1)

        // Thumb tip drops below minJointConfidence → no ratio at all.
        var faint = SyntheticHand.pinchIndex(gap: Self.tightGap)
        faint.setPoint(faint[.thumbTip]!, for: .thumbTip, confidence: 0.1)
        let e = feedFrames([faint], from: 0.25, count: 5)
        XCTAssertTrue(ups(e).isEmpty, "a low-confidence tip must never release the button")
        let (_, overlay) = feed([faint], at: 0.45)
        XCTAssertTrue(overlay.grabbed, "state is held, not flapped")

        // Confidence returns: still pinched, and a real open still releases.
        let (_, restored) = feed([SyntheticHand.pinchIndex(gap: Self.tightGap)], at: 0.5)
        XCTAssertTrue(restored.grabbed)
        XCTAssertEqual(ups(feedFrames([SyntheticHand.openRelaxed()], from: 0.55, count: 3)).count, 1)
    }

    func testDoubleTripleThenWrapChaining() {
        feedFrames([SyntheticHand.openRelaxed()], from: 0, count: 3)
        let w = Vec2(0.5, 0.7)

        let c1 = click(at: w, from: 0.10)
        XCTAssertEqual(downs(c1).map(\.1), [1])

        let c2 = click(at: w, from: 0.30)
        XCTAssertEqual(downs(c2).map(\.1), [2], "quick second click chains to double")

        let c3 = click(at: w, from: 0.50)
        XCTAssertEqual(downs(c3).map(\.1), [3], "third chains to triple")

        let c4 = click(at: w, from: 0.70)
        XCTAssertEqual(downs(c4).map(\.1), [1], "after a triple the chain restarts")
    }

    func testSlowSecondClickIsSingle() {
        feedFrames([SyntheticHand.openRelaxed()], from: 0, count: 3)
        _ = click(at: Vec2(0.5, 0.7), from: 0.1)
        let c2 = click(at: Vec2(0.5, 0.7), from: 1.5)
        XCTAssertEqual(downs(c2).map(\.1), [1])
    }

    func testSecondClickFarAwayIsSingle() {
        feedFrames([SyntheticHand.openRelaxed(wrist: Vec2(0.3, 0.7))], from: 0, count: 3)
        _ = click(at: Vec2(0.3, 0.7), from: 0.1)
        // Move away, then click quickly: position slop breaks the chain.
        feedFrames([SyntheticHand.openRelaxed(wrist: Vec2(0.7, 0.4))], from: 0.25, count: 3)
        let c2 = click(at: Vec2(0.7, 0.4), from: 0.36)
        XCTAssertEqual(downs(c2).map(\.1), [1])
    }

    // MARK: - Drag / hold

    func testDragWhilePinched() {
        feedFrames([SyntheticHand.openRelaxed(wrist: Vec2(0.4, 0.7))], from: 0, count: 3)
        let down = feedFrames([SyntheticHand.pinchIndex(gap: Self.tightGap, wrist: Vec2(0.4, 0.7))],
                              from: 0.1, count: 3)
        XCTAssertEqual(downs(down).count, 1)

        var dragged: [Vec2] = []
        for i in 1...6 {
            let e = feed([SyntheticHand.pinchIndex(gap: Self.tightGap,
                                                   wrist: Vec2(0.4 + Double(i) * 0.03, 0.7))],
                         at: 0.2 + Double(i) / 30).events
            dragged += drags(e)
            XCTAssertTrue(moves(e).isEmpty, "no plain moves while pinched")
            XCTAssertTrue(ups(e).isEmpty, "the pinch holds while the tips stay together")
        }
        XCTAssertEqual(dragged.count, 6)
        XCTAssertEqual(dragged, dragged.sorted { $0.x < $1.x }, "drag positions advance monotonically")

        let opening = feedFrames([SyntheticHand.openRelaxed(wrist: Vec2(0.58, 0.7))], from: 0.5, count: 3)
        let u = ups(opening)
        XCTAssertEqual(u.count, 1)
        XCTAssertEqual(u[0].0.x, dragged.last!.x, accuracy: 1e-2, "up lands at the drag end")
    }

    func testMicroMovementWhilePinchedDoesNotDrag() {
        feedFrames([SyntheticHand.openRelaxed(wrist: Vec2(0.5, 0.7))], from: 0, count: 3)
        feedFrames([SyntheticHand.pinchIndex(gap: Self.tightGap, wrist: Vec2(0.5, 0.7))],
                   from: 0.1, count: 3)
        let e = feedFrames([SyntheticHand.pinchIndex(gap: Self.tightGap, wrist: Vec2(0.504, 0.7))],
                           from: 0.25, count: 3)
        XCTAssertTrue(drags(e).isEmpty, "sub-threshold wobble must not start a drag")
        let up = feedFrames([SyntheticHand.openRelaxed(wrist: Vec2(0.504, 0.7))], from: 0.4, count: 3)
        XCTAssertEqual(ups(up).count, 1)
    }

    func testHoldNeverTimesOut() {
        feedFrames([SyntheticHand.openRelaxed()], from: 0, count: 3)
        var events = feedFrames([SyntheticHand.pinchIndex(gap: Self.tightGap)], from: 0.1, count: 90) // 3 s
        XCTAssertEqual(downs(events).count, 1)
        XCTAssertTrue(ups(events).isEmpty, "hold must persist indefinitely")
        events = feedFrames([SyntheticHand.openRelaxed()], from: 3.2, count: 3)
        XCTAssertEqual(ups(events).count, 1)
    }

    // MARK: - Hysteresis

    func testHysteresisBandHoldsStateBothWays() {
        // From open: a ratio inside the band must not click…
        feedFrames([SyntheticHand.openRelaxed()], from: 0, count: 4)
        let e1 = feedFrames([SyntheticHand.pinchIndex(gap: Self.bandGap)], from: 0.15, count: 8)
        XCTAssertTrue(downs(e1).isEmpty, "the hysteresis band must not click")

        // …then a real pinch clicks…
        let e2 = feedFrames([SyntheticHand.pinchIndex(gap: Self.tightGap)], from: 0.45, count: 3)
        XCTAssertEqual(downs(e2).count, 1)

        // …and easing back into the band must not release.
        let e3 = feedFrames([SyntheticHand.pinchIndex(gap: Self.bandGap)], from: 0.56, count: 8)
        XCTAssertTrue(ups(e3).isEmpty, "the band must not release a pinch either")

        let e4 = feedFrames([SyntheticHand.openRelaxed()], from: 0.85, count: 3)
        XCTAssertEqual(ups(e4).count, 1)
    }

    // MARK: - Pose tolerance

    func testCasualPinchClicks() {
        // The other three fingers half-curled — how people actually pinch.
        feedFrames([SyntheticHand.openRelaxed()], from: 0, count: 3)
        let e = feedFrames([SyntheticHand.pinchIndexCasual(gap: Self.tightGap)], from: 0.1, count: 3)
        XCTAssertEqual(downs(e).map(\.1), [1], "only thumb + index may gate the click")
        XCTAssertEqual(ups(feedFrames([SyntheticHand.openRelaxed()], from: 0.25, count: 3)).count, 1)
    }

    // MARK: - Tracking loss and robustness

    func testTrackingLossReleasesPinchAfterGrace() {
        feedFrames([SyntheticHand.openRelaxed()], from: 0, count: 3)
        feedFrames([SyntheticHand.pinchIndex(gap: Self.tightGap)], from: 0.1, count: 3)

        XCTAssertTrue(ups(feed([], at: 0.30).events).isEmpty, "grace holds the pinch")
        let e = feed([], at: 0.55).events
        XCTAssertEqual(ups(e).count, 1, "held button must release after tracking loss")
        XCTAssertTrue(ups(feed([], at: 0.7).events).isEmpty, "no repeated releases")
    }

    func testBriefDropoutKeepsDrag() {
        feedFrames([SyntheticHand.openRelaxed(wrist: Vec2(0.4, 0.7))], from: 0, count: 3)
        feedFrames([SyntheticHand.pinchIndex(gap: Self.tightGap, wrist: Vec2(0.4, 0.7))],
                   from: 0.1, count: 3)
        XCTAssertTrue(ups(feed([], at: 0.22).events).isEmpty)
        let e = feed([SyntheticHand.pinchIndex(gap: Self.tightGap, wrist: Vec2(0.5, 0.7))], at: 0.25).events
        XCTAssertTrue(ups(e).isEmpty)
        XCTAssertFalse(drags(e).isEmpty, "drag continues after a one-frame dropout")
    }

    func testLowConfidenceHandIsIgnored() {
        let (events, overlay) = feed([SyntheticHand.openRelaxed(confidence: 0.1)], at: 0)
        XCTAssertTrue(events.isEmpty)
        XCTAssertNil(overlay.cursor)
    }

    func testForceReleaseEmitsUpAndBlocksChaining() {
        feedFrames([SyntheticHand.openRelaxed()], from: 0, count: 3)
        feedFrames([SyntheticHand.pinchIndex(gap: Self.tightGap)], from: 0.1, count: 3)
        let released = engine.forceRelease(at: 0.25)
        XCTAssertEqual(ups(released).count, 1)

        feedFrames([SyntheticHand.openRelaxed()], from: 0.3, count: 2)
        let c = click(at: Vec2(0.5, 0.7), from: 0.4)
        XCTAssertEqual(downs(c).map(\.1), [1], "forced release must not chain")
    }

    // MARK: - Two hands

    func testPrimaryHandIsSticky() {
        feedFrames([SyntheticHand.openRelaxed(wrist: Vec2(0.3, 0.7))], from: 0, count: 3)
        let (_, overlay) = feed(
            [SyntheticHand.openRelaxed(wrist: Vec2(0.3, 0.7)),
             SyntheticHand.openRelaxed(wrist: Vec2(0.75, 0.7))],
            at: 0.2)
        XCTAssertEqual(overlay.hands.count, 2)
        XCTAssertEqual(overlay.hands.filter(\.isPrimary).count, 1)

        // Moving the second hand does not move the cursor.
        let before = overlay.cursor!
        let (events, o2) = feed(
            [SyntheticHand.openRelaxed(wrist: Vec2(0.3, 0.7)),
             SyntheticHand.openRelaxed(wrist: Vec2(0.6, 0.5))],
            at: 0.3)
        XCTAssertTrue(moves(events).isEmpty)
        XCTAssertEqual(o2.cursor!, before)
    }
}
