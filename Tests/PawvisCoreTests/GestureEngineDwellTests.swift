import XCTest
@testable import PawvisCore

/// The dwell-to-click story: with cursor control armed and nothing else in
/// flight, a cursor held inside a small radius for `dwellSeconds` clicks
/// where it settled — once — and must leave that radius before it may dwell
/// again. Every press, scroll, and park stands it down; real clicks and
/// tracking loss reset its clock.
final class GestureEngineDwellTests: XCTestCase {
    var engine: GestureEngine!

    /// The shared engine test config (identity mapping, no smoothing,
    /// `.anyHand`) with dwell click switched on at its 1.0 s default.
    static func dwellConfig() -> GestureConfig {
        var config = GestureEngineTests.testConfig()
        config.dwellClickEnabled = true
        return config
    }

    override func setUp() {
        super.setUp()
        engine = GestureEngine(config: Self.dwellConfig())
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

    private func rightDowns(_ events: [GestureEvent]) -> [(Vec2, Int)] {
        events.compactMap {
            if case .buttonDown(.right, let at, let cc) = $0 { return (at, cc) }
            return nil
        }
    }

    // MARK: - Config

    func testDwellDefaultsOffWithAOneSecondTimer() {
        let c = GestureConfig.default
        XCTAssertFalse(c.dwellClickEnabled, "dwell click is strictly opt-in")
        XCTAssertEqual(c.dwellSeconds, 1.0, accuracy: 1e-9)
        XCTAssertEqual(c.pointerSource, .palmCenter,
                       "the cursor rides the palm unless asked otherwise")
    }

    func testDwellAndPointerFieldsDecodeAndTolerateGarbage() throws {
        let known = try JSONDecoder().decode(GestureConfig.self, from: Data(
            #"{"dwellClickEnabled":true,"dwellSeconds":2.5,"pointerSource":"indexTip"}"#.utf8))
        XCTAssertTrue(known.dwellClickEnabled)
        XCTAssertEqual(known.dwellSeconds, 2.5, accuracy: 1e-9)
        XCTAssertEqual(known.pointerSource, .indexTip)

        let bogus = try JSONDecoder().decode(GestureConfig.self, from: Data(
            #"{"dwellClickEnabled":"sure","dwellSeconds":"soon","pointerSource":"nose"}"#.utf8))
        XCTAssertFalse(bogus.dwellClickEnabled, "a mistyped field keeps its default")
        XCTAssertEqual(bogus.dwellSeconds, 1.0, accuracy: 1e-9)
        XCTAssertEqual(bogus.pointerSource, .palmCenter)
    }

    func testDwellOffMeansNoDwellClicksEver() {
        engine = GestureEngine(config: GestureEngineTests.testConfig()) // dwell off
        let events = feedFrames([SyntheticHand.openRelaxed()], from: 0, count: 60) // 2 s still
        XCTAssertTrue(downs(events).isEmpty, "a still cursor never clicks unless the setting is on")
        let (_, overlay) = feed([SyntheticHand.openRelaxed()], at: 2.05)
        XCTAssertEqual(overlay.dwellProgress, 0, accuracy: 1e-9)
    }

    // MARK: - The dwell itself

    func testStillCursorClicksOnceAfterTheDwellTime() {
        let hand = SyntheticHand.openRelaxed()
        let expected = hand[.wrist]!.midpoint(with: hand[.middleMCP]!)

        let early = feedFrames([hand], from: 0, count: 30) // up to 0.967 s
        XCTAssertTrue(downs(early).isEmpty, "no click before the dwell time is up")

        let fired = feedFrames([hand], from: 1.0, count: 3)
        XCTAssertEqual(downs(fired).count, 1, "one second of stillness clicks")
        XCTAssertEqual(ups(fired).count, 1, "…a full down-and-up pair")
        XCTAssertEqual(downs(fired)[0].1, 1)
        XCTAssertEqual(downs(fired)[0].0.distance(to: expected), 0, accuracy: 1e-6,
                       "the click lands on the settled cursor")

        let rest = feedFrames([hand], from: 1.15, count: 90) // three more seconds
        XCTAssertTrue(downs(rest).isEmpty,
                      "a dwell must never machine-gun: no repeat until the cursor leaves")
    }

    func testDwellReArmsOnlyAfterTheCursorLeavesTheRadius() {
        feedFrames([SyntheticHand.openRelaxed()], from: 0, count: 33) // settles + fires
        // Wobble on the clicked spot for two more seconds: nothing.
        let wobbling = feedFrames([SyntheticHand.openRelaxed(wrist: Vec2(0.508, 0.7))],
                                  from: 1.2, count: 60)
        XCTAssertTrue(downs(wobbling).isEmpty, "wobble on the clicked spot must not re-dwell")

        // Move well clear and settle again: a fresh dwell clicks at the new spot.
        let moved = SyntheticHand.openRelaxed(wrist: Vec2(0.6, 0.5))
        let expected = moved[.wrist]!.midpoint(with: moved[.middleMCP]!)
        let fired = feedFrames([moved], from: 3.3, count: 33)
        XCTAssertEqual(downs(fired).count, 1, "movement is the re-arm")
        XCTAssertEqual(downs(fired)[0].0.distance(to: expected), 0, accuracy: 1e-6)
    }

    func testSlowDriftInsideTheRadiusStillDwells() {
        // Three settled spots a few thousandths apart, all inside the dwell
        // radius of the first: the anchor holds the clock, so slow drift
        // (which still emits moves) never restarts it.
        var events: [GestureEvent] = []
        events += feedFrames([SyntheticHand.openRelaxed(wrist: Vec2(0.5, 0.7))], from: 0, count: 12)
        events += feedFrames([SyntheticHand.openRelaxed(wrist: Vec2(0.506, 0.7))], from: 0.4, count: 12)
        XCTAssertTrue(downs(events).isEmpty, "still under the dwell time")
        let fired = feedFrames([SyntheticHand.openRelaxed(wrist: Vec2(0.512, 0.7))], from: 0.8, count: 12)
        XCTAssertEqual(downs(fired).count, 1,
                       "drift inside the radius counts as holding still")
    }

    func testDisablingDwellMidDwellStops() {
        feedFrames([SyntheticHand.openRelaxed()], from: 0, count: 24) // 0.77 s banked
        engine.config.dwellClickEnabled = false
        let after = feedFrames([SyntheticHand.openRelaxed()], from: 0.85, count: 60)
        XCTAssertTrue(downs(after).isEmpty, "the switch kills the running timer at once")
    }

    // MARK: - Presses always win

    func testDwellNeverFiresWhileTheLeftButtonIsHeld() {
        feedFrames([SyntheticHand.mouseTap(indexDown: false)], from: 0, count: 3)
        let pressed = feedFrames([SyntheticHand.mouseTap(indexDown: true)], from: 0.1, count: 60) // 2 s held
        XCTAssertEqual(downs(pressed).count, 1, "the real press, and nothing else")
        XCTAssertTrue(ups(pressed).isEmpty, "no dwell pair sneaked in while the button was down")
        let (_, overlay) = feed([SyntheticHand.mouseTap(indexDown: true)], at: 2.12)
        XCTAssertEqual(overlay.dwellProgress, 0, accuracy: 1e-9,
                       "no dwell ramp shows while a button is held")
        let released = feedFrames([SyntheticHand.mouseTap(indexDown: false)], from: 2.2, count: 3)
        XCTAssertEqual(ups(released).count, 1)
    }

    func testDwellNeverFiresWhileTheRightButtonIsHeld() {
        feedFrames([SyntheticHand.mouseTap(indexDown: false)], from: 0, count: 3)
        let held = feedFrames([SyntheticHand.fingerDip(.little)], from: 0.1, count: 60)
        XCTAssertEqual(rightDowns(held).count, 1)
        XCTAssertTrue(downs(held).isEmpty, "no dwell click while the right button is down")
    }

    func testDwellNeverFiresWhileTheMiddleButtonIsHeld() {
        var config = Self.dwellConfig()
        config.middleClickEnabled = true
        engine = GestureEngine(config: config)
        feedFrames([SyntheticHand.mouseTap(indexDown: false)], from: 0, count: 3)
        let held = feedFrames([SyntheticHand.fingerDip(.ring)], from: 0.1, count: 60) // 2 s
        let middleDowns = held.compactMap { event -> Vec2? in
            if case .buttonDown(.middle, let at, _) = event { return at }
            return nil
        }
        XCTAssertEqual(middleDowns.count, 1, "the real middle press, and nothing else")
        XCTAssertTrue(downs(held).isEmpty, "no dwell click while the middle button is down")
    }

    func testDwellNeverFiresMidDrag() {
        feedFrames([SyntheticHand.mouseTap(indexDown: false, wrist: Vec2(0.4, 0.7))], from: 0, count: 3)
        feedFrames([SyntheticHand.mouseTap(indexDown: true, wrist: Vec2(0.4, 0.7))], from: 0.1, count: 3)
        // A deliberate flick starts the drag, then the hand freezes mid-drag.
        feed([SyntheticHand.mouseTap(indexDown: true, wrist: Vec2(0.45, 0.7))], at: 0.2)
        let frozen = feedFrames([SyntheticHand.mouseTap(indexDown: true, wrist: Vec2(0.45, 0.7))],
                                from: 0.25, count: 60)
        XCTAssertTrue(downs(frozen).isEmpty, "a hand parked mid-drag must not dwell-click")
        XCTAssertTrue(ups(frozen).isEmpty, "…and the drag itself holds")
        let released = feedFrames([SyntheticHand.mouseTap(indexDown: false, wrist: Vec2(0.45, 0.7))],
                                  from: 2.3, count: 3)
        XCTAssertEqual(ups(released).count, 1)
    }

    func testARealClickResetsTheDwellTimer() {
        let open = SyntheticHand.mouseTap(indexDown: false)
        feedFrames([open], from: 0, count: 27) // 0.87 s of stillness — nearly there
        // A quick real tap lands (down on the second dipped frame, up on the
        // second open frame after).
        let clicked = feedFrames([SyntheticHand.mouseTap(indexDown: true)], from: 0.9, count: 3)
            + feedFrames([open], from: 1.0, count: 3)
        XCTAssertEqual(downs(clicked).count, 1, "the real tap clicks — dwell stands down")
        XCTAssertEqual(ups(clicked).count, 1)

        // Were the timer not reset, the banked 0.9 s would complete almost
        // immediately after the release. Instead a full dwell must elapse.
        let after = feedFrames([open], from: 1.1, count: 27) // up to 1.97 s
        XCTAssertTrue(downs(after).isEmpty, "real clicks win: the dwell clock restarts from zero")
        let dwellFired = feedFrames([open], from: 2.0, count: 5)
        XCTAssertEqual(downs(dwellFired).count, 1,
                       "…and a full dwell after the click still fires")
    }

    // MARK: - Scrolls and parks stand the dwell down

    func testDwellNeverFiresWhileScrolling() {
        feedFrames([SyntheticHand.openRelaxed()], from: 0, count: 3)
        // The pose engages and holds perfectly still: a parked scroll, not a dwell.
        let scrolling = feedFrames([SyntheticHand.scrollPose()], from: 0.1, count: 60) // 2 s
        XCTAssertTrue(downs(scrolling).isEmpty, "a still scroll pose must never click")

        // Reopening restarts the clock from zero at the parked spot.
        let reopened = feedFrames([SyntheticHand.openRelaxed()], from: 2.2, count: 27)
        XCTAssertTrue(downs(reopened).isEmpty, "the timer restarts after the scroll")
        let fired = feedFrames([SyntheticHand.openRelaxed()], from: 3.1, count: 6)
        XCTAssertEqual(downs(fired).count, 1)
    }

    func testDwellNeverFiresWhilePointedParked() {
        feedFrames([SyntheticHand.openRelaxed()], from: 0, count: 4)
        // A hand pointed at the screen parks the cursor; holding it dead
        // still must never turn the park into a click.
        let pointed = feedFrames([SyntheticHand.pointedHand(struck: false)], from: 0.15, count: 60)
        XCTAssertTrue(downs(pointed).isEmpty, "the pointed park blocks the dwell")
    }

    func testDwellNeverFiresWhileTheCrissCrossWaveIsEngaged() {
        // Two open, splayed hands standing still: the wave engages and both
        // buttons are barred — the dwell must be barred with them. (Kept
        // under the wave's 2 s stall timeout.)
        let pair = [SyntheticHand.openSplayed(wrist: Vec2(0.3, 0.7), chirality: .left),
                    SyntheticHand.openSplayed(wrist: Vec2(0.7, 0.7), chirality: .right)]
        let events = feedFrames(pair, from: 0, count: 45) // 1.5 s
        XCTAssertTrue(downs(events).isEmpty, "an engaged wave blocks the dwell")
    }

    func testDwellNeverFiresWhileAGrabIsParked() {
        var custom = CustomGestureDetector.Config()
        custom.enabled = [.grabFlingRight]
        engine.customConfig = custom

        feedFrames([SyntheticHand.openRelaxed()], from: 0, count: 3)
        // Gather in place and hold: the grab engages and parks the cursor.
        // (Kept under the fling's 2 s stall timeout.)
        let held = feedFrames([SyntheticHand.gathered()], from: 0.1, count: 50)
        XCTAssertTrue(downs(held).isEmpty, "a held grab parks the cursor — no dwell click")
    }

    func testDwellNeverFiresWhileControlIsDisarmed() {
        var config = Self.dwellConfig()
        config.controlTrigger = .openHand
        engine = GestureEngine(config: config)

        feedFrames([SyntheticHand.openRelaxed()], from: 0, count: 4) // arms
        // A sustained fist disarms control; the parked cursor then sits
        // perfectly still for two seconds — and must never click.
        let events = feedFrames([SyntheticHand.fist()], from: 0.15, count: 70)
        XCTAssertTrue(downs(events).isEmpty, "a parked cursor never dwells")
        let (_, overlay) = feed([SyntheticHand.fist()], at: 2.5)
        XCTAssertFalse(overlay.armed)
    }

    // MARK: - Tracking loss

    func testTrackingLossResetsTheDwell() {
        let hand = SyntheticHand.openRelaxed()
        feedFrames([hand], from: 0, count: 24) // 0.77 s banked
        feed([], at: 1.4) // past the grace: the hand is really gone

        // The hand returns to the very same spot: were the clock not reset,
        // the stale anchor would fire immediately (1.5 s have "elapsed").
        let returned = feedFrames([hand], from: 1.5, count: 28) // up to 2.4 s
        XCTAssertTrue(downs(returned).isEmpty, "tracking loss resets the dwell")
        let fired = feedFrames([hand], from: 2.5, count: 5)
        XCTAssertEqual(downs(fired).count, 1, "…and a full fresh dwell still clicks")
    }

    // MARK: - Progress for the overlay ring

    func testDwellProgressRampsThenRestsUntilMovementReArms() {
        let hand = SyntheticHand.openRelaxed()
        var last = 0.0
        for i in 0..<30 {
            let (_, overlay) = feed([hand], at: Double(i) / 30)
            XCTAssertGreaterThanOrEqual(overlay.dwellProgress, last,
                                        "the ramp never retreats while settled")
            last = overlay.dwellProgress
        }
        XCTAssertGreaterThan(last, 0.9, "a nearly-complete dwell shows a nearly-tight ring")

        let (fired, atFire) = feed([hand], at: 1.0)
        XCTAssertEqual(downs(fired).count, 1)
        XCTAssertEqual(atFire.dwellProgress, 0, accuracy: 1e-9,
                       "after the click the ring lets go")

        let (_, still) = feed([hand], at: 1.5)
        XCTAssertEqual(still.dwellProgress, 0, accuracy: 1e-9,
                       "…and stays at rest until the cursor moves off the spot")

        let (_, moved) = feed([SyntheticHand.openRelaxed(wrist: Vec2(0.6, 0.5))], at: 1.6)
        XCTAssertEqual(moved.dwellProgress, 0, accuracy: 1e-9, "a fresh settle starts from zero")
        let (_, later) = feed([SyntheticHand.openRelaxed(wrist: Vec2(0.6, 0.5))], at: 2.1)
        XCTAssertEqual(later.dwellProgress, 0.5, accuracy: 0.02,
                       "…and ramps against the new anchor")
    }
}
