import XCTest
@testable import PawvisCore

final class GestureEngineTests: XCTestCase {
    var engine: GestureEngine!

    /// Test config: identity mapping (no mirror, full box, no auto-reach
    /// drift) and effectively disabled smoothing, so positions are exact and
    /// assertions deterministic. Auto reach gets its own tests, which opt in.
    static func testConfig() -> GestureConfig {
        var config = GestureConfig.default
        config.interactionBox = InteractionBox(xMin: 0, xMax: 1, yMin: 0, yMax: 1)
        config.reachMode = .manual
        config.mirrorCamera = false
        config.smoothing = OneEuroFilter.Params(minCutoff: 1e9, beta: 0, dCutoff: 1e9)
        // The suite drives hands straight into gestures; the open-hand control
        // trigger gets its own tests, which opt back in.
        config.controlTrigger = .anyHand
        return config
    }

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

    private func scrolls(_ events: [GestureEvent]) -> [Double] {
        events.compactMap {
            if case .scroll(let deltaY) = $0 { return deltaY }
            return nil
        }
    }

    /// One left click: dip the index for the debounce, then lift it.
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

    /// Open frames, then the index dipped and held. The button goes down on
    /// the second dipped frame (`from + 1/30`), so the tap window closes at
    /// `from + 0.33`. Returns the press point.
    private func beginTapPress(at wrist: Vec2, from: TimeInterval) -> Vec2 {
        feedFrames([SyntheticHand.mouseTap(indexDown: false, wrist: wrist)], from: from - 0.1, count: 3)
        let pressed = feedFrames([SyntheticHand.mouseTap(indexDown: true, wrist: wrist)],
                                 from: from, count: 3)
        return downs(pressed).first!.0
    }

    // MARK: - Config defaults

    func testDefaultConfigMatchesSporecasterTuning() {
        let c = GestureConfig.default
        XCTAssertEqual(c.smoothing, .landmark, "sporecaster smoothed every landmark at 1.4/0.014/1.0")
        XCTAssertEqual(c.pinchEngageRatio, 0.45)
        XCTAssertEqual(c.pinchReleaseRatio, 0.53, accuracy: 1e-9,
                       "release tracks engage + hysteresis, so it follows the sensitivity slider")
    }

    func testEngageRatioUsesTheDipFactor() {
        var c = GestureConfig.default
        XCTAssertEqual(c.engageRatio, 0.675, accuracy: 1e-9,
                       "the index-tap differential idles near 1.0 and dips on a tap")
        XCTAssertEqual(c.releaseRatio, 0.755, accuracy: 1e-9)
        c.pinchEngageRatio = 0.55
        XCTAssertEqual(c.engageRatio, 0.825, accuracy: 1e-9,
                       "a tighter or looser click setting moves both thresholds with it")
        XCTAssertEqual(c.releaseRatio, 0.905, accuracy: 1e-9)
    }

    func testTapWindowDefaults() {
        let c = GestureConfig.default
        XCTAssertEqual(c.dragStartDelay, 0.30, accuracy: 1e-9)
        XCTAssertEqual(c.dragIntentDistance, 0.030, accuracy: 1e-9)
        XCTAssertEqual(c.jitterDeadband, 0.004, accuracy: 1e-9)
    }

    func testRightClickAndReachDefaults() {
        let c = GestureConfig.default
        XCTAssertTrue(c.rightClickEnabled)
        XCTAssertEqual(c.rightClickFinger, .little,
                       "the one finger the click gesture doesn't use")
        XCTAssertEqual(c.reachMode, .auto,
                       "the box fits itself to the hand unless the user takes the slider")
        XCTAssertEqual(Self.testConfig().reachMode, .manual,
                       "…but the tests pin the box, so mapped positions stay exact")
    }

    func testRightThresholdsRideTheSameSlider() {
        var c = GestureConfig.default
        XCTAssertEqual(c.rightEngageRatio, 0.675, accuracy: 1e-9)
        XCTAssertEqual(c.rightReleaseRatio, 0.755, accuracy: 1e-9)
        c.pinchEngageRatio = 0.50
        XCTAssertEqual(c.rightEngageRatio, 0.75, accuracy: 1e-9,
                       "both buttons are dips on one sensitivity slider")
        XCTAssertEqual(c.engageRatio, c.rightEngageRatio, accuracy: 1e-9)
    }

    func testScrollDefaults() {
        let c = GestureConfig.default
        XCTAssertTrue(c.scrollEnabled, "the scroll gesture ships on")
        XCTAssertFalse(c.scrollInvert)
    }

