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

    private func downs(_ events: [GestureEvent], _ button: MouseButton) -> [(Vec2, Int)] {
        events.compactMap {
            if case .buttonDown(let b, let at, let cc) = $0, b == button { return (at, cc) }
            return nil
        }
    }

    private func ups(_ events: [GestureEvent], _ button: MouseButton) -> [(Vec2, Int)] {
        events.compactMap {
            if case .buttonUp(let b, let at, let cc) = $0, b == button { return (at, cc) }
            return nil
        }
    }

    private func drags(_ events: [GestureEvent], _ button: MouseButton) -> [Vec2] {
        events.compactMap {
            if case .drag(let b, let to) = $0, b == button { return to }
            return nil
        }
    }

    private func moves(_ events: [GestureEvent]) -> [Vec2] {
        events.compactMap {
            if case .move(let to) = $0 { return to }
            return nil
        }
    }

    private func scrolls(_ events: [GestureEvent]) -> [(dx: Double, dy: Double)] {
        events.compactMap {
            if case .scroll(let dx, let dy, _) = $0 { return (dx, dy) }
            return nil
        }
    }

    // MARK: - Pre-click stabilization

    func testDefaultPointerSourceIsIndexTip() {
        XCTAssertEqual(GestureConfig.default.pointerSource, .indexTip)
    }

    func testPinchApproachRollsBackAndClickLandsPrePinch() {
        // Establish a cursor while pointing.
        feedFrames([SyntheticHand.openRelaxed(wrist: Vec2(0.5, 0.7))], from: 0, count: 8)
        let (_, before) = feed([SyntheticHand.openRelaxed(wrist: Vec2(0.5, 0.7))], at: 0.3)
        let prePinchCursor = before.cursor!

        // Fingers converging (ratio in the band): the index tip has moved, but
        // the cursor must roll back to / hold the pre-convergence position.
        let (_, held) = feed([SyntheticHand.pinchIndex(gap: 0.55, wrist: Vec2(0.5, 0.7))], at: 0.333)
        XCTAssertEqual(held.cursor!.distance(to: prePinchCursor), 0, accuracy: 0.03,
                       "converging fingers must not drag the cursor")

        // Engage: the click lands at the pre-pinch position.
        let events = feed([SyntheticHand.pinchIndex(gap: 0.1, wrist: Vec2(0.5, 0.7))], at: 0.366).events
        let d = downs(events, .left)
        XCTAssertEqual(d.count, 1)
        XCTAssertEqual(d[0].0.distance(to: prePinchCursor), 0, accuracy: 0.03,
                       "click lands where you were pointing before the pinch motion")
    }

    func testAbandonedApproachResumesTracking() {
        feedFrames([SyntheticHand.openRelaxed(wrist: Vec2(0.5, 0.7))], from: 0, count: 6)
        // Enter the band briefly, then open back up without engaging.
        feedFrames([SyntheticHand.pinchIndex(gap: 0.55, wrist: Vec2(0.5, 0.7))], from: 0.25, count: 3)
        let resumed = feed([SyntheticHand.openRelaxed(wrist: Vec2(0.62, 0.7))], at: 0.4).events
        XCTAssertFalse(moves(resumed).isEmpty, "abandoning the pinch resumes cursor tracking")
    }

    func testHoveringInBandTimesOutAndResumes() {
        feedFrames([SyntheticHand.openRelaxed(wrist: Vec2(0.5, 0.7))], from: 0, count: 6)
        // Sit in the band well past the hold limit (0.5 s), while moving.
        var lateMoves: [Vec2] = []
        for i in 0..<25 { // 0.83 s
            let t = 0.25 + Double(i) / 30
            let wrist = Vec2(0.5 + Double(i) * 0.004, 0.7)
            let e = feed([SyntheticHand.pinchIndex(gap: 0.55, wrist: wrist)], at: t).events
            if t > 0.85 { lateMoves += moves(e) }
        }
        XCTAssertFalse(lateMoves.isEmpty,
                       "hovering in the band must eventually resume tracking")
    }

    func testReleaseDoesNotDragCursor() {
        // Down, then a release frame where the fingers have separated wide:
        // the up must land exactly at the down position (no smear into a drag).
        feedFrames([SyntheticHand.openRelaxed(wrist: Vec2(0.5, 0.7))], from: 0, count: 6)
        let down = feedFrames([SyntheticHand.pinchIndex(gap: 0.1, wrist: Vec2(0.5, 0.7))], from: 0.25, count: 2)
        let downPos = downs(down, .left)[0].0
        let release = feedFrames([SyntheticHand.openRelaxed(wrist: Vec2(0.5, 0.7))], from: 0.35, count: 2)
        XCTAssertTrue(drags(release, .left).isEmpty,
                      "separating fingers must not emit drags before the up")
        let u = ups(release, .left)
        XCTAssertEqual(u.count, 1)
        XCTAssertEqual(u[0].0.distance(to: downPos), 0, accuracy: 1e-9)
    }

    // MARK: - Cursor movement

    func testCursorFollowsHand() {
        let e1 = feed([SyntheticHand.openRelaxed(wrist: Vec2(0.5, 0.7))], at: 0).events
        let m1 = moves(e1)
        XCTAssertEqual(m1.count, 1)

        let e2 = feed([SyntheticHand.openRelaxed(wrist: Vec2(0.6, 0.7))], at: 1 / 30.0).events
        let m2 = moves(e2)
        XCTAssertEqual(m2.count, 1)
        XCTAssertEqual(m2[0].x - m1[0].x, 0.1, accuracy: 1e-6)
        XCTAssertEqual(m2[0].y, m1[0].y, accuracy: 1e-6)
    }

    func testNoMoveEventWhenStationary() {
        feed([SyntheticHand.openRelaxed()], at: 0)
        let e = feed([SyntheticHand.openRelaxed()], at: 1 / 30.0).events
        XCTAssertTrue(moves(e).isEmpty, "identical frame must not emit a move")
    }

    func testOverlayShowsFingertipsAndCursor() {
        let (_, overlay) = feed([SyntheticHand.openRelaxed()], at: 0)
        XCTAssertEqual(overlay.hands.count, 1)
        XCTAssertEqual(overlay.hands[0].fingertips.count, 5)
        XCTAssertTrue(overlay.hands[0].isPrimary)
        XCTAssertNotNil(overlay.cursor)
        XCTAssertEqual(overlay.mode, .pointing)
    }

    // MARK: - Clicks

    func testCasualPinchWithHalfCurledFingersClicks() {
        // The natural human pinch: middle/ring/little casually half-bent.
        // Regression test — an openness-based guard used to veto this.
        feedFrames([SyntheticHand.openRelaxed()], from: 0, count: 3)
        let down = feedFrames([SyntheticHand.pinchIndexCasual(gap: 0.1)], from: 0.1, count: 2)
        XCTAssertEqual(downs(down, .left).count, 1,
                       "a pinch with relaxed-curled fingers must click")
        let up = feedFrames([SyntheticHand.openRelaxed()], from: 0.2, count: 2)
        XCTAssertEqual(ups(up, .left).count, 1)
    }

    func testQuickPinchIsSingleClick() {
        feedFrames([SyntheticHand.openRelaxed()], from: 0, count: 3)
        let pinchEvents = feedFrames([SyntheticHand.pinchIndex(gap: 0.1)], from: 0.1, count: 2)
        let d = downs(pinchEvents, .left)
        XCTAssertEqual(d.count, 1)
        XCTAssertEqual(d[0].1, 1, "first click has clickCount 1")
        XCTAssertTrue(drags(pinchEvents, .left).isEmpty, "a stationary pinch must not drag")

        let releaseEvents = feedFrames([SyntheticHand.openRelaxed()], from: 0.2, count: 2)
        let u = ups(releaseEvents, .left)
        XCTAssertEqual(u.count, 1)
        XCTAssertEqual(u[0].1, 1)
        XCTAssertEqual(u[0].0.distance(to: d[0].0), 0, accuracy: 1e-9,
                       "click up lands exactly where down landed")
    }

    func testDoubleAndTripleClickChaining() {
        feedFrames([SyntheticHand.openRelaxed()], from: 0, count: 3)

        let c1 = feedFrames([SyntheticHand.pinchIndex(gap: 0.1)], from: 0.10, count: 2)
            + feedFrames([SyntheticHand.openRelaxed()], from: 0.1667, count: 2)
        XCTAssertEqual(downs(c1, .left).map(\.1), [1])
        XCTAssertEqual(ups(c1, .left).map(\.1), [1])

        // Second click 0.1s later, same spot → double.
        let c2 = feedFrames([SyntheticHand.pinchIndex(gap: 0.1)], from: 0.30, count: 2)
            + feedFrames([SyntheticHand.openRelaxed()], from: 0.3667, count: 2)
        XCTAssertEqual(downs(c2, .left).map(\.1), [2])
        XCTAssertEqual(ups(c2, .left).map(\.1), [2])

        // Third quick click → triple (capped at 3).
        let c3 = feedFrames([SyntheticHand.pinchIndex(gap: 0.1)], from: 0.50, count: 2)
            + feedFrames([SyntheticHand.openRelaxed()], from: 0.5667, count: 2)
        XCTAssertEqual(downs(c3, .left).map(\.1), [3])

        // A fourth quick click restarts the chain at 1 — it must not stay
        // pinned at triple-click forever.
        let c4 = feedFrames([SyntheticHand.pinchIndex(gap: 0.1)], from: 0.70, count: 2)
            + feedFrames([SyntheticHand.openRelaxed()], from: 0.7667, count: 2)
        XCTAssertEqual(downs(c4, .left).map(\.1), [1])

        // A slow follow-up also resets to a single click.
        let c5 = feedFrames([SyntheticHand.pinchIndex(gap: 0.1)], from: 2.5, count: 2)
            + feedFrames([SyntheticHand.openRelaxed()], from: 2.5667, count: 2)
        XCTAssertEqual(downs(c5, .left).map(\.1), [1])
    }

    func testSecondClickFarAwayIsSingle() {
        feedFrames([SyntheticHand.openRelaxed(wrist: Vec2(0.5, 0.7))], from: 0, count: 3)
        var events = feedFrames([SyntheticHand.pinchIndex(gap: 0.1, wrist: Vec2(0.5, 0.7))], from: 0.1, count: 2)
        events += feedFrames([SyntheticHand.openRelaxed(wrist: Vec2(0.5, 0.7))], from: 0.1667, count: 2)
        XCTAssertEqual(downs(events, .left).map(\.1), [1])

        // Move far, then click again quickly: position slop breaks the chain.
        feedFrames([SyntheticHand.openRelaxed(wrist: Vec2(0.8, 0.5))], from: 0.25, count: 2)
        let events2 = feedFrames([SyntheticHand.pinchIndex(gap: 0.1, wrist: Vec2(0.8, 0.5))], from: 0.32, count: 2)
        XCTAssertEqual(downs(events2, .left).map(\.1), [1])
    }

    // MARK: - Drag / hold

    func testDragEmitsDragsAndHoldsButton() {
        feedFrames([SyntheticHand.openRelaxed(wrist: Vec2(0.4, 0.7))], from: 0, count: 3)
        var events = feedFrames([SyntheticHand.pinchIndex(gap: 0.1, wrist: Vec2(0.4, 0.7))], from: 0.1, count: 2)
        XCTAssertEqual(downs(events, .left).count, 1)

        // Drag right in steps while pinched.
        var dragPositions: [Vec2] = []
        for i in 1...6 {
            let wrist = Vec2(0.4 + Double(i) * 0.03, 0.7)
            let e = feed([SyntheticHand.pinchIndex(gap: 0.1, wrist: wrist)], at: 0.2 + Double(i) / 30).events
            dragPositions += drags(e, .left)
            XCTAssertTrue(moves(e).isEmpty, "no plain moves while a button is held")
            XCTAssertTrue(ups(e, .left).isEmpty, "button stays down while pinch is held")
        }
        XCTAssertGreaterThanOrEqual(dragPositions.count, 5)
        XCTAssertGreaterThan(dragPositions.last!.x, dragPositions.first!.x)

        events = feedFrames([SyntheticHand.openRelaxed(wrist: Vec2(0.58, 0.7))], from: 0.5, count: 2)
        let u = ups(events, .left)
        XCTAssertEqual(u.count, 1)
        // The release frame's pose transition shifts the pointer a hair before
        // the up fires, so compare against the drag end loosely.
        XCTAssertEqual(u[0].0.x, dragPositions.last!.x, accuracy: 0.005, "up lands at the drag end")
    }

    func testMicroMovementWhilePinchedDoesNotDrag() {
        feedFrames([SyntheticHand.openRelaxed(wrist: Vec2(0.5, 0.7))], from: 0, count: 3)
        feedFrames([SyntheticHand.pinchIndex(gap: 0.1, wrist: Vec2(0.5, 0.7))], from: 0.1, count: 2)
        // 0.003 normalized wobble — under the 0.008 drag threshold.
        let e = feedFrames([SyntheticHand.pinchIndex(gap: 0.1, wrist: Vec2(0.503, 0.7))], from: 0.2, count: 3)
        XCTAssertTrue(drags(e, .left).isEmpty, "micro-movement must not start a drag")
        let up = feedFrames([SyntheticHand.openRelaxed(wrist: Vec2(0.503, 0.7))], from: 0.32, count: 2)
        XCTAssertEqual(ups(up, .left).count, 1)
    }

    func testLongHoldNeverTimesOut() {
        feedFrames([SyntheticHand.openRelaxed()], from: 0, count: 3)
        var events = feedFrames([SyntheticHand.pinchIndex(gap: 0.1)], from: 0.1, count: 90) // 3 s hold
        XCTAssertEqual(downs(events, .left).count, 1)
        XCTAssertTrue(ups(events, .left).isEmpty, "hold must persist indefinitely")
        events = feedFrames([SyntheticHand.openRelaxed()], from: 3.2, count: 2)
        XCTAssertEqual(ups(events, .left).count, 1)
    }

    // MARK: - Right click

    func testMiddlePinchIsRightClick() {
        feedFrames([SyntheticHand.openRelaxed()], from: 0, count: 3)
        let down = feedFrames([SyntheticHand.pinchFinger(.middle, gap: 0.1)], from: 0.1, count: 2)
        XCTAssertEqual(downs(down, .right).count, 1)
        XCTAssertTrue(downs(down, .left).isEmpty)
        let up = feedFrames([SyntheticHand.openRelaxed()], from: 0.2, count: 2)
        XCTAssertEqual(ups(up, .right).count, 1)
    }

    func testRightDragWorks() {
        feedFrames([SyntheticHand.openRelaxed(wrist: Vec2(0.4, 0.7))], from: 0, count: 3)
        feedFrames([SyntheticHand.pinchFinger(.middle, gap: 0.1, wrist: Vec2(0.4, 0.7))], from: 0.1, count: 2)
        var dragged: [Vec2] = []
        for i in 1...5 {
            let e = feed([SyntheticHand.pinchFinger(.middle, gap: 0.1, wrist: Vec2(0.4 + Double(i) * 0.03, 0.7))],
                         at: 0.2 + Double(i) / 30).events
            dragged += drags(e, .right)
        }
        XCTAssertGreaterThanOrEqual(dragged.count, 4, "right-button drags (hold) must work")
    }

    func testConfigurableRightClickFinger() {
        var config = Self.testConfig()
        config.rightClickFinger = .ring
        engine = GestureEngine(config: config)
        feedFrames([SyntheticHand.openRelaxed()], from: 0, count: 3)
        let e = feedFrames([SyntheticHand.pinchFinger(.ring, gap: 0.1)], from: 0.1, count: 2)
        XCTAssertEqual(downs(e, .right).count, 1)
    }

    func testRightBlockedWhileLeftEngaged() {
        feedFrames([SyntheticHand.openRelaxed()], from: 0, count: 3)
        feedFrames([SyntheticHand.pinchIndex(gap: 0.1)], from: 0.1, count: 2)
        // While the index pinch is held, force the middle tip next to the thumb.
        var sneaky = SyntheticHand.pinchIndex(gap: 0.1)
        sneaky.setPoint(sneaky[.thumbTip]! + Vec2(0.005, 0), for: .middleTip)
        let e = feedFrames([sneaky], from: 0.2, count: 3)
        XCTAssertTrue(downs(e, .right).isEmpty, "no right-click while left pinch is held")
    }

    // MARK: - Hysteresis

    func testHysteresisPreventsFlapping() {
        feedFrames([SyntheticHand.openRelaxed()], from: 0, count: 3)
        // Ratios in the dead band (0.45–0.68) must not engage…
        let e1 = feedFrames([SyntheticHand.pinchIndex(gap: 0.55)], from: 0.1, count: 3)
            + feedFrames([SyntheticHand.pinchIndex(gap: 0.62)], from: 0.2, count: 3)
        XCTAssertTrue(downs(e1, .left).isEmpty)

        // …engage below 0.45…
        let e2 = feedFrames([SyntheticHand.pinchIndex(gap: 0.30)], from: 0.3, count: 2)
        XCTAssertEqual(downs(e2, .left).count, 1)

        // …stay engaged through the dead band…
        let e3 = feedFrames([SyntheticHand.pinchIndex(gap: 0.55)], from: 0.4, count: 3)
            + feedFrames([SyntheticHand.pinchIndex(gap: 0.64)], from: 0.5, count: 3)
        XCTAssertTrue(ups(e3, .left).isEmpty, "dead band must not release")

        // …and release only above 0.68.
        let e4 = feedFrames([SyntheticHand.pinchIndex(gap: 0.80)], from: 0.6, count: 2)
        XCTAssertEqual(ups(e4, .left).count, 1)
    }

    // MARK: - Scroll

    func testTwoFingerScroll() {
        feedFrames([SyntheticHand.openRelaxed(wrist: Vec2(0.5, 0.7))], from: 0, count: 3)
        // Hold the pose through the debounce.
        feedFrames([SyntheticHand.twoFingerPoint(wrist: Vec2(0.5, 0.7))], from: 0.1, count: 4)
        let (_, overlay) = feed([SyntheticHand.twoFingerPoint(wrist: Vec2(0.5, 0.7))], at: 0.25)
        XCTAssertEqual(overlay.mode, .scrolling)

        // Move the hand up → positive dy with natural scrolling.
        var all: [GestureEvent] = []
        for i in 1...5 {
            let e = feed([SyntheticHand.twoFingerPoint(wrist: Vec2(0.5, 0.7 - Double(i) * 0.02))],
                         at: 0.3 + Double(i) / 30).events
            all += e
            XCTAssertTrue(moves(e).isEmpty, "cursor stays frozen while scrolling")
        }
        let s = scrolls(all)
        XCTAssertGreaterThanOrEqual(s.count, 4)
        XCTAssertTrue(s.allSatisfy { $0.dy > 0 }, "hand up + natural scroll → positive dy")
        XCTAssertTrue(downs(all, .left).isEmpty)

        // Leaving the pose resumes pointing.
        let (_, o2) = feed([SyntheticHand.openRelaxed(wrist: Vec2(0.5, 0.6))], at: 0.6)
        XCTAssertEqual(o2.mode, .pointing)
    }

    func testUnnaturalScrollFlipsSign() {
        var config = Self.testConfig()
        config.naturalScroll = false
        engine = GestureEngine(config: config)
        feedFrames([SyntheticHand.openRelaxed(wrist: Vec2(0.5, 0.7))], from: 0, count: 3)
        feedFrames([SyntheticHand.twoFingerPoint(wrist: Vec2(0.5, 0.7))], from: 0.1, count: 4)
        var all: [GestureEvent] = []
        for i in 1...4 {
            all += feed([SyntheticHand.twoFingerPoint(wrist: Vec2(0.5, 0.7 - Double(i) * 0.02))],
                        at: 0.3 + Double(i) / 30).events
        }
        XCTAssertTrue(scrolls(all).allSatisfy { $0.dy < 0 })
    }

    func testScrollDisabledConfig() {
        var config = Self.testConfig()
        config.scrollEnabled = false
        engine = GestureEngine(config: config)
        feedFrames([SyntheticHand.openRelaxed()], from: 0, count: 3)
        feedFrames([SyntheticHand.twoFingerPoint()], from: 0.1, count: 6)
        let (events, overlay) = feed([SyntheticHand.twoFingerPoint(wrist: Vec2(0.55, 0.7))], at: 0.35)
        XCTAssertNotEqual(overlay.mode, .scrolling)
        XCTAssertTrue(scrolls(events).isEmpty)
        XCTAssertFalse(moves(events).isEmpty, "cursor keeps moving when scroll is disabled")
    }

    // MARK: - Clutch

    func testFistClutchFreezesSnapsBackAndReanchors() {
        // Establish cursor at A.
        feedFrames([SyntheticHand.openRelaxed(wrist: Vec2(0.5, 0.7))], from: 0, count: 8)
        let cursorA = engineCursor()

        // Form a fist and hold it through the debounce.
        let fistEvents = feedFrames([SyntheticHand.fist(wrist: Vec2(0.5, 0.7))], from: 0.3, count: 5)
        XCTAssertTrue(downs(fistEvents, .left).isEmpty,
                      "curling into a fist must not fire a click (openness guard)")
        let (_, overlay) = feed([SyntheticHand.fist(wrist: Vec2(0.5, 0.7))], at: 0.5)
        XCTAssertEqual(overlay.mode, .clutch)
        XCTAssertEqual(overlay.cursor!.distance(to: cursorA), 0, accuracy: 0.01,
                       "clutch engage snaps the cursor back to its pre-fist position")

        // Move the fist far away: cursor must not move.
        let during = feedFrames([SyntheticHand.fist(wrist: Vec2(0.8, 0.4))], from: 0.55, count: 5)
        XCTAssertTrue(moves(during).isEmpty, "cursor frozen during clutch")

        // Reopen at the new spot: cursor stays where it froze (re-anchored)…
        let reopen = feedFrames([SyntheticHand.openRelaxed(wrist: Vec2(0.8, 0.4))], from: 0.75, count: 3)
        for m in moves(reopen) {
            XCTAssertEqual(m.distance(to: cursorA), 0, accuracy: 0.02,
                           "cursor must not jump to the hand's new absolute position")
        }

        // …and subsequent movement continues relative from there.
        let after = feed([SyntheticHand.openRelaxed(wrist: Vec2(0.85, 0.4))], at: 0.9).events
        let m = moves(after)
        XCTAssertEqual(m.count, 1)
        XCTAssertEqual(m[0].x - cursorA.x, 0.05, accuracy: 0.02)
    }

    private func engineCursor() -> Vec2 {
        let (_, overlay) = engine.process(HandFrame(time: 0.29, hands: [SyntheticHand.openRelaxed(wrist: Vec2(0.5, 0.7))]))
        return overlay.cursor!
    }

    // MARK: - Dictation toggle

    func testSplayHoldTogglesOnce() {
        var toggles = 0
        for i in 0..<30 { // 1 s of splay at 30 fps
            let (events, overlay) = feed([SyntheticHand.openSplayed()], at: Double(i) / 30)
            toggles += events.filter { $0 == .dictationToggle }.count
            if Double(i) / 30 < 0.7, toggles == 0 {
                XCTAssertNotNil(overlay.dictationHoldProgress, "hold progress shown while holding")
            }
        }
        XCTAssertEqual(toggles, 1, "held splay fires exactly once")

        // Release, then splay again → second toggle.
        feedFrames([SyntheticHand.openRelaxed()], from: 1.1, count: 3)
        var toggles2 = 0
        for i in 0..<30 {
            let (events, _) = feed([SyntheticHand.openSplayed()], at: 1.3 + Double(i) / 30)
            toggles2 += events.filter { $0 == .dictationToggle }.count
        }
        XCTAssertEqual(toggles2, 1)
    }

    func testRelaxedHandNeverToggles() {
        var toggles = 0
        for i in 0..<60 {
            toggles += feed([SyntheticHand.openRelaxed()], at: Double(i) / 30).events
                .filter { $0 == .dictationToggle }.count
        }
        XCTAssertEqual(toggles, 0)
    }

    func testShortSplayDoesNotToggle() {
        var toggles = 0
        for i in 0..<12 { // 0.4 s < 0.75 s hold
            toggles += feed([SyntheticHand.openSplayed()], at: Double(i) / 30).events
                .filter { $0 == .dictationToggle }.count
        }
        toggles += feedFrames([SyntheticHand.openRelaxed()], from: 0.5, count: 5)
            .filter { $0 == .dictationToggle }.count
        XCTAssertEqual(toggles, 0)
    }

    func testShakaToggleWhenConfigured() {
        var config = Self.testConfig()
        config.dictationToggle = .shakaHold
        engine = GestureEngine(config: config)
        var toggles = 0
        for i in 0..<30 {
            toggles += feed([SyntheticHand.shaka()], at: Double(i) / 30).events
                .filter { $0 == .dictationToggle }.count
        }
        XCTAssertEqual(toggles, 1)

        // Splay must NOT toggle in shaka mode.
        engine = GestureEngine(config: config)
        var splayToggles = 0
        for i in 0..<30 {
            splayToggles += feed([SyntheticHand.openSplayed()], at: Double(i) / 30).events
                .filter { $0 == .dictationToggle }.count
        }
        XCTAssertEqual(splayToggles, 0)
    }

    func testTwoHandSplayToggle() {
        var config = Self.testConfig()
        config.dictationToggle = .twoHandSplay
        engine = GestureEngine(config: config)

        // One splayed hand is not enough.
        var toggles = 0
        for i in 0..<30 {
            toggles += feed([SyntheticHand.openSplayed(wrist: Vec2(0.3, 0.7))], at: Double(i) / 30).events
                .filter { $0 == .dictationToggle }.count
        }
        XCTAssertEqual(toggles, 0)

        // Two splayed hands toggle.
        for i in 0..<30 {
            toggles += feed(
                [SyntheticHand.openSplayed(wrist: Vec2(0.3, 0.7)),
                 SyntheticHand.openSplayed(wrist: Vec2(0.75, 0.7))],
                at: 1.5 + Double(i) / 30).events
                .filter { $0 == .dictationToggle }.count
        }
        XCTAssertEqual(toggles, 1)
    }

    func testToggleDisabled() {
        var config = Self.testConfig()
        config.dictationToggle = .off
        engine = GestureEngine(config: config)
        var toggles = 0
        for i in 0..<40 {
            toggles += feed([SyntheticHand.openSplayed()], at: Double(i) / 30).events
                .filter { $0 == .dictationToggle }.count
        }
        XCTAssertEqual(toggles, 0)
    }

    // MARK: - Tracking loss and confidence

    func testTrackingLossReleasesHeldButtonAfterGrace() {
        feedFrames([SyntheticHand.openRelaxed()], from: 0, count: 3)
        feedFrames([SyntheticHand.pinchIndex(gap: 0.1)], from: 0.1, count: 3)

        // Within the grace window: nothing released.
        let e1 = feed([], at: 0.30).events
        XCTAssertTrue(ups(e1, .left).isEmpty)
        let (_, o1) = feed([], at: 0.40)
        XCTAssertTrue(o1.leftEngaged, "state held during grace")

        // Past the grace window: safety release.
        let e2 = feed([], at: 0.55).events
        XCTAssertEqual(ups(e2, .left).count, 1, "held button must release after tracking loss")

        // No repeated releases.
        XCTAssertTrue(ups(feed([], at: 0.7).events, .left).isEmpty)
    }

    func testBriefDropoutDoesNotReleaseDrag() {
        feedFrames([SyntheticHand.openRelaxed(wrist: Vec2(0.4, 0.7))], from: 0, count: 3)
        feedFrames([SyntheticHand.pinchIndex(gap: 0.1, wrist: Vec2(0.4, 0.7))], from: 0.1, count: 3)
        // One dropped frame.
        XCTAssertTrue(ups(feed([], at: 0.22).events, .left).isEmpty)
        // Hand returns, drag continues.
        let e = feed([SyntheticHand.pinchIndex(gap: 0.1, wrist: Vec2(0.5, 0.7))], at: 0.25).events
        XCTAssertTrue(ups(e, .left).isEmpty)
        XCTAssertFalse(drags(e, .left).isEmpty, "drag continues after a one-frame dropout")
    }

    func testLowConfidenceHandIsIgnored() {
        let (events, overlay) = feed([SyntheticHand.openRelaxed(confidence: 0.1)], at: 0)
        XCTAssertTrue(events.isEmpty)
        XCTAssertEqual(overlay.mode, .none)
    }

    func testForceReleaseEmitsUpAndBlocksChaining() {
        feedFrames([SyntheticHand.openRelaxed()], from: 0, count: 3)
        feedFrames([SyntheticHand.pinchIndex(gap: 0.1)], from: 0.1, count: 2)
        let released = engine.forceRelease(at: 0.2)
        XCTAssertEqual(ups(released, .left).count, 1)

        // A new pinch right after must be clickCount 1 (no chain into double).
        feedFrames([SyntheticHand.openRelaxed()], from: 0.25, count: 2)
        let e = feedFrames([SyntheticHand.pinchIndex(gap: 0.1)], from: 0.32, count: 2)
        XCTAssertEqual(downs(e, .left).map(\.1), [1])
    }

    // MARK: - Two hands

    func testPrimaryHandIsSticky() {
        // Hand A alone becomes primary.
        feedFrames([SyntheticHand.openRelaxed(wrist: Vec2(0.3, 0.7))], from: 0, count: 3)
        // Hand B joins; A stays primary and keeps driving the cursor.
        let (_, overlay) = feed(
            [SyntheticHand.openRelaxed(wrist: Vec2(0.3, 0.7)),
             SyntheticHand.openRelaxed(wrist: Vec2(0.75, 0.7))],
            at: 0.2)
        XCTAssertEqual(overlay.hands.count, 2)
        XCTAssertEqual(overlay.hands.filter(\.isPrimary).count, 1)

        // Moving B does not move the cursor.
        let before = overlay.cursor!
        let (events, o2) = feed(
            [SyntheticHand.openRelaxed(wrist: Vec2(0.3, 0.7)),
             SyntheticHand.openRelaxed(wrist: Vec2(0.6, 0.5))],
            at: 0.3)
        XCTAssertTrue(moves(events).isEmpty)
        XCTAssertEqual(o2.cursor!, before)
    }

    func testPinchStrengthRamp() {
        XCTAssertEqual(GestureEngine.pinchStrength(ratio: 0.3), 1.0)
        XCTAssertEqual(GestureEngine.pinchStrength(ratio: 0.9), 0.0)
        XCTAssertEqual(GestureEngine.pinchStrength(ratio: 0.65), 0.5, accuracy: 1e-9)
    }
}
