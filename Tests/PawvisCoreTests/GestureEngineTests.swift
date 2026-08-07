import XCTest
@testable import PawvisCore

final class GestureEngineTests: XCTestCase {
    var engine: GestureEngine!

    /// Test config: identity mapping (no mirror, full box, no auto-reach
    /// drift) and effectively disabled smoothing, so positions are exact and
    /// assertions deterministic. Auto reach gets its own tests, which opt in.
    static func testConfig(_ clickGesture: ClickGesture = .pinch) -> GestureConfig {
        var config = GestureConfig.default
        config.clickGesture = clickGesture
        config.interactionBox = InteractionBox(xMin: 0, xMax: 1, yMin: 0, yMax: 1)
        config.reachMode = .manual
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

    /// Restart the engine in a different click mode.
    private func useMode(_ clickGesture: ClickGesture) {
        engine = GestureEngine(config: Self.testConfig(clickGesture))
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

    private func rightDowns(_ events: [GestureEvent]) -> [(Vec2, Int)] {
        events.compactMap {
            if case .buttonDown(.right, let at, let cc) = $0 { return (at, cc) }
            return nil
        }
    }

    private func rightUps(_ events: [GestureEvent]) -> [(Vec2, Int)] {
        events.compactMap {
            if case .buttonUp(.right, let at, let cc) = $0 { return (at, cc) }
            return nil
        }
    }

    private func rightDrags(_ events: [GestureEvent]) -> [Vec2] {
        events.compactMap {
            if case .drag(.right, let to) = $0 { return to }
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

    /// One left click in `.indexTap` mode: dip the index, then lift it.
    @discardableResult
    private func tapClick(at wrist: Vec2 = Vec2(0.5, 0.7), from: TimeInterval) -> [GestureEvent] {
        feedFrames([SyntheticHand.mouseTap(indexDown: true, wrist: wrist)], from: from, count: 3)
            + feedFrames([SyntheticHand.mouseTap(indexDown: false, wrist: wrist)],
                         from: from + 0.1, count: 3)
    }

    /// One right click: dip the right-click finger, then lift it.
    @discardableResult
    private func rightClick(_ finger: Finger = .little, at wrist: Vec2 = Vec2(0.5, 0.7),
                            from: TimeInterval) -> [GestureEvent] {
        feedFrames([SyntheticHand.fingerDip(finger, wrist: wrist)], from: from, count: 3)
            + feedFrames([SyntheticHand.mouseTap(indexDown: false, wrist: wrist)],
                         from: from + 0.1, count: 3)
    }

    /// Open frames, then a pinch held down. The button goes down on the second
    /// pinched frame (`from + 1/30`), so the tap window closes at `from + 0.33`.
    /// Returns the press point.
    private func beginPinchPress(at wrist: Vec2, from: TimeInterval) -> Vec2 {
        feedFrames([SyntheticHand.openRelaxed(wrist: wrist)], from: from - 0.1, count: 3)
        let pressed = feedFrames([SyntheticHand.pinchIndex(gap: Self.tightGap, wrist: wrist)],
                                 from: from, count: 3)
        return downs(pressed).first!.0
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

    func testTapWindowDefaults() {
        let c = GestureConfig.default
        XCTAssertEqual(c.clickGesture, .indexTap,
                       "the mouse tap keeps the hand open, so tracking never guesses")
        XCTAssertEqual(ClickGesture.allCases.first, .indexTap,
                       "picker order = declaration order = best modes first")
        XCTAssertEqual(c.dragStartDelay, 0.30, accuracy: 1e-9)
        XCTAssertEqual(c.dragIntentDistance, 0.030, accuracy: 1e-9)
        XCTAssertEqual(c.jitterDeadband, 0.004, accuracy: 1e-9)
    }

    func testRightClickAndReachDefaults() {
        let c = GestureConfig.default
        XCTAssertTrue(c.rightClickEnabled)
        XCTAssertEqual(c.rightClickFinger, .little,
                       "the one finger no click mode uses")
        XCTAssertEqual(c.reachMode, .auto,
                       "the box fits itself to the hand unless the user takes the slider")
        XCTAssertEqual(Self.testConfig().reachMode, .manual,
                       "…but the tests pin the box, so mapped positions stay exact")
    }

    func testRightThresholdsAlwaysUseTheDipFactor() {
        var c = GestureConfig.default
        for mode in ClickGesture.allCases {
            c.clickGesture = mode
            XCTAssertEqual(c.rightEngageRatio, 0.675, accuracy: 1e-9,
                           "\(mode): right click is a dip whatever the left button does")
            XCTAssertEqual(c.rightReleaseRatio, 0.755, accuracy: 1e-9)
        }
        c.pinchEngageRatio = 0.50
        XCTAssertEqual(c.rightEngageRatio, 0.75, accuracy: 1e-9,
                       "…and it rides the same sensitivity slider")
    }

    func testModeThresholdsScaleTheSameSlider() {
        var c = GestureConfig.default
        c.clickGesture = .pinch
        XCTAssertEqual(c.engageRatio, 0.45, accuracy: 1e-9)
        XCTAssertEqual(c.releaseRatio, c.pinchReleaseRatio, accuracy: 1e-9, "pinch mode is unchanged")

        c.clickGesture = .wholeHandPinch
        XCTAssertEqual(c.engageRatio, 0.5625, accuracy: 1e-9,
                       "ring and little can't close on the thumb as tightly as the index")
        XCTAssertEqual(c.releaseRatio, 0.6425, accuracy: 1e-9)

        c.clickGesture = .thumbCurl
        XCTAssertEqual(c.engageRatio, 0.36, accuracy: 1e-9,
                       "a tucked thumb sits ~0.30–0.35 of hand scale from the index knuckle")
        XCTAssertEqual(c.releaseRatio, 0.44, accuracy: 1e-9)

        c.clickGesture = .indexTap
        XCTAssertEqual(c.engageRatio, 0.675, accuracy: 1e-9,
                       "the index-tap differential idles near 1.0 and dips on a tap")
        XCTAssertEqual(c.releaseRatio, 0.755, accuracy: 1e-9)
    }

    func testUnreadableClickGestureKeepsTheDefault() throws {
        let bogus = try JSONDecoder().decode(
            GestureConfig.self, from: Data(#"{"clickGesture":"telekinesis"}"#.utf8))
        XCTAssertEqual(bogus.clickGesture, .indexTap,
                       "an unknown mode must not fail the settings tree")
        let known = try JSONDecoder().decode(
            GestureConfig.self, from: Data(#"{"clickGesture":"thumbCurl"}"#.utf8))
        XCTAssertEqual(known.clickGesture, .thumbCurl)
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

        // Past the tap window, so the ordinary dragActivationDistance rule runs.
        var dragged: [Vec2] = []
        for i in 1...6 {
            let e = feed([SyntheticHand.pinchIndex(gap: Self.tightGap,
                                                   wrist: Vec2(0.4 + Double(i) * 0.03, 0.7))],
                         at: 0.5 + Double(i) / 30).events
            dragged += drags(e)
            XCTAssertTrue(moves(e).isEmpty, "no plain moves while pinched")
            XCTAssertTrue(ups(e).isEmpty, "the pinch holds while the tips stay together")
        }
        XCTAssertEqual(dragged.count, 6)
        XCTAssertEqual(dragged, dragged.sorted { $0.x < $1.x }, "drag positions advance monotonically")

        let opening = feedFrames([SyntheticHand.openRelaxed(wrist: Vec2(0.58, 0.7))], from: 0.8, count: 3)
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

    // MARK: - Tap window (click vs grab)

    func testQuickClickWithWobbleStaysAClick() {
        let downAt = beginPinchPress(at: Vec2(0.5, 0.7), from: 0.1) // down at t = 0.133
        // 0.015 of press wobble: past dragActivationDistance (0.010), short of
        // dragIntentDistance (0.030) — the shake of a hand closing, not a drag.
        let wobbled = SyntheticHand.pinchIndex(gap: Self.tightGap, wrist: Vec2(0.515, 0.7))
        XCTAssertTrue(drags(feedFrames([wobbled], from: 0.2, count: 3)).isEmpty,
                      "wobble inside the tap window must not drag")

        // Release 0.2 s after the down — still inside the 0.30 s window.
        let opening = feedFrames([SyntheticHand.openRelaxed(wrist: Vec2(0.515, 0.7))],
                                 from: 0.3333, count: 3)
        XCTAssertTrue(drags(opening).isEmpty)
        XCTAssertEqual(ups(opening).count, 1)
        XCTAssertEqual(ups(opening)[0].0, downAt, "the up lands exactly on the press point")
    }

    func testHoldingPastTheTapWindowLetsWobbleDrag() {
        let downAt = beginPinchPress(at: Vec2(0.5, 0.7), from: 0.1)
        let wobbled = SyntheticHand.pinchIndex(gap: Self.tightGap, wrist: Vec2(0.515, 0.7))
        XCTAssertTrue(drags(feedFrames([wobbled], from: 0.2, count: 3)).isEmpty)

        // Same offset once the window has expired: the ordinary activation
        // distance applies, so the held pinch becomes a grab.
        let after = feedFrames([wobbled], from: 0.5, count: 2)
        XCTAssertEqual(drags(after).count, 1, "one drag to the wobbled point, then it holds still")

        let moved = feedFrames([SyntheticHand.pinchIndex(gap: Self.tightGap, wrist: Vec2(0.565, 0.7))],
                               from: 0.6, count: 2)
        XCTAssertEqual(drags(moved).count, 1)
        XCTAssertEqual(drags(moved)[0].x - downAt.x, 0.065, accuracy: 1e-3)
    }

    func testDeliberateFlickInsideTapWindowDragsImmediately() {
        let downAt = beginPinchPress(at: Vec2(0.5, 0.7), from: 0.1)
        let flicked = SyntheticHand.pinchIndex(gap: Self.tightGap, wrist: Vec2(0.55, 0.7))
        let d = drags(feed([flicked], at: 0.2).events)
        XCTAssertEqual(d.count, 1, "0.05 of travel is unmistakably a drag, window or not")
        XCTAssertEqual(d[0].distance(to: flicked[.thumbTip]!.midpoint(with: flicked[.indexTip]!)),
                       0, accuracy: 1e-6, "and it tracks the hand from the first frame")
        XCTAssertEqual(d[0].x - downAt.x, 0.05, accuracy: 1e-3)
    }

    // MARK: - Jitter deadband

    func testJitterDeadbandSuppressesShimmerWhileDragging() {
        _ = beginPinchPress(at: Vec2(0.5, 0.7), from: 0.1)
        let started = feed([SyntheticHand.pinchIndex(gap: Self.tightGap, wrist: Vec2(0.55, 0.7))],
                           at: 0.5).events
        XCTAssertEqual(drags(started).count, 1)

        // Vision shivering the overlapped tips ±0.002 around a held position.
        var shimmer: [Vec2] = []
        for i in 0..<6 {
            let x = 0.55 + (i.isMultiple(of: 2) ? 0.002 : 0)
            shimmer += drags(feed([SyntheticHand.pinchIndex(gap: Self.tightGap, wrist: Vec2(x, 0.7))],
                                  at: 0.6 + Double(i) / 30).events)
        }
        XCTAssertTrue(shimmer.isEmpty, "sub-deadband shiver must not re-emit drags")

        // Real motion at 0.006 a frame flows through untouched.
        var real: [Vec2] = []
        for i in 1...4 {
            real += drags(feed([SyntheticHand.pinchIndex(gap: Self.tightGap,
                                                         wrist: Vec2(0.55 + Double(i) * 0.006, 0.7))],
                               at: 0.9 + Double(i) / 30).events)
        }
        XCTAssertEqual(real.count, 4)
    }

    func testHalfDeadbandSuppressesStationaryShimmerOnMoves() {
        feedFrames([SyntheticHand.openRelaxed(wrist: Vec2(0.5, 0.7))], from: 0, count: 2)
        let tiny = feed([SyntheticHand.openRelaxed(wrist: Vec2(0.501, 0.7))], at: 0.1).events
        XCTAssertTrue(moves(tiny).isEmpty, "0.001 of shimmer must not move the cursor")
        let real = feed([SyntheticHand.openRelaxed(wrist: Vec2(0.503, 0.7))], at: 0.15).events
        XCTAssertEqual(moves(real).count, 1, "0.003 of travel still moves it")
    }

    // MARK: - Engage-side confidence gate

    func testFaintTipsNeverEngage() {
        feedFrames([SyntheticHand.openRelaxed()], from: 0, count: 3)
        var faint = SyntheticHand.pinchIndex(gap: Self.tightGap)
        for tip in [HandJoint.thumbTip, .indexTip] {
            faint.setPoint(faint[tip]!, for: tip, confidence: 0.30)
        }
        // 0.30 clears minJointConfidence (0.25), so the ratio is there and the
        // ring reads closed — only the engage floor (0.40) blocks the click.
        let e = feedFrames([faint], from: 0.1, count: 20)
        XCTAssertTrue(downs(e).isEmpty, "phantom-prone frames must never click, however many arrive")
        let (_, overlay) = feed([faint], at: 0.85)
        XCTAssertEqual(overlay.closingProgress, 1, accuracy: 1e-9)
        XCTAssertFalse(overlay.grabbed)

        // The same pose tracked confidently clicks on the usual debounce.
        var solid = SyntheticHand.pinchIndex(gap: Self.tightGap)
        for tip in [HandJoint.thumbTip, .indexTip] {
            solid.setPoint(solid[tip]!, for: tip, confidence: 0.9)
        }
        XCTAssertEqual(downs(feedFrames([solid], from: 0.9, count: 3)).map(\.1), [1])
    }

    func testFaintTipsStillRelease() {
        feedFrames([SyntheticHand.openRelaxed()], from: 0, count: 3)
        XCTAssertEqual(downs(feedFrames([SyntheticHand.pinchIndex(gap: Self.tightGap)],
                                        from: 0.1, count: 3)).count, 1)

        // Confidence usually sags exactly as the hand opens; releasing must
        // never be the harder direction or the button sticks.
        var faintOpen = SyntheticHand.openRelaxed()
        for tip in [HandJoint.thumbTip, .indexTip] {
            faintOpen.setPoint(faintOpen[tip]!, for: tip, confidence: 0.30)
        }
        XCTAssertEqual(ups(feedFrames([faintOpen], from: 0.25, count: 3)).count, 1)
    }

    func testWholeHandGateOnlyChecksTheTipsItAveraged() {
        useMode(.wholeHandPinch)
        feedFrames([SyntheticHand.openRelaxed()], from: 0, count: 3)

        // A ring tip Vision half-believes: it feeds the mean, so it gates.
        var shaky = SyntheticHand.wholeHandPinch(gap: 0.3)
        shaky.setPoint(shaky[.ringTip]!, for: .ringTip, confidence: 0.30)
        XCTAssertTrue(downs(feedFrames([shaky], from: 0.1, count: 8)).isEmpty)

        // Dropped entirely, it is out of the mean and out of the gate: the
        // three remaining tips are confident, so the click stands.
        var occluded = SyntheticHand.wholeHandPinch(gap: 0.3)
        occluded.setPoint(occluded[.ringTip]!, for: .ringTip, confidence: 0.1)
        XCTAssertEqual(downs(feedFrames([occluded], from: 0.5, count: 3)).map(\.1), [1])
    }

    // MARK: - Whole-hand pinch mode

    func testWholeHandPinchClicksAndReleases() {
        useMode(.wholeHandPinch)
        feedFrames([SyntheticHand.openRelaxed()], from: 0, count: 3)
        let closing = feedFrames([SyntheticHand.wholeHandPinch(gap: 0.3)], from: 0.1, count: 3)
        XCTAssertEqual(downs(closing).map(\.1), [1])
        XCTAssertEqual(ups(feedFrames([SyntheticHand.openRelaxed()], from: 0.5, count: 3)).count, 1)
    }

    func testPlainPinchDoesNotClickInWholeHandMode() {
        useMode(.wholeHandPinch)
        feedFrames([SyntheticHand.openRelaxed()], from: 0, count: 3)
        let e = feedFrames([SyntheticHand.pinchIndex(gap: Self.tightGap)], from: 0.1, count: 10)
        XCTAssertTrue(downs(e).isEmpty, "three idle fingers keep the mean above the threshold")
    }

    // MARK: - Index-tap (mouse) mode

    func testIndexTapClicksAndReleasesOnThePalm() {
        useMode(.indexTap)
        feedFrames([SyntheticHand.mouseTap(indexDown: false)], from: 0, count: 4)

        let tapping = feedFrames([SyntheticHand.mouseTap(indexDown: true)], from: 0.15, count: 3)
        let d = downs(tapping)
        XCTAssertEqual(d.count, 1, "dipping the index finger clicks")

        // Lifting the finger releases; the palm-anchored cursor never moved,
        // so the up lands exactly on the down.
        let lifting = feedFrames([SyntheticHand.mouseTap(indexDown: false)], from: 0.28, count: 3)
        XCTAssertTrue(drags(lifting).isEmpty)
        let u = ups(lifting)
        XCTAssertEqual(u.count, 1)
        XCTAssertEqual(u[0].0.distance(to: d[0].0), 0, accuracy: 1e-9)
    }

    func testIndexTapHoldDragsWithThePalm() {
        useMode(.indexTap)
        feedFrames([SyntheticHand.mouseTap(indexDown: false, wrist: Vec2(0.4, 0.7))], from: 0, count: 4)
        feedFrames([SyntheticHand.mouseTap(indexDown: true, wrist: Vec2(0.4, 0.7))], from: 0.15, count: 3)

        // Hold the finger down past the tap window, then move the hand.
        feedFrames([SyntheticHand.mouseTap(indexDown: true, wrist: Vec2(0.4, 0.7))], from: 0.28, count: 8)
        var dragged: [Vec2] = []
        for i in 1...5 {
            let e = feed([SyntheticHand.mouseTap(indexDown: true, wrist: Vec2(0.4 + Double(i) * 0.03, 0.7))],
                         at: 0.56 + Double(i) / 30).events
            dragged += drags(e)
        }
        XCTAssertGreaterThanOrEqual(dragged.count, 4, "held finger + hand movement drags")
    }

    func testWholeHandTiltDoesNotIndexTap() {
        // Curling every finger (or pitching the whole hand forward) shortens
        // the index AND middle extents together — the differential stays flat,
        // so no click. Only the index moving relative to its neighbor taps.
        useMode(.indexTap)
        feedFrames([SyntheticHand.mouseTap(indexDown: false)], from: 0, count: 4)
        let e = feedFrames([SyntheticHand.fist()], from: 0.15, count: 6)
        XCTAssertTrue(downs(e).isEmpty, "whole-hand curl must not read as an index tap")
    }

    func testIndexTapBandHoldsBothWays() {
        useMode(.indexTap)
        // Half-dipped from open: no click.
        feedFrames([SyntheticHand.mouseTap(indexDown: false)], from: 0, count: 4)
        let e1 = feedFrames([SyntheticHand.mouseTapHalf()], from: 0.15, count: 8)
        XCTAssertTrue(downs(e1).isEmpty, "a half-dip sits in the hysteresis band")

        // Full dip clicks; returning to half-dip must not release.
        feedFrames([SyntheticHand.mouseTap(indexDown: true)], from: 0.45, count: 3)
        let e2 = feedFrames([SyntheticHand.mouseTapHalf()], from: 0.56, count: 8)
        XCTAssertTrue(ups(e2).isEmpty, "the band must not release a held tap")
        let e3 = feedFrames([SyntheticHand.mouseTap(indexDown: false)], from: 0.85, count: 3)
        XCTAssertEqual(ups(e3).count, 1)
    }

    func testWholeHandPointerIsThePalm() {
        // The palm is the only part of the hand that holds still through a
        // whole-hand gather AND its release — a fingertip centroid shifted
        // ~0.08 when the hand reopened, smearing every click into a drag.
        useMode(.wholeHandPinch)
        let hand = SyntheticHand.wholeHandPinch(gap: 0.3)
        let events = feed([hand], at: 0).events
        let expected = hand[.wrist]!.midpoint(with: hand[.middleMCP]!)
        XCTAssertEqual(moves(events).count, 1)
        XCTAssertEqual(moves(events)[0].distance(to: expected), 0, accuracy: 1e-6)
    }

    func testWholeHandClickDoesNotDragOnRelease() {
        useMode(.wholeHandPinch)
        feedFrames([SyntheticHand.openRelaxed()], from: 0, count: 4)
        let closing = feedFrames([SyntheticHand.wholeHandPinch(gap: 0.3)], from: 0.15, count: 3)
        let d = downs(closing)
        XCTAssertEqual(d.count, 1)

        // Opening the hand spreads the fingertips far apart; the palm-anchored
        // cursor must not budge, so the up lands exactly on the down.
        let opening = feedFrames([SyntheticHand.openRelaxed()], from: 0.28, count: 3)
        XCTAssertTrue(drags(opening).isEmpty, "release motion must not smear into a drag")
        let u = ups(opening)
        XCTAssertEqual(u.count, 1)
        XCTAssertEqual(u[0].0.distance(to: d[0].0), 0, accuracy: 1e-9)
    }

    // MARK: - Thumb-curl mode

    func testThumbCurlCursorFollowsThePalmAndIgnoresTheThumb() {
        useMode(.thumbCurl)
        let opening = feed([SyntheticHand.highFive(thumbTucked: false, wrist: Vec2(0.5, 0.7))],
                           at: 0).events
        XCTAssertEqual(moves(opening).count, 1)
        let start = moves(opening)[0]

        // Waggle the thumb: the finger that clicks must not steer the cursor.
        for (i, offset) in [Vec2(0.06, 0.05), Vec2(-0.05, 0.04), Vec2(0.02, -0.06)].enumerated() {
            let waggled = SyntheticHand.build(
                pose: .init(fingerDirs: SyntheticHand.relaxedDirs,
                            thumbTipOffset: SyntheticHand.thumbExtendedOffset + offset),
                wrist: Vec2(0.5, 0.7))
            let e = feed([waggled], at: 0.1 + Double(i) / 30).events
            XCTAssertTrue(moves(e).isEmpty, "thumb travel must not move the cursor")
            XCTAssertTrue(downs(e).isEmpty, "…nor click short of a real tuck")
        }

        let palmMoved = feed([SyntheticHand.highFive(thumbTucked: false, wrist: Vec2(0.6, 0.7))],
                             at: 0.3).events
        XCTAssertEqual(moves(palmMoved).count, 1)
        XCTAssertEqual(moves(palmMoved)[0].x - start.x, 0.1, accuracy: 1e-6)
    }

    func testThumbCurlClicksWhenTucked() {
        useMode(.thumbCurl)
        feedFrames([SyntheticHand.highFive(thumbTucked: false)], from: 0, count: 3)
        let closing = feedFrames([SyntheticHand.highFive(thumbTucked: true)], from: 0.1, count: 3)
        XCTAssertEqual(downs(closing).map(\.1), [1])
        XCTAssertTrue(drags(closing).isEmpty, "tucking the thumb must not move the cursor")

        let opening = feedFrames([SyntheticHand.highFive(thumbTucked: false)], from: 0.5, count: 3)
        XCTAssertEqual(ups(opening).count, 1)
        XCTAssertEqual(ups(opening)[0].0, downs(closing)[0].0,
                       "palm pointer: the whole click happens in one spot")
    }

    func testThumbCurlDragsWithThePalm() {
        useMode(.thumbCurl)
        feedFrames([SyntheticHand.highFive(thumbTucked: false, wrist: Vec2(0.4, 0.7))],
                   from: 0, count: 3)
        XCTAssertEqual(downs(feedFrames([SyntheticHand.highFive(thumbTucked: true, wrist: Vec2(0.4, 0.7))],
                                        from: 0.1, count: 3)).count, 1)

        var dragged: [Vec2] = []
        for i in 1...4 {
            dragged += drags(feed([SyntheticHand.highFive(thumbTucked: true,
                                                          wrist: Vec2(0.4 + Double(i) * 0.03, 0.7))],
                                  at: 0.5 + Double(i) / 30).events)
        }
        XCTAssertEqual(dragged.count, 4)
        XCTAssertEqual(dragged, dragged.sorted { $0.x < $1.x }, "drag positions advance monotonically")

        let opening = feedFrames([SyntheticHand.highFive(thumbTucked: false, wrist: Vec2(0.52, 0.7))],
                                 from: 0.8, count: 3)
        XCTAssertEqual(ups(opening).count, 1)
        XCTAssertEqual(ups(opening)[0].0.x, dragged.last!.x, accuracy: 1e-6,
                       "up lands on the last emitted drag")
    }

    // MARK: - Mode switching

    func testSwitchingClickGestureMidPressReleases() {
        feedFrames([SyntheticHand.openRelaxed()], from: 0, count: 3)
        let down = feedFrames([SyntheticHand.pinchIndex(gap: Self.tightGap)], from: 0.1, count: 3)
        XCTAssertEqual(downs(down).count, 1)

        engine.config.clickGesture = .thumbCurl

        let (events, overlay) = feed([SyntheticHand.highFive(thumbTucked: false)], at: 0.25)
        XCTAssertEqual(ups(events).count, 1, "a mode switch must not strand the button down")
        XCTAssertEqual(ups(events)[0].0, downs(down)[0].0)
        XCTAssertFalse(overlay.grabbed)
        XCTAssertTrue(ups(feedFrames([SyntheticHand.highFive(thumbTucked: false)],
                                     from: 0.3, count: 3)).isEmpty, "…and only once")
    }

    func testSwitchingClickGestureWhileOpenEmitsNothing() {
        feedFrames([SyntheticHand.openRelaxed()], from: 0, count: 3)
        engine.config.clickGesture = .wholeHandPinch
        let events = feed([SyntheticHand.openRelaxed()], at: 0.2).events
        XCTAssertTrue(ups(events).isEmpty)
        XCTAssertTrue(downs(events).isEmpty)
    }

    // MARK: - Closing ring

    func testClosingProgressRisesInEveryMode() {
        let (_, wide) = feed([SyntheticHand.pinchIndex(gap: Self.openGap)], at: 0)
        let (_, near) = feed([SyntheticHand.pinchIndex(gap: 0.6)], at: 1 / 30.0)
        XCTAssertGreaterThan(near.closingProgress, wide.closingProgress)

        useMode(.wholeHandPinch)
        let (_, apart) = feed([SyntheticHand.wholeHandPinch(gap: 1.2)], at: 0)
        let (_, gathering) = feed([SyntheticHand.wholeHandPinch(gap: 0.7)], at: 1 / 30.0)
        XCTAssertGreaterThan(gathering.closingProgress, apart.closingProgress)
        XCTAssertLessThan(gathering.closingProgress, 1, "…without filling before the click")

        useMode(.thumbCurl)
        let (_, out) = feed([SyntheticHand.highFive(thumbTucked: false)], at: 0)
        let halfway = SyntheticHand.build(
            pose: .init(fingerDirs: SyntheticHand.relaxedDirs,
                        thumbTipOffset: SyntheticHand.thumbExtendedOffset
                            .lerp(to: SyntheticHand.thumbTuckedOffset, t: 0.5)))
        let (_, tucking) = feed([halfway], at: 1 / 30.0)
        XCTAssertGreaterThan(tucking.closingProgress, out.closingProgress)
        XCTAssertLessThan(tucking.closingProgress, 1)
    }

    // MARK: - Right click

    func testPinkyDipRightClicksInMouseTapMode() {
        useMode(.indexTap)
        feedFrames([SyntheticHand.mouseTap(indexDown: false)], from: 0, count: 4)

        let dipping = feedFrames([SyntheticHand.fingerDip(.little)], from: 0.15, count: 3)
        let d = rightDowns(dipping)
        XCTAssertEqual(d.count, 1, "dipping the pinky presses the right button")
        XCTAssertEqual(d[0].1, 1)
        XCTAssertTrue(downs(dipping).isEmpty, "…and the left button stays out of it")

        // The palm-anchored cursor never moved, so the up lands on the down.
        let lifting = feedFrames([SyntheticHand.mouseTap(indexDown: false)], from: 0.28, count: 3)
        XCTAssertTrue(rightDrags(lifting).isEmpty)
        let u = rightUps(lifting)
        XCTAssertEqual(u.count, 1)
        XCTAssertEqual(u[0].0.distance(to: d[0].0), 0, accuracy: 1e-9)
        XCTAssertTrue(ups(lifting).isEmpty)
    }

    func testOnlyOneButtonIsEverPressed() {
        useMode(.indexTap)
        let bothDipped = SyntheticHand.build(
            pose: .init(fingerDirs: SyntheticHand.relaxedDirs,
                        curled: [.index, .little],
                        thumbTipOffset: SyntheticHand.thumbExtendedOffset))

        // Right first: dipping the index as well must not add a left press.
        feedFrames([SyntheticHand.mouseTap(indexDown: false)], from: 0, count: 3)
        XCTAssertEqual(rightDowns(feedFrames([SyntheticHand.fingerDip(.little)],
                                             from: 0.1, count: 3)).count, 1)
        let whileRight = feedFrames([bothDipped], from: 0.25, count: 10)
        XCTAssertTrue(downs(whileRight).isEmpty,
                      "a held right button blocks the left engage outright — no frames accumulate")
        XCTAssertTrue(rightUps(whileRight).isEmpty, "…and the right press is undisturbed")

        let opened = feedFrames([SyntheticHand.mouseTap(indexDown: false)], from: 0.6, count: 3)
        XCTAssertEqual(rightUps(opened).count, 1)
        XCTAssertTrue(ups(opened).isEmpty, "the blocked left button has nothing to release")

        // Left first: the same pose must not add a right press.
        XCTAssertEqual(downs(feedFrames([SyntheticHand.mouseTap(indexDown: true)],
                                        from: 0.8, count: 3)).count, 1)
        let whileLeft = feedFrames([bothDipped], from: 0.95, count: 10)
        XCTAssertTrue(rightDowns(whileLeft).isEmpty, "…and it holds symmetrically the other way")
        XCTAssertTrue(ups(whileLeft).isEmpty)
    }

    func testRightDragWithThePalm() {
        useMode(.indexTap)
        let start = Vec2(0.4, 0.7)
        feedFrames([SyntheticHand.mouseTap(indexDown: false, wrist: start)], from: 0, count: 4)
        feedFrames([SyntheticHand.fingerDip(.little, wrist: start)], from: 0.15, count: 3)

        // Hold the dip past the tap window, then move the hand.
        feedFrames([SyntheticHand.fingerDip(.little, wrist: start)], from: 0.28, count: 8)
        var dragged: [Vec2] = []
        for i in 1...5 {
            let e = feed([SyntheticHand.fingerDip(.little, wrist: Vec2(0.4 + Double(i) * 0.03, 0.7))],
                         at: 0.56 + Double(i) / 30).events
            dragged += rightDrags(e)
            XCTAssertTrue(drags(e).isEmpty, "a right-button drag must not masquerade as a left one")
        }
        XCTAssertGreaterThanOrEqual(dragged.count, 4, "held dip + hand movement drags")
        XCTAssertEqual(dragged, dragged.sorted { $0.x < $1.x }, "drag positions advance monotonically")

        let opening = feedFrames([SyntheticHand.mouseTap(indexDown: false, wrist: Vec2(0.55, 0.7))],
                                 from: 0.8, count: 3)
        XCTAssertEqual(rightUps(opening).count, 1)
        XCTAssertEqual(rightUps(opening)[0].0.x, dragged.last!.x, accuracy: 1e-6,
                       "up lands on the last emitted drag")
    }

    func testRightClicksNeverChain() {
        useMode(.indexTap)
        feedFrames([SyntheticHand.mouseTap(indexDown: false)], from: 0, count: 3)
        XCTAssertEqual(rightDowns(rightClick(from: 0.10)).map(\.1), [1])
        XCTAssertEqual(rightDowns(rightClick(from: 0.30)).map(\.1), [1],
                       "a right click is always a single, however fast it repeats")
    }

    func testRightClickLeavesTheDoubleClickChainAlone() {
        useMode(.indexTap)
        feedFrames([SyntheticHand.mouseTap(indexDown: false)], from: 0, count: 3)
        XCTAssertEqual(downs(tapClick(from: 0.10)).map(\.1), [1])
        XCTAssertEqual(rightDowns(rightClick(from: 0.28)).map(\.1), [1])
        XCTAssertEqual(downs(tapClick(from: 0.46)).map(\.1), [2],
                       "the right click neither chained into the double nor broke it")
    }

    func testThumbCurlModeAlsoRightClicks() {
        useMode(.thumbCurl)
        feedFrames([SyntheticHand.highFive(thumbTucked: false)], from: 0, count: 3)

        // The left button is unchanged: tuck the thumb.
        XCTAssertEqual(downs(feedFrames([SyntheticHand.highFive(thumbTucked: true)],
                                        from: 0.1, count: 3)).map(\.1), [1])
        XCTAssertEqual(ups(feedFrames([SyntheticHand.highFive(thumbTucked: false)],
                                      from: 0.25, count: 3)).count, 1)

        // The pinky dips for the right button, thumb still out.
        let dipping = feedFrames([SyntheticHand.fingerDip(.little)], from: 0.45, count: 3)
        XCTAssertEqual(rightDowns(dipping).map(\.1), [1])
        XCTAssertTrue(downs(dipping).isEmpty, "an extended thumb is not a click")
        XCTAssertEqual(rightUps(feedFrames([SyntheticHand.highFive(thumbTucked: false)],
                                           from: 0.6, count: 3)).count, 1)
    }

    func testGatheringModesHaveNoRightClick() {
        for mode in [ClickGesture.wholeHandPinch, .pinch] {
            useMode(mode)
            feedFrames([SyntheticHand.openRelaxed()], from: 0, count: 3)
            let e = feedFrames([SyntheticHand.fingerDip(.little)], from: 0.1, count: 10)
            XCTAssertTrue(rightDowns(e).isEmpty,
                          "\(mode): a mode that gathers the fingers can't read a dip apart from its own click")
            XCTAssertTrue(downs(e).isEmpty)
        }
    }

    func testRightClickCanBeTurnedOff() {
        var config = Self.testConfig(.indexTap)
        config.rightClickEnabled = false
        engine = GestureEngine(config: config)
        feedFrames([SyntheticHand.mouseTap(indexDown: false)], from: 0, count: 3)
        let e = feedFrames([SyntheticHand.fingerDip(.little)], from: 0.1, count: 10)
        XCTAssertTrue(rightDowns(e).isEmpty)
        XCTAssertTrue(downs(e).isEmpty)
    }

    func testRightClickFingerCannotAlsoBeTheLeftClickFinger() {
        var config = Self.testConfig(.indexTap)
        config.rightClickFinger = .index
        engine = GestureEngine(config: config)
        feedFrames([SyntheticHand.mouseTap(indexDown: false)], from: 0, count: 3)
        let e = feedFrames([SyntheticHand.mouseTap(indexDown: true)], from: 0.1, count: 3)
        XCTAssertTrue(rightDowns(e).isEmpty, "the index already presses the left button")
        XCTAssertEqual(downs(e).map(\.1), [1], "…and it still does")
    }

    func testRingFingerRightClickWhenConfigured() {
        var config = Self.testConfig(.indexTap)
        config.rightClickFinger = .ring
        engine = GestureEngine(config: config)
        feedFrames([SyntheticHand.mouseTap(indexDown: false)], from: 0, count: 3)
        XCTAssertEqual(rightDowns(feedFrames([SyntheticHand.fingerDip(.ring)],
                                             from: 0.1, count: 3)).map(\.1), [1])
        XCTAssertEqual(rightUps(feedFrames([SyntheticHand.mouseTap(indexDown: false)],
                                           from: 0.3, count: 3)).count, 1)
        // …and the pinky no longer does anything.
        XCTAssertTrue(rightDowns(feedFrames([SyntheticHand.fingerDip(.little)],
                                            from: 0.5, count: 10)).isEmpty)
    }

    func testFaintDipJointsNeverRightClick() {
        useMode(.indexTap)
        feedFrames([SyntheticHand.mouseTap(indexDown: false)], from: 0, count: 3)

        var faint = SyntheticHand.fingerDip(.little)
        for joint in [HandJoint.littleTip, .littleMCP, .ringTip, .ringMCP] {
            faint.setPoint(faint[joint]!, for: joint, confidence: 0.30)
        }
        // 0.30 clears minJointConfidence (0.25), so the differential exists and
        // reads dipped — only the engage floor (0.40) holds the press back.
        XCTAssertTrue(rightDowns(feedFrames([faint], from: 0.1, count: 20)).isEmpty,
                      "the right button gets the same phantom-click gate as the left")

        // Tracked confidently, the same pose clicks on the usual debounce.
        XCTAssertEqual(rightDowns(feedFrames([SyntheticHand.fingerDip(.little)],
                                             from: 0.9, count: 3)).map(\.1), [1])
    }

    func testOverlayReportsTheTwoButtonsSeparately() {
        useMode(.indexTap)
        feedFrames([SyntheticHand.mouseTap(indexDown: false)], from: 0, count: 3)
        feedFrames([SyntheticHand.fingerDip(.little)], from: 0.1, count: 2)
        let (_, held) = feed([SyntheticHand.fingerDip(.little)], at: 0.2)
        XCTAssertTrue(held.rightGrabbed)
        XCTAssertFalse(held.grabbed, "`grabbed` stays left-only")
        XCTAssertEqual(held.closingProgress, 1, accuracy: 1e-9,
                       "the ring fills for whichever button is down")

        feedFrames([SyntheticHand.mouseTap(indexDown: false)], from: 0.3, count: 2) // release debounce
        let (_, lifted) = feed([SyntheticHand.mouseTap(indexDown: false)], at: 0.4)
        XCTAssertFalse(lifted.rightGrabbed)
        XCTAssertFalse(lifted.grabbed)
        XCTAssertLessThan(lifted.closingProgress, 0.05, "…and the ring drops back to resting")
    }

    func testChangingTheRightClickFingerMidPressReleasesIt() {
        useMode(.indexTap)
        feedFrames([SyntheticHand.mouseTap(indexDown: false)], from: 0, count: 3)
        let down = feedFrames([SyntheticHand.fingerDip(.little)], from: 0.1, count: 3)
        XCTAssertEqual(rightDowns(down).count, 1)

        engine.config.rightClickFinger = .ring

        let (events, overlay) = feed([SyntheticHand.fingerDip(.little)], at: 0.25)
        XCTAssertEqual(rightUps(events).count, 1, "the finger holding the button changed under it")
        XCTAssertEqual(rightUps(events)[0].0, rightDowns(down)[0].0)
        XCTAssertFalse(overlay.rightGrabbed)
        XCTAssertTrue(rightUps(feedFrames([SyntheticHand.fingerDip(.little)],
                                          from: 0.3, count: 3)).isEmpty, "…and only once")
    }

    func testDisablingRightClickMidPressReleasesIt() {
        useMode(.indexTap)
        feedFrames([SyntheticHand.mouseTap(indexDown: false)], from: 0, count: 3)
        XCTAssertEqual(rightDowns(feedFrames([SyntheticHand.fingerDip(.little)],
                                             from: 0.1, count: 3)).count, 1)

        engine.config.rightClickEnabled = false

        XCTAssertEqual(rightUps(feed([SyntheticHand.fingerDip(.little)], at: 0.25).events).count, 1)
        XCTAssertTrue(rightDowns(feedFrames([SyntheticHand.fingerDip(.little)],
                                            from: 0.3, count: 6)).isEmpty)
    }

    // MARK: - Auto reach

    /// The test config with auto reach turned back on (it starts from the
    /// identity box, so every drift is visible).
    private func useAutoReach(_ clickGesture: ClickGesture = .indexTap) {
        var config = Self.testConfig(clickGesture)
        config.reachMode = .auto
        engine = GestureEngine(config: config)
    }

    func testAutoTargetMatchesTheTunedDefaultsAtATypicalHandSize() {
        // Deliberate continuity: at the hand size a laptop webcam usually
        // sees, fitting the box reproduces the hand-tuned margins.
        let box = GestureEngine.targetBox(forHandScale: 0.15)
        XCTAssertEqual(box.xMin, 0.14, accuracy: 1e-9)
        XCTAssertEqual(box.xMax, 0.86, accuracy: 1e-9)
        XCTAssertEqual(box.yMin, 0.2525, accuracy: 1e-9)
        XCTAssertEqual(box.yMax, 0.875, accuracy: 1e-9)
    }

    func testAutoReachWidensForALargeHand() {
        useAutoReach()
        // Scale 0.28 with the wrist low enough that every joint stays in frame.
        feedFrames([SyntheticHand.openRelaxed(wrist: Vec2(0.5, 0.8), scale: 0.28)], from: 0, count: 150)
        let box = engine.effectiveInteractionBox
        XCTAssertEqual(box.yMin, 0.428, accuracy: 0.02, "1.35 hand scales of headroom for the fingers")
        XCTAssertEqual(box.xMin, 0.218, accuracy: 0.02)
        XCTAssertEqual(box.xMax, 1 - box.xMin, accuracy: 1e-9, "the box stays centred")
        XCTAssertEqual(box.yMax, 0.81, accuracy: 0.02)
    }

    func testAutoReachTightensForASmallHand() {
        useAutoReach()
        feedFrames([SyntheticHand.openRelaxed(wrist: Vec2(0.5, 0.7), scale: 0.10)], from: 0, count: 150)
        XCTAssertEqual(engine.effectiveInteractionBox.yMin, 0.185, accuracy: 0.02,
                       "a distant hand needs the screen edges within reach")
    }

    func testLosingTheHandForgetsItsMeasuredSize() {
        useAutoReach()
        feedFrames([SyntheticHand.openRelaxed(wrist: Vec2(0.5, 0.8), scale: 0.28)], from: 0, count: 20)
        XCTAssertEqual(engine.smoothedHandScale!, 0.28, accuracy: 1e-6)

        feed([], at: 1.0) // past the tracking-loss grace: the hand is really gone
        XCTAssertNil(engine.smoothedHandScale)

        // The next hand sizes the box from its own scale, not the old one's.
        feedFrames([SyntheticHand.openRelaxed(wrist: Vec2(0.5, 0.7), scale: 0.10)], from: 1.1, count: 150)
        XCTAssertEqual(engine.smoothedHandScale!, 0.10, accuracy: 1e-6)
        XCTAssertEqual(engine.effectiveInteractionBox.yMin, 0.185, accuracy: 0.02)
    }

    func testAutoReachNeverMovesTheBoxMidPress() {
        useAutoReach()
        let wrist = Vec2(0.5, 0.8)
        feedFrames([SyntheticHand.openRelaxed(wrist: wrist, scale: 0.28)], from: 0, count: 10)
        let drifting = engine.effectiveInteractionBox
        XCTAssertGreaterThan(drifting.yMin, 0, "the box has started drifting toward the hand")
        XCTAssertLessThan(drifting.yMin, 0.40, "…and is nowhere near finished")

        feedFrames([SyntheticHand.mouseTap(indexDown: true, wrist: wrist, scale: 0.28)],
                   from: 0.4, count: 3)
        let pressed = engine.effectiveInteractionBox
        feedFrames([SyntheticHand.mouseTap(indexDown: true, wrist: wrist, scale: 0.28)],
                   from: 0.6, count: 60)
        XCTAssertEqual(engine.effectiveInteractionBox, pressed,
                       "a box change remaps the cursor, so it must never move under a held button")

        // Released, the drift picks up again.
        feedFrames([SyntheticHand.openRelaxed(wrist: wrist, scale: 0.28)], from: 2.8, count: 10)
        XCTAssertGreaterThan(engine.effectiveInteractionBox.yMin, pressed.yMin)
    }

    func testManualReachUsesTheConfiguredBoxVerbatim() {
        var config = Self.testConfig(.indexTap)
        config.interactionBox = InteractionBox(xMin: 0.2, xMax: 0.8, yMin: 0.25, yMax: 0.75)
        engine = GestureEngine(config: config)
        for i in 0..<30 {
            feed([SyntheticHand.openRelaxed(wrist: Vec2(0.5, 0.8), scale: 0.28)], at: Double(i) / 30)
            XCTAssertEqual(engine.effectiveInteractionBox, config.interactionBox,
                           "manual reach never drifts, however big the hand")
        }
    }

    func testTheAdaptedBoxIsWhatMapsTheCursor() {
        useAutoReach()
        let scale = 0.28
        feedFrames([SyntheticHand.openRelaxed(wrist: Vec2(0.5, 0.72), scale: scale)], from: 0, count: 150)
        let box = engine.effectiveInteractionBox
        XCTAssertGreaterThan(box.yMin, 0.40, "the top edge really did move (the identity box starts at 0)")

        // The palm pointer is the wrist↔middleMCP midpoint, half a hand scale
        // above the wrist. Put it exactly on the fitted top edge and the cursor
        // has to land at the very top of the screen.
        let (_, overlay) = feed(
            [SyntheticHand.openRelaxed(wrist: Vec2(0.5, box.yMin + scale / 2), scale: scale)], at: 5.0)
        XCTAssertEqual(overlay.cursor!.y, 0, accuracy: 1e-6,
                       "…which the unadapted identity box would have mapped to 0.43")
    }
}