    func testRetiredClickGestureKeyIsIgnored() throws {
        // Settings persisted by builds that still had the click-gesture picker
        // carry its key; the tolerant decoder must shrug it off.
        let decoded = try JSONDecoder().decode(
            GestureConfig.self, from: Data(#"{"clickGesture":"thumbCurl","pinchEngageRatio":0.5}"#.utf8))
        XCTAssertEqual(decoded.pinchEngageRatio, 0.5, "known keys still decode")
        XCTAssertEqual(decoded.engageRatio, 0.75, accuracy: 1e-9,
                       "…and the retired mode key changes nothing")
    }

    func testScrollFieldsDecodeAndTolerateGarbage() throws {
        let known = try JSONDecoder().decode(
            GestureConfig.self, from: Data(#"{"scrollEnabled":false,"scrollInvert":true}"#.utf8))
        XCTAssertFalse(known.scrollEnabled)
        XCTAssertTrue(known.scrollInvert)

        let bogus = try JSONDecoder().decode(
            GestureConfig.self, from: Data(#"{"scrollEnabled":"maybe","scrollInvert":7}"#.utf8))
        XCTAssertTrue(bogus.scrollEnabled, "a mistyped field keeps its default")
        XCTAssertFalse(bogus.scrollInvert)
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

    func testPointerIsThePalm() {
        // The palm is the only part of the hand no finger gesture moves — a
        // fingertip centroid shifted ~0.08 when a hand opened to release,
        // smearing every click into a drag.
        let hand = SyntheticHand.openRelaxed(wrist: Vec2(0.5, 0.7))
        let events = feed([hand], at: 0).events
        let expected = hand[.wrist]!.midpoint(with: hand[.middleMCP]!)
        XCTAssertEqual(moves(events).count, 1)
        XCTAssertEqual(moves(events)[0].distance(to: expected), 0, accuracy: 1e-6)
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
        XCTAssertFalse(overlay.isScrolling)
        XCTAssertLessThan(overlay.closingProgress, 0.05,
                          "an open hand sits at the bottom of the closing ramp")
    }

    func testClosingProgressRisesAsTheFingerDips() {
        let (_, up) = feed([SyntheticHand.mouseTap(indexDown: false)], at: 0)
        let (_, half) = feed([SyntheticHand.mouseTapHalf()], at: 1 / 30.0)
        XCTAssertGreaterThan(half.closingProgress, up.closingProgress,
                             "the ring tightens as the finger comes down")
        XCTAssertFalse(half.grabbed, "still short of the engage threshold")

        let dipping = feedFrames([SyntheticHand.mouseTap(indexDown: true)], from: 0.1, count: 3)
        XCTAssertEqual(downs(dipping).count, 1)
        // Held inside the hysteresis band: the ring must stay filled for as
        // long as the button is down.
        let (_, held) = feed([SyntheticHand.mouseTapHalf()], at: 0.25)
        XCTAssertTrue(held.grabbed)
        XCTAssertEqual(held.closingProgress, 1, "strength pins at 1 while pressed")
    }

    // MARK: - Click

    func testIndexTapClicksAndReleasesOnThePalm() {
        feedFrames([SyntheticHand.mouseTap(indexDown: false)], from: 0, count: 4)

        // Two dipped frames clear the debounce → down.
        let tapping = feedFrames([SyntheticHand.mouseTap(indexDown: true)], from: 0.15, count: 3)
        let d = downs(tapping)
        XCTAssertEqual(d.count, 1, "dipping the index finger clicks")
        XCTAssertEqual(d[0].1, 1)
        XCTAssertTrue(drags(tapping).isEmpty, "a stationary tap must not drag")

        // Lifting the finger releases; the palm-anchored cursor never moved,
        // so the up lands exactly on the down.
        let lifting = feedFrames([SyntheticHand.mouseTap(indexDown: false)], from: 0.28, count: 3)
        XCTAssertTrue(drags(lifting).isEmpty)
        let u = ups(lifting)
        XCTAssertEqual(u.count, 1)
        XCTAssertEqual(u[0].1, 1)
        XCTAssertEqual(u[0].0.distance(to: d[0].0), 0, accuracy: 1e-9)
    }

    func testSingleFrameBlipDoesNotClick() {
        feedFrames([SyntheticHand.mouseTap(indexDown: false)], from: 0, count: 4)
        // One dipped frame (debounce needs 2), then open again.
        var events = feed([SyntheticHand.mouseTap(indexDown: true)], at: 0.15).events
        events += feedFrames([SyntheticHand.mouseTap(indexDown: false)], from: 0.1833, count: 3)
        XCTAssertTrue(downs(events).isEmpty, "a one-frame blip must not click")
    }

    func testSingleFrameReleaseSpikeDoesNotRelease() {
        feedFrames([SyntheticHand.mouseTap(indexDown: false)], from: 0, count: 3)
        XCTAssertEqual(downs(feedFrames([SyntheticHand.mouseTap(indexDown: true)],
                                        from: 0.1, count: 3)).count, 1)

        // One frame of Vision noise spiking past the release threshold.
        var events = feed([SyntheticHand.mouseTap(indexDown: false)], at: 0.25).events
        events += feedFrames([SyntheticHand.mouseTap(indexDown: true)], from: 0.2833, count: 3)
        XCTAssertTrue(ups(events).isEmpty, "debounce guards the release direction too")
    }

    func testMissingJointHoldsTapState() {
        feedFrames([SyntheticHand.mouseTap(indexDown: false)], from: 0, count: 3)
        XCTAssertEqual(downs(feedFrames([SyntheticHand.mouseTap(indexDown: true)],
                                        from: 0.1, count: 3)).count, 1)

        // The index tip drops below minJointConfidence → no ratio at all.
        var faint = SyntheticHand.mouseTap(indexDown: true)
        faint.setPoint(faint[.indexTip]!, for: .indexTip, confidence: 0.1)
        let e = feedFrames([faint], from: 0.25, count: 5)
        XCTAssertTrue(ups(e).isEmpty, "a low-confidence joint must never release the button")
        let (_, overlay) = feed([faint], at: 0.45)
        XCTAssertTrue(overlay.grabbed, "state is held, not flapped")

        // Confidence returns: still pressed, and a real lift still releases.
        let (_, restored) = feed([SyntheticHand.mouseTap(indexDown: true)], at: 0.5)
        XCTAssertTrue(restored.grabbed)
        XCTAssertEqual(ups(feedFrames([SyntheticHand.mouseTap(indexDown: false)],
                                      from: 0.55, count: 3)).count, 1)
    }

    func testDoubleTripleThenWrapChaining() {
        feedFrames([SyntheticHand.mouseTap(indexDown: false)], from: 0, count: 3)
        let w = Vec2(0.5, 0.7)

        let c1 = tapClick(at: w, from: 0.10)
        XCTAssertEqual(downs(c1).map(\.1), [1])

        let c2 = tapClick(at: w, from: 0.30)
        XCTAssertEqual(downs(c2).map(\.1), [2], "quick second click chains to double")

        let c3 = tapClick(at: w, from: 0.50)
        XCTAssertEqual(downs(c3).map(\.1), [3], "third chains to triple")

        let c4 = tapClick(at: w, from: 0.70)
        XCTAssertEqual(downs(c4).map(\.1), [1], "after a triple the chain restarts")
    }

    func testSlowSecondClickIsSingle() {
        feedFrames([SyntheticHand.mouseTap(indexDown: false)], from: 0, count: 3)
        _ = tapClick(from: 0.1)
        let c2 = tapClick(from: 1.5)
        XCTAssertEqual(downs(c2).map(\.1), [1])
    }

    func testSecondClickFarAwayIsSingle() {
        feedFrames([SyntheticHand.mouseTap(indexDown: false, wrist: Vec2(0.3, 0.7))], from: 0, count: 3)
        _ = tapClick(at: Vec2(0.3, 0.7), from: 0.1)
        // Move away, then click quickly: position slop breaks the chain.
        feedFrames([SyntheticHand.mouseTap(indexDown: false, wrist: Vec2(0.7, 0.4))], from: 0.25, count: 3)
        let c2 = tapClick(at: Vec2(0.7, 0.4), from: 0.36)
        XCTAssertEqual(downs(c2).map(\.1), [1])
    }

    func testWholeHandTiltDoesNotIndexTap() {
        // Curling every finger (or pitching the whole hand forward) shortens
        // the index AND middle extents together — the differential stays flat,
        // so no click. Only the index moving relative to its neighbor taps.
        feedFrames([SyntheticHand.mouseTap(indexDown: false)], from: 0, count: 4)
        let e = feedFrames([SyntheticHand.fist()], from: 0.15, count: 6)
        XCTAssertTrue(downs(e).isEmpty, "whole-hand curl must not read as an index tap")
    }

    // MARK: - Drag / hold

    func testHeldTapDragsWithThePalm() {
        feedFrames([SyntheticHand.mouseTap(indexDown: false, wrist: Vec2(0.4, 0.7))], from: 0, count: 3)
        let down = feedFrames([SyntheticHand.mouseTap(indexDown: true, wrist: Vec2(0.4, 0.7))],
                              from: 0.1, count: 3)
        XCTAssertEqual(downs(down).count, 1)

        // Past the tap window, so the ordinary dragActivationDistance rule runs.
        var dragged: [Vec2] = []
        for i in 1...6 {
            let e = feed([SyntheticHand.mouseTap(indexDown: true,
                                                 wrist: Vec2(0.4 + Double(i) * 0.03, 0.7))],
                         at: 0.5 + Double(i) / 30).events
            dragged += drags(e)
            XCTAssertTrue(moves(e).isEmpty, "no plain moves while pressed")
            XCTAssertTrue(ups(e).isEmpty, "the press holds while the finger stays down")
        }
        XCTAssertEqual(dragged.count, 6)
        XCTAssertEqual(dragged, dragged.sorted { $0.x < $1.x }, "drag positions advance monotonically")

        let lifting = feedFrames([SyntheticHand.mouseTap(indexDown: false, wrist: Vec2(0.58, 0.7))],
                                 from: 0.8, count: 3)
        let u = ups(lifting)
        XCTAssertEqual(u.count, 1)
        XCTAssertEqual(u[0].0.x, dragged.last!.x, accuracy: 1e-6, "up lands at the drag end")
    }

    func testMicroMovementWhilePressedDoesNotDrag() {
        feedFrames([SyntheticHand.mouseTap(indexDown: false, wrist: Vec2(0.5, 0.7))], from: 0, count: 3)
        feedFrames([SyntheticHand.mouseTap(indexDown: true, wrist: Vec2(0.5, 0.7))],
                   from: 0.1, count: 3)
        let e = feedFrames([SyntheticHand.mouseTap(indexDown: true, wrist: Vec2(0.504, 0.7))],
                           from: 0.25, count: 3)
        XCTAssertTrue(drags(e).isEmpty, "sub-threshold wobble must not start a drag")
        let up = feedFrames([SyntheticHand.mouseTap(indexDown: false, wrist: Vec2(0.504, 0.7))],
                            from: 0.4, count: 3)
        XCTAssertEqual(ups(up).count, 1)
    }

    func testHoldNeverTimesOut() {
        feedFrames([SyntheticHand.mouseTap(indexDown: false)], from: 0, count: 3)
        var events = feedFrames([SyntheticHand.mouseTap(indexDown: true)], from: 0.1, count: 90) // 3 s
        XCTAssertEqual(downs(events).count, 1)
        XCTAssertTrue(ups(events).isEmpty, "hold must persist indefinitely")
        events = feedFrames([SyntheticHand.mouseTap(indexDown: false)], from: 3.2, count: 3)
        XCTAssertEqual(ups(events).count, 1)
    }

    // MARK: - Hysteresis

    func testHysteresisBandHoldsStateBothWays() {
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

    // MARK: - Tracking loss and robustness

    func testTrackingLossReleasesPressAfterGrace() {
        feedFrames([SyntheticHand.mouseTap(indexDown: false)], from: 0, count: 3)
        feedFrames([SyntheticHand.mouseTap(indexDown: true)], from: 0.1, count: 3)

        XCTAssertTrue(ups(feed([], at: 0.30).events).isEmpty, "grace holds the press")
        let e = feed([], at: 0.55).events
        XCTAssertEqual(ups(e).count, 1, "held button must release after tracking loss")
        XCTAssertTrue(ups(feed([], at: 0.7).events).isEmpty, "no repeated releases")
    }

    func testBriefDropoutKeepsDrag() {
        feedFrames([SyntheticHand.mouseTap(indexDown: false, wrist: Vec2(0.4, 0.7))], from: 0, count: 3)
        feedFrames([SyntheticHand.mouseTap(indexDown: true, wrist: Vec2(0.4, 0.7))],
                   from: 0.1, count: 3)
        XCTAssertTrue(ups(feed([], at: 0.22).events).isEmpty)
        let e = feed([SyntheticHand.mouseTap(indexDown: true, wrist: Vec2(0.5, 0.7))], at: 0.25).events
        XCTAssertTrue(ups(e).isEmpty)
        XCTAssertFalse(drags(e).isEmpty, "drag continues after a one-frame dropout")
    }

    func testLowConfidenceHandIsIgnored() {
        let (events, overlay) = feed([SyntheticHand.openRelaxed(confidence: 0.1)], at: 0)
        XCTAssertTrue(events.isEmpty)
        XCTAssertNil(overlay.cursor)
    }

    func testForceReleaseEmitsUpAndBlocksChaining() {
        feedFrames([SyntheticHand.mouseTap(indexDown: false)], from: 0, count: 3)
        feedFrames([SyntheticHand.mouseTap(indexDown: true)], from: 0.1, count: 3)
        let released = engine.forceRelease(at: 0.25)
        XCTAssertEqual(ups(released).count, 1)

        feedFrames([SyntheticHand.mouseTap(indexDown: false)], from: 0.3, count: 2)
        let c = tapClick(from: 0.4)
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
        let downAt = beginTapPress(at: Vec2(0.5, 0.7), from: 0.1) // down at t = 0.133
        // 0.015 of press wobble: past dragActivationDistance (0.010), short of
        // dragIntentDistance (0.030) — the shake of a hand closing, not a drag.
        let wobbled = SyntheticHand.mouseTap(indexDown: true, wrist: Vec2(0.515, 0.7))
        XCTAssertTrue(drags(feedFrames([wobbled], from: 0.2, count: 3)).isEmpty,
                      "wobble inside the tap window must not drag")

        // Release 0.2 s after the down — still inside the 0.30 s window.
        let lifting = feedFrames([SyntheticHand.mouseTap(indexDown: false, wrist: Vec2(0.515, 0.7))],
                                 from: 0.3333, count: 3)
        XCTAssertTrue(drags(lifting).isEmpty)
        XCTAssertEqual(ups(lifting).count, 1)
        XCTAssertEqual(ups(lifting)[0].0, downAt, "the up lands exactly on the press point")
    }

    func testHoldingPastTheTapWindowLetsWobbleDrag() {
        let downAt = beginTapPress(at: Vec2(0.5, 0.7), from: 0.1)
        let wobbled = SyntheticHand.mouseTap(indexDown: true, wrist: Vec2(0.515, 0.7))
        XCTAssertTrue(drags(feedFrames([wobbled], from: 0.2, count: 3)).isEmpty)

        // Same offset once the window has expired: the ordinary activation
        // distance applies, so the held tap becomes a grab.
        let after = feedFrames([wobbled], from: 0.5, count: 2)
        XCTAssertEqual(drags(after).count, 1, "one drag to the wobbled point, then it holds still")

        let moved = feedFrames([SyntheticHand.mouseTap(indexDown: true, wrist: Vec2(0.565, 0.7))],
                               from: 0.6, count: 2)
        XCTAssertEqual(drags(moved).count, 1)
        XCTAssertEqual(drags(moved)[0].x - downAt.x, 0.065, accuracy: 1e-3)
    }

    func testDeliberateFlickInsideTapWindowDragsImmediately() {
        let downAt = beginTapPress(at: Vec2(0.5, 0.7), from: 0.1)
        let flicked = SyntheticHand.mouseTap(indexDown: true, wrist: Vec2(0.55, 0.7))
        let d = drags(feed([flicked], at: 0.2).events)
        XCTAssertEqual(d.count, 1, "0.05 of travel is unmistakably a drag, window or not")
        XCTAssertEqual(d[0].distance(to: flicked[.wrist]!.midpoint(with: flicked[.middleMCP]!)),
                       0, accuracy: 1e-6, "and it tracks the palm from the first frame")
        XCTAssertEqual(d[0].x - downAt.x, 0.05, accuracy: 1e-3)
    }

    // MARK: - Jitter deadband

    func testJitterDeadbandSuppressesShimmerWhileDragging() {
        _ = beginTapPress(at: Vec2(0.5, 0.7), from: 0.1)
        let started = feed([SyntheticHand.mouseTap(indexDown: true, wrist: Vec2(0.55, 0.7))],
                           at: 0.5).events
        XCTAssertEqual(drags(started).count, 1)

        // Vision shivering the tracked joints ±0.002 around a held position.
        var shimmer: [Vec2] = []
        for i in 0..<6 {
            let x = 0.55 + (i.isMultiple(of: 2) ? 0.002 : 0)
            shimmer += drags(feed([SyntheticHand.mouseTap(indexDown: true, wrist: Vec2(x, 0.7))],
                                  at: 0.6 + Double(i) / 30).events)
        }
        XCTAssertTrue(shimmer.isEmpty, "sub-deadband shiver must not re-emit drags")

        // Real motion at 0.006 a frame flows through untouched.
        var real: [Vec2] = []
        for i in 1...4 {
            real += drags(feed([SyntheticHand.mouseTap(indexDown: true,
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

    func testFaintJointsNeverEngage() {
        feedFrames([SyntheticHand.mouseTap(indexDown: false)], from: 0, count: 3)
        var faint = SyntheticHand.mouseTap(indexDown: true)
        for joint in [HandJoint.indexTip, .indexMCP, .middleTip, .middleMCP] {
            faint.setPoint(faint[joint]!, for: joint, confidence: 0.30)
        }
        // 0.30 clears minJointConfidence (0.25), so the ratio is there and the
        // ring reads closed — only the engage floor (0.40) blocks the click.
        let e = feedFrames([faint], from: 0.1, count: 20)
        XCTAssertTrue(downs(e).isEmpty, "phantom-prone frames must never click, however many arrive")
        let (_, overlay) = feed([faint], at: 0.85)
        XCTAssertEqual(overlay.closingProgress, 1, accuracy: 1e-9)
        XCTAssertFalse(overlay.grabbed)

        // The same pose tracked confidently clicks on the usual debounce.
        XCTAssertEqual(downs(feedFrames([SyntheticHand.mouseTap(indexDown: true)],
                                        from: 0.9, count: 3)).map(\.1), [1])
    }

    func testFaintJointsStillRelease() {
        feedFrames([SyntheticHand.mouseTap(indexDown: false)], from: 0, count: 3)
        XCTAssertEqual(downs(feedFrames([SyntheticHand.mouseTap(indexDown: true)],
                                        from: 0.1, count: 3)).count, 1)

        // Confidence usually sags exactly as the hand opens; releasing must
        // never be the harder direction or the button sticks.
        var faintOpen = SyntheticHand.mouseTap(indexDown: false)
        for joint in [HandJoint.indexTip, .middleTip] {
            faintOpen.setPoint(faintOpen[joint]!, for: joint, confidence: 0.30)
        }
        XCTAssertEqual(ups(feedFrames([faintOpen], from: 0.25, count: 3)).count, 1)
    }

    // MARK: - Right click

    func testPinkyDipRightClicks() {
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
        feedFrames([SyntheticHand.mouseTap(indexDown: false)], from: 0, count: 3)
        XCTAssertEqual(rightDowns(rightClick(from: 0.10)).map(\.1), [1])
        XCTAssertEqual(rightDowns(rightClick(from: 0.30)).map(\.1), [1],
                       "a right click is always a single, however fast it repeats")
    }

    func testRightClickLeavesTheDoubleClickChainAlone() {
        feedFrames([SyntheticHand.mouseTap(indexDown: false)], from: 0, count: 3)
        XCTAssertEqual(downs(tapClick(from: 0.10)).map(\.1), [1])
        XCTAssertEqual(rightDowns(rightClick(from: 0.28)).map(\.1), [1])
        XCTAssertEqual(downs(tapClick(from: 0.46)).map(\.1), [2],
                       "the right click neither chained into the double nor broke it")
    }

    func testRightClickCanBeTurnedOff() {
        var config = Self.testConfig()
        config.rightClickEnabled = false
        engine = GestureEngine(config: config)
        feedFrames([SyntheticHand.mouseTap(indexDown: false)], from: 0, count: 3)
        let e = feedFrames([SyntheticHand.fingerDip(.little)], from: 0.1, count: 10)
        XCTAssertTrue(rightDowns(e).isEmpty)
        XCTAssertTrue(downs(e).isEmpty)
    }

    func testRightClickFingerCannotAlsoBeTheLeftClickFinger() {
        var config = Self.testConfig()
        config.rightClickFinger = .index
        engine = GestureEngine(config: config)
        feedFrames([SyntheticHand.mouseTap(indexDown: false)], from: 0, count: 3)
        let e = feedFrames([SyntheticHand.mouseTap(indexDown: true)], from: 0.1, count: 3)
        XCTAssertTrue(rightDowns(e).isEmpty, "the index already presses the left button")
        XCTAssertEqual(downs(e).map(\.1), [1], "…and it still does")
    }

    func testRingFingerRightClickWhenConfigured() {
        var config = Self.testConfig()
        config.rightClickFinger = .ring
        engine = GestureEngine(config: config)
        feedFrames([SyntheticHand.mouseTap(indexDown: false)], from: 0, count: 3)
        XCTAssertEqual(rightDowns(feedFrames([SyntheticHand.fingerDip(.ring)],
                                             from: 0.1, count: 3)).map(\.1), [1],
                       "a genuine ring dip keeps the middle finger up, so the scroll guard stays out of the way")
        XCTAssertEqual(rightUps(feedFrames([SyntheticHand.mouseTap(indexDown: false)],
                                           from: 0.3, count: 3)).count, 1)
        // …and the pinky no longer does anything.
        XCTAssertTrue(rightDowns(feedFrames([SyntheticHand.fingerDip(.little)],
                                            from: 0.5, count: 10)).isEmpty)
    }

    func testMiddleFingerRightClickWhenConfigured() {
        var config = Self.testConfig()
        config.rightClickFinger = .middle
        engine = GestureEngine(config: config)
        feedFrames([SyntheticHand.mouseTap(indexDown: false)], from: 0, count: 3)
        XCTAssertEqual(rightDowns(feedFrames([SyntheticHand.fingerDip(.middle)],
                                             from: 0.1, count: 3)).map(\.1), [1],
                       "a genuine middle dip keeps the ring up, so the scroll guard stays out of the way")
        XCTAssertEqual(rightUps(feedFrames([SyntheticHand.mouseTap(indexDown: false)],
                                           from: 0.3, count: 3)).count, 1)
    }

    func testFaintDipJointsNeverRightClick() {
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
        feedFrames([SyntheticHand.mouseTap(indexDown: false)], from: 0, count: 3)
        XCTAssertEqual(rightDowns(feedFrames([SyntheticHand.fingerDip(.little)],
                                             from: 0.1, count: 3)).count, 1)

        engine.config.rightClickEnabled = false

        XCTAssertEqual(rightUps(feed([SyntheticHand.fingerDip(.little)], at: 0.25).events).count, 1)
        XCTAssertTrue(rightDowns(feedFrames([SyntheticHand.fingerDip(.little)],
                                            from: 0.3, count: 6)).isEmpty)
    }

    // MARK: - Scroll

    func testScrollPoseScrollsUpAndDown() {
        feedFrames([SyntheticHand.openRelaxed()], from: 0, count: 3)

        // Two posed frames clear the engage debounce; stationary = no deltas.
        let engaging = feedFrames([SyntheticHand.scrollPose()], from: 0.1, count: 3)
        XCTAssertTrue(scrolls(engaging).isEmpty, "a stationary pose scrolls nothing")
        XCTAssertTrue(downs(engaging).isEmpty && rightDowns(engaging).isEmpty,
                      "the pose is neither click's shape")
        let (_, overlay) = feed([SyntheticHand.scrollPose()], at: 0.2)
        XCTAssertTrue(overlay.isScrolling)

        // Hand up → positive (scroll-up) deltas that sum to the travel.
        var upDeltas: [Double] = []
        for i in 1...5 {
            upDeltas += scrolls(feed(
                [SyntheticHand.scrollPose(wrist: Vec2(0.5, 0.7 - Double(i) * 0.02))],
                at: 0.25 + Double(i) / 30).events)
        }
        XCTAssertEqual(upDeltas.count, 5)
        XCTAssertTrue(upDeltas.allSatisfy { $0 > 0 }, "hand up = scroll up")
        XCTAssertEqual(upDeltas.reduce(0, +), 0.10, accuracy: 1e-6)

        // Hand back down → negative deltas.
        var downDeltas: [Double] = []
        for i in 1...5 {
            downDeltas += scrolls(feed(
                [SyntheticHand.scrollPose(wrist: Vec2(0.5, 0.6 + Double(i) * 0.02))],
                at: 0.5 + Double(i) / 30).events)
        }
        XCTAssertTrue(downDeltas.allSatisfy { $0 < 0 }, "hand down = scroll down")
        XCTAssertEqual(downDeltas.reduce(0, +), -0.10, accuracy: 1e-6)
    }

    func testScrollInvertFlipsTheDirection() {
        var config = Self.testConfig()
        config.scrollInvert = true
        engine = GestureEngine(config: config)
        feedFrames([SyntheticHand.openRelaxed()], from: 0, count: 3)
        feedFrames([SyntheticHand.scrollPose()], from: 0.1, count: 3)

        var deltas: [Double] = []
        for i in 1...4 {
            deltas += scrolls(feed(
                [SyntheticHand.scrollPose(wrist: Vec2(0.5, 0.7 - Double(i) * 0.02))],
                at: 0.25 + Double(i) / 30).events)
        }
        XCTAssertEqual(deltas.count, 4)
        XCTAssertTrue(deltas.allSatisfy { $0 < 0 }, "inverted: hand up = scroll down")
    }

    func testScrollCanBeTurnedOff() {
        var config = Self.testConfig()
        config.scrollEnabled = false
        engine = GestureEngine(config: config)
        feedFrames([SyntheticHand.openRelaxed()], from: 0, count: 3)

        var events: [GestureEvent] = []
        for i in 0..<8 {
            events += feed([SyntheticHand.scrollPose(wrist: Vec2(0.5, 0.7 - Double(i) * 0.02))],
                           at: 0.1 + Double(i) / 30).events
        }
        XCTAssertTrue(scrolls(events).isEmpty)
        XCTAssertFalse(moves(events).isEmpty, "disabled, the pose is just a hand — the cursor follows")
        XCTAssertTrue(downs(events).isEmpty && rightDowns(events).isEmpty)
    }

    func testCursorParksWhileScrollingAndResumesAfter() {
        feedFrames([SyntheticHand.openRelaxed()], from: 0, count: 3)
        let parkedAt = feed([SyntheticHand.openRelaxed()], at: 0.1).overlay.cursor!
        feedFrames([SyntheticHand.scrollPose()], from: 0.13, count: 3)

        var events: [GestureEvent] = []
        var lastOverlay = OverlayState()
        for i in 1...5 {
            let (e, o) = feed([SyntheticHand.scrollPose(wrist: Vec2(0.5, 0.7 - Double(i) * 0.03))],
                              at: 0.25 + Double(i) / 30)
            events += e
            lastOverlay = o
        }
        XCTAssertTrue(moves(events).isEmpty, "the cursor is parked while the pose scrolls")
        XCTAssertEqual(lastOverlay.cursor!, parkedAt, "…exactly where the scroll began")
        XCTAssertFalse(scrolls(events).isEmpty)

        // Reopening the hand ends the scroll and the cursor follows again —
        // jumping to wherever the hand ended up.
        let released = feedFrames([SyntheticHand.openRelaxed(wrist: Vec2(0.5, 0.55))],
                                  from: 0.5, count: 3)
        XCTAssertTrue(scrolls(released).isEmpty)
        XCTAssertEqual(moves(released).count, 1)
        XCTAssertEqual(moves(released)[0].y, 0.55 - 0.075, accuracy: 1e-6,
                       "the cursor lands on the hand's current palm")
    }

    func testScrollPoseHalfHoldsAScrollButNeverStartsOne() {
        // From idle, the half-bent pose must not engage…
        feedFrames([SyntheticHand.openRelaxed()], from: 0, count: 3)
        var idle: [GestureEvent] = []
        for i in 0..<8 {
            idle += feed([SyntheticHand.scrollPoseHalf(wrist: Vec2(0.5, 0.7 - Double(i) * 0.02))],
                         at: 0.1 + Double(i) / 30).events
        }
        XCTAssertTrue(scrolls(idle).isEmpty, "the neutral band must not start a scroll")
        XCTAssertFalse(moves(idle).isEmpty)

        // …but once scrolling, drifting into the band keeps the scroll alive.
        feedFrames([SyntheticHand.scrollPose(wrist: Vec2(0.5, 0.56))], from: 0.4, count: 3)
        var held: [GestureEvent] = []
        for i in 1...4 {
            held += feed([SyntheticHand.scrollPoseHalf(wrist: Vec2(0.5, 0.56 - Double(i) * 0.02))],
                         at: 0.5 + Double(i) / 30).events
        }
        XCTAssertEqual(scrolls(held).count, 4, "the band holds the pose — hysteresis for free")
        XCTAssertTrue(moves(held).isEmpty)
    }

    func testScrollJitterDeadbandAccumulates() {
        feedFrames([SyntheticHand.openRelaxed()], from: 0, count: 3)
        feedFrames([SyntheticHand.scrollPose()], from: 0.1, count: 3)

        // 0.003 of shimmer: below the deadband, nothing.
        let tiny = feed([SyntheticHand.scrollPose(wrist: Vec2(0.5, 0.697))], at: 0.2).events
        XCTAssertTrue(scrolls(tiny).isEmpty, "sub-deadband wobble must not scroll")

        // Another 0.003 in the same direction: slow travel accumulates
        // against the unmoved anchor and comes through whole.
        let accumulated = feed([SyntheticHand.scrollPose(wrist: Vec2(0.5, 0.694))], at: 0.233).events
        XCTAssertEqual(scrolls(accumulated).count, 1)
        XCTAssertEqual(scrolls(accumulated)[0], 0.006, accuracy: 1e-6)
    }

    func testScrollNeverStartsMidPress() {
        feedFrames([SyntheticHand.mouseTap(indexDown: false)], from: 0, count: 3)
        feedFrames([SyntheticHand.mouseTap(indexDown: true)], from: 0.1, count: 3)

        // Morph straight into the scroll pose: the press must release first,
        // and no scroll may fire before the up.
        var sawUp = false
        var all: [GestureEvent] = []
        for i in 0..<8 {
            let e = feed([SyntheticHand.scrollPose(wrist: Vec2(0.5, 0.7 - Double(i) * 0.02))],
                         at: 0.25 + Double(i) / 30).events
            if !sawUp {
                XCTAssertTrue(scrolls(e).isEmpty, "no scroll before the button lets go")
            }
            if !ups(e).isEmpty { sawUp = true }
            all += e
        }
        XCTAssertTrue(sawUp, "extending the index out of the press releases it")
        XCTAssertFalse(scrolls(all).isEmpty, "…then the pose scrolls normally")
    }

    func testReleasingScrollRestoresClicking() {
        feedFrames([SyntheticHand.openRelaxed()], from: 0, count: 3)
        feedFrames([SyntheticHand.scrollPose()], from: 0.1, count: 4)
        feedFrames([SyntheticHand.openRelaxed()], from: 0.25, count: 3)
        XCTAssertEqual(downs(tapClick(from: 0.4)).map(\.1), [1],
                       "clicking works normally the moment the pose lets go")
    }

    func testTrackingLossResetsScroll() {
        feedFrames([SyntheticHand.openRelaxed()], from: 0, count: 3)
        feedFrames([SyntheticHand.scrollPose()], from: 0.1, count: 3)

        feed([], at: 0.6) // past the grace: the hand is really gone

        // The hand returns somewhere else entirely: the pose has to re-engage,
        // and the fresh anchor means no jump-sized delta.
        let returning = feedFrames([SyntheticHand.scrollPose(wrist: Vec2(0.5, 0.3))],
                                   from: 0.7, count: 4)
        XCTAssertTrue(scrolls(returning).isEmpty,
                      "re-engaging re-anchors — the position jump must not scroll")
        var deltas: [Double] = []
        for i in 1...3 {
            deltas += scrolls(feed([SyntheticHand.scrollPose(wrist: Vec2(0.5, 0.3 - Double(i) * 0.02))],
                                   at: 0.85 + Double(i) / 30).events)
        }
        XCTAssertEqual(deltas.count, 3, "…and scrolling resumes from the new anchor")
    }

    func testDisablingScrollMidScrollStops() {
        feedFrames([SyntheticHand.openRelaxed()], from: 0, count: 3)
        feedFrames([SyntheticHand.scrollPose()], from: 0.1, count: 3)

        engine.config.scrollEnabled = false

        var events: [GestureEvent] = []
        for i in 1...4 {
            events += feed([SyntheticHand.scrollPose(wrist: Vec2(0.5, 0.7 - Double(i) * 0.02))],
                           at: 0.25 + Double(i) / 30).events
        }
        XCTAssertTrue(scrolls(events).isEmpty, "the switch stops an in-flight scroll at once")
        XCTAssertFalse(moves(events).isEmpty, "…and the cursor follows the hand again")
    }

    func testScrollPoseEntryNeverPhantomsAMiddleRightClick() {
        // fingerTapRatio(.middle) references the index, which stays up in the
        // scroll pose — so folding into the pose reads exactly like a middle
        // dip for a frame or two. The scroll guard (ring must stay extended)
        // is what keeps that from firing the right button.
        var config = Self.testConfig()
        config.rightClickFinger = .middle
        engine = GestureEngine(config: config)
        feedFrames([SyntheticHand.mouseTap(indexDown: false)], from: 0, count: 3)

        var events: [GestureEvent] = []
        for i in 0..<10 {
            events += feed([SyntheticHand.scrollPose(wrist: Vec2(0.5, 0.7 - Double(i) * 0.01))],
                           at: 0.1 + Double(i) / 30).events
        }
        XCTAssertTrue(rightDowns(events).isEmpty, "folding into the scroll pose is not a middle dip")
        XCTAssertFalse(scrolls(events).isEmpty, "…it is a scroll")
    }

    func testRingLeadingFoldNeverPhantomsARingRightClick() {
        // Entering the scroll pose ring-first: the ring reads dipped while the
        // middle is still on its way down. The guard (middle must stay
        // extended for a ring right-click) blocks the phantom.
        var config = Self.testConfig()
        config.rightClickFinger = .ring
        engine = GestureEngine(config: config)
        feedFrames([SyntheticHand.mouseTap(indexDown: false)], from: 0, count: 3)

        let ringFirst = SyntheticHand.build(
            pose: .init(fingerDirs: SyntheticHand.relaxedDirs,
                        curled: [.ring], semiCurled: [.middle],
                        thumbTipOffset: SyntheticHand.thumbExtendedOffset))
        let e = feedFrames([ringFirst], from: 0.1, count: 10)
        XCTAssertTrue(rightDowns(e).isEmpty, "a fold-in-progress is not a ring dip")
    }

    // MARK: - Control trigger

    /// The test config with the open-hand control trigger switched back on.
    private func useOpenHandTrigger() {
        var config = Self.testConfig()
        config.controlTrigger = .openHand
        engine = GestureEngine(config: config)
    }

    /// A pressing hand that also reads deliberately closed: the index dipped
    /// into a click with the ring and little curled alongside (three curled
    /// fingers) — the pose that would disarm control if a held press didn't
    /// pin it armed.
    private func clenchedTap(wrist: Vec2 = Vec2(0.5, 0.7)) -> Hand {
        SyntheticHand.build(
            pose: .init(fingerDirs: SyntheticHand.relaxedDirs,
                        curled: [.index, .ring, .little],
                        thumbTipOffset: SyntheticHand.thumbTuckedOffset),
            wrist: wrist)
    }

    func testControlTriggerDefaultsToOpenHand() {
        XCTAssertEqual(GestureConfig.default.controlTrigger, .openHand,
                       "a merely visible hand must not seize the cursor")
        XCTAssertEqual(Self.testConfig().controlTrigger, .anyHand,
                       "…but the rest of the suite drives hands without the ceremony")
    }

    func testUnreadableControlTriggerKeepsTheDefault() throws {
        let bogus = try JSONDecoder().decode(
            GestureConfig.self, from: Data(#"{"controlTrigger":"jazzHands"}"#.utf8))
        XCTAssertEqual(bogus.controlTrigger, .openHand,
                       "an unknown trigger must not fail the settings tree")
        let known = try JSONDecoder().decode(
            GestureConfig.self, from: Data(#"{"controlTrigger":"anyHand"}"#.utf8))
        XCTAssertEqual(known.controlTrigger, .anyHand)
    }

    func testDisarmedHandNeverMovesClicksOrScrolls() {
        useOpenHandTrigger()
        var events: [GestureEvent] = []
        for i in 0..<10 {
            events += feed([SyntheticHand.fist(wrist: Vec2(0.3 + Double(i) * 0.04, 0.7))],
                           at: Double(i) / 30).events
        }
        XCTAssertTrue(events.isEmpty, "a hand that never showed the trigger controls nothing")

        // A click gesture from a hand that never armed is just as inert…
        let dipped = feedFrames([SyntheticHand.mouseTap(indexDown: true)], from: 0.4, count: 10)
        XCTAssertTrue(downs(dipped).isEmpty, "click gestures are inert until control arms")

        // …and so is the scroll pose (it is not the open-hand trigger).
        var scrolled: [GestureEvent] = []
        for i in 0..<8 {
            scrolled += feed([SyntheticHand.scrollPose(wrist: Vec2(0.5, 0.7 - Double(i) * 0.02))],
                             at: 0.8 + Double(i) / 30).events
        }
        XCTAssertTrue(scrolled.isEmpty, "the scroll pose neither arms control nor scrolls unarmed")

        let (_, overlay) = feed([SyntheticHand.fist(wrist: Vec2(0.7, 0.7))], at: 1.2)
        XCTAssertFalse(overlay.armed)
        XCTAssertNil(overlay.cursor, "no cursor exists before control has ever armed")
        XCTAssertEqual(overlay.hands.count, 1, "the hand still tracks — the dots render")
        XCTAssertEqual(overlay.closingProgress, 0, accuracy: 1e-9)
    }

    func testOpenHandArmsOnTheThirdConsecutiveFrame() {
        useOpenHandTrigger()
        feedFrames([SyntheticHand.fist()], from: 0, count: 3)

        let e1 = feed([SyntheticHand.openRelaxed(wrist: Vec2(0.50, 0.7))], at: 0.20).events
        let e2 = feed([SyntheticHand.openRelaxed(wrist: Vec2(0.52, 0.7))], at: 0.233).events
        XCTAssertTrue(moves(e1).isEmpty && moves(e2).isEmpty,
                      "two open frames are not yet the trigger")
        let (e3, overlay) = feed([SyntheticHand.openRelaxed(wrist: Vec2(0.54, 0.7))], at: 0.267)
        XCTAssertEqual(moves(e3).count, 1,
                       "the third consecutive open frame arms control and the cursor moves")
        XCTAssertTrue(overlay.armed)
    }

    func testAFlashOfOpenHandDoesNotArm() {
        useOpenHandTrigger()
        var events: [GestureEvent] = []
        let sequence = [SyntheticHand.openRelaxed(), SyntheticHand.openRelaxed(),
                        SyntheticHand.fist(),
                        SyntheticHand.openRelaxed(), SyntheticHand.openRelaxed()]
        for (i, hand) in sequence.enumerated() {
            events += feed([hand], at: Double(i) / 30).events
        }
        XCTAssertTrue(moves(events).isEmpty,
                      "the arm debounce needs consecutive open frames, not a total")
    }

    func testArmedIndexTapClicksAndStaysArmed() {
        useOpenHandTrigger()
        feedFrames([SyntheticHand.mouseTap(indexDown: false)], from: 0, count: 4) // arms

        let tapping = feedFrames([SyntheticHand.mouseTap(indexDown: true)], from: 0.15, count: 3)
        XCTAssertEqual(downs(tapping).count, 1, "an armed hand clicks exactly as before")
        let lifting = feedFrames([SyntheticHand.mouseTap(indexDown: false)], from: 0.28, count: 3)
        XCTAssertEqual(ups(lifting).count, 1)

        let (_, overlay) = feed([SyntheticHand.mouseTap(indexDown: false)], at: 0.5)
        XCTAssertTrue(overlay.armed, "a click's finger dip must never disarm control")
    }

    func testScrollingKeepsControlArmed() {
        useOpenHandTrigger()
        feedFrames([SyntheticHand.openRelaxed()], from: 0, count: 4) // arms

        feedFrames([SyntheticHand.scrollPose()], from: 0.15, count: 3)
        var deltas: [Double] = []
        var lastOverlay = OverlayState()
        for i in 1...9 {
            let (e, o) = feed([SyntheticHand.scrollPose(wrist: Vec2(0.5, 0.7 - Double(i) * 0.02))],
                              at: 0.3 + Double(i) / 30)
            deltas += scrolls(e)
            lastOverlay = o
        }
        XCTAssertEqual(deltas.count, 9,
                       "two folded fingers are under the three-finger disarm line")
        XCTAssertTrue(lastOverlay.armed)
        XCTAssertTrue(lastOverlay.isScrolling)
    }

    func testHeldPressPinsControlArmed() {
        useOpenHandTrigger()
        feedFrames([SyntheticHand.openRelaxed()], from: 0, count: 4) // arms

        let closing = feedFrames([clenchedTap()], from: 0.15, count: 3)
        XCTAssertEqual(downs(closing).count, 1, "a clenched tap still clicks")

        // A full second of a hand that reads deliberately closed: the held
        // press must pin control armed, or the button strands mid-drag.
        let held = feedFrames([clenchedTap()], from: 0.3, count: 30)
        XCTAssertTrue(ups(held).isEmpty, "a held press pins control armed, however closed the hand")

        let opening = feedFrames([SyntheticHand.openRelaxed()], from: 1.4, count: 3)
        XCTAssertEqual(ups(opening).count, 1)
        let after = feed([SyntheticHand.openRelaxed(wrist: Vec2(0.6, 0.7))], at: 1.6).events
        XCTAssertEqual(moves(after).count, 1, "…and control is still armed after the release")
    }

    func testFistDisarmsAndParksTheCursor() {
        // A whole-hand curl keeps the tap differential flat, so a fist is
        // inert to the click — free to be the parking gesture.
        useOpenHandTrigger()
        feedFrames([SyntheticHand.mouseTap(indexDown: false)], from: 0, count: 4) // arms

        // A closing hand keeps the cursor through the disarm debounce…
        var during: [GestureEvent] = []
        for i in 0..<9 {
            during += feed([SyntheticHand.fist(wrist: Vec2(0.5 + Double(i) * 0.01, 0.7))],
                           at: 0.2 + Double(i) / 30).events
        }
        XCTAssertFalse(moves(during).isEmpty, "the debounce window still tracks")
        XCTAssertTrue(downs(during).isEmpty, "a whole-hand curl is not an index tap")

        // …then lets go: further movement of the closed hand is ignored.
        var after: [GestureEvent] = []
        for i in 0..<6 {
            after += feed([SyntheticHand.fist(wrist: Vec2(0.3, 0.5 + Double(i) * 0.03))],
                          at: 0.55 + Double(i) / 30).events
        }
        XCTAssertTrue(moves(after).isEmpty, "a sustained fist parks the cursor")
        let (_, overlay) = feed([SyntheticHand.fist(wrist: Vec2(0.3, 0.68))], at: 0.78)
        XCTAssertFalse(overlay.armed)
        XCTAssertNotNil(overlay.cursor, "the claw stays parked where control was let go")

        // Reopening re-arms through the same debounce.
        let rearmed = feedFrames([SyntheticHand.mouseTap(indexDown: false, wrist: Vec2(0.6, 0.4))],
                                 from: 0.85, count: 3)
        XCTAssertEqual(moves(rearmed).count, 1, "an open hand takes the cursor back")
    }

    func testBriefDropoutKeepsControlArmed() {
        useOpenHandTrigger()
        feedFrames([SyntheticHand.openRelaxed()], from: 0, count: 4) // arms
        XCTAssertTrue(feed([], at: 0.15).events.isEmpty, "one lost frame is inside the grace")
        let back = feed([SyntheticHand.openRelaxed(wrist: Vec2(0.6, 0.7))], at: 0.183).events
        XCTAssertEqual(moves(back).count, 1,
                       "control survives a dropout shorter than the tracking-loss grace")
    }

    func testHandLossPastGraceRequiresReArm() {
        useOpenHandTrigger()
        feedFrames([SyntheticHand.openRelaxed()], from: 0, count: 4) // arms
        feed([], at: 0.5) // past the grace: the hand is really gone

        var events: [GestureEvent] = []
        for i in 0..<6 {
            events += feed([SyntheticHand.fist(wrist: Vec2(0.4 + Double(i) * 0.03, 0.6))],
                           at: 0.6 + Double(i) / 30).events
        }
        XCTAssertTrue(moves(events).isEmpty, "a returning hand must show the trigger again")
        let rearmed = feedFrames([SyntheticHand.openRelaxed(wrist: Vec2(0.4, 0.6))],
                                 from: 0.85, count: 3)
        XCTAssertEqual(moves(rearmed).count, 1)
    }

    func testOpenSecondHandTakesPrimaryWhileDisarmed() {
        useOpenHandTrigger()
        feedFrames([SyntheticHand.fist(wrist: Vec2(0.3, 0.7))], from: 0, count: 5)

        // A second, open hand appears: it — not the sticky closed primary —
        // gets to arm control and drive the cursor.
        var events: [GestureEvent] = []
        var lastOverlay = OverlayState()
        for i in 0..<4 {
            let (e, o) = feed([SyntheticHand.fist(wrist: Vec2(0.3, 0.7)),
                               SyntheticHand.openRelaxed(wrist: Vec2(0.7, 0.5))],
                              at: 0.2 + Double(i) / 30)
            events += e
            lastOverlay = o
        }
        XCTAssertEqual(moves(events).count, 1, "the open hand arms and the cursor jumps to it once")
        XCTAssertGreaterThan(moves(events)[0].x, 0.5, "…near the open hand, not the fist")
        XCTAssertTrue(lastOverlay.armed)
        XCTAssertEqual(lastOverlay.hands.count, 2)
        XCTAssertTrue(lastOverlay.hands[1].isPrimary, "the open hand (slot 1) is primary now")
    }

    func testSwitchingToOpenHandTriggerMidPressReleases() {
        feedFrames([SyntheticHand.mouseTap(indexDown: false)], from: 0, count: 3) // .anyHand test config
        XCTAssertEqual(downs(feedFrames([SyntheticHand.mouseTap(indexDown: true)],
                                        from: 0.1, count: 3)).count, 1)

        engine.config.controlTrigger = .openHand

        let next = feed([SyntheticHand.mouseTap(indexDown: true)], at: 0.25).events
        XCTAssertEqual(ups(next).count, 1, "a trigger change must not strand the button down")
        let more = feedFrames([SyntheticHand.mouseTap(indexDown: true)], from: 0.283, count: 10)
        XCTAssertTrue(downs(more).isEmpty, "…and the un-triggered hand cannot re-press")

        // Re-arm somewhere else: an in-place reopen would land inside the
        // jitter deadband (the palm anchor never moved).
        let rearmed = feedFrames([SyntheticHand.mouseTap(indexDown: false, wrist: Vec2(0.6, 0.5))],
                                 from: 0.65, count: 3)
        XCTAssertEqual(moves(rearmed).count, 1, "showing the trigger takes control back")
    }

    func testSwitchingToAnyHandTriggerMidPressKeepsThePress() {
        useOpenHandTrigger()
        feedFrames([SyntheticHand.mouseTap(indexDown: false)], from: 0, count: 4) // arms
        XCTAssertEqual(downs(feedFrames([SyntheticHand.mouseTap(indexDown: true)],
                                        from: 0.15, count: 3)).count, 1)

        engine.config.controlTrigger = .anyHand

        let held = feedFrames([SyntheticHand.mouseTap(indexDown: true)], from: 0.3, count: 5)
        XCTAssertTrue(ups(held).isEmpty, "loosening the trigger must not interrupt the press")
        XCTAssertEqual(ups(feedFrames([SyntheticHand.mouseTap(indexDown: false)],
                                      from: 0.5, count: 3)).count, 1)
    }

    func testAnyHandModeIsAlwaysArmed() {
        let (events, overlay) = feed([SyntheticHand.fist()], at: 0)
        XCTAssertEqual(moves(events).count, 1,
                       "legacy behavior: any tracked hand moves the cursor at once")
        XCTAssertTrue(overlay.armed)
    }

    // MARK: - Auto reach

    /// The test config with auto reach turned back on (it starts from the
    /// identity box, so every drift is visible).
    private func useAutoReach() {
        var config = Self.testConfig()
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
        var config = Self.testConfig()
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
