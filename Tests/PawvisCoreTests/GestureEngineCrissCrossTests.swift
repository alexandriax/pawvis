import XCTest
@testable import PawvisCore

/// The criss-cross tracking-off wave: both hands open and splayed, then
/// traded sides the configured number of times. Chirality orders the palms,
/// so these tests move a left- and a right-chirality hand across each other
/// and assert exactly when `.disableTracking` fires.
final class GestureEngineCrissCrossTests: XCTestCase {
    var engine: GestureEngine!
    private var t: TimeInterval = 0
    private let dt = 1.0 / 30

    override func setUp() {
        super.setUp()
        engine = GestureEngine(config: GestureEngineTests.testConfig())
        t = 0
    }

    // MARK: - Drivers

    /// One frame: a left-chirality and a right-chirality splayed hand at the
    /// given x positions (palm x == wrist x for the synthetic build).
    @discardableResult
    private func feedPair(leftX: Double, rightX: Double,
                          make: (Vec2, Hand.Chirality) -> Hand = {
                              SyntheticHand.openSplayed(wrist: $0, chirality: $1)
                          }) -> [GestureEvent] {
        defer { t += dt }
        return engine.process(HandFrame(time: t, hands: [
            make(Vec2(leftX, 0.7), .left),
            make(Vec2(rightX, 0.7), .right),
        ])).events
    }

    /// Hold the pair still for `count` frames.
    @discardableResult
    private func holdPair(leftX: Double, rightX: Double, count: Int,
                          make: (Vec2, Hand.Chirality) -> Hand = {
                              SyntheticHand.openSplayed(wrist: $0, chirality: $1)
                          }) -> [GestureEvent] {
        var events: [GestureEvent] = []
        for _ in 0..<count {
            events += feedPair(leftX: leftX, rightX: rightX, make: make)
        }
        return events
    }

    /// Glide both hands linearly to swapped positions over `steps` frames,
    /// then settle there long enough for the side debounce.
    @discardableResult
    private func trade(leftX: inout Double, rightX: inout Double, steps: Int = 6,
                       make: (Vec2, Hand.Chirality) -> Hand = {
                           SyntheticHand.openSplayed(wrist: $0, chirality: $1)
                       }) -> [GestureEvent] {
        let (leftTo, rightTo) = (rightX, leftX)
        var events: [GestureEvent] = []
        for i in 1...steps {
            let f = Double(i) / Double(steps)
            events += feedPair(leftX: leftX + (leftTo - leftX) * f,
                               rightX: rightX + (rightTo - rightX) * f,
                               make: make)
        }
        events += holdPair(leftX: leftTo, rightX: rightTo, count: 3, make: make)
        (leftX, rightX) = (leftTo, rightTo)
        return events
    }

    /// Engage (pair held apart), then trade sides `crossings` times.
    private func wave(crossings: Int,
                      make: (Vec2, Hand.Chirality) -> Hand = {
                          SyntheticHand.openSplayed(wrist: $0, chirality: $1)
                      }) -> [GestureEvent] {
        var leftX = 0.3, rightX = 0.7
        var events = holdPair(leftX: leftX, rightX: rightX, count: 4, make: make)
        for _ in 0..<crossings {
            events += trade(leftX: &leftX, rightX: &rightX, make: make)
        }
        return events
    }

    private func disables(_ events: [GestureEvent]) -> Int {
        events.filter { $0 == .disableTracking }.count
    }

    private func moves(_ events: [GestureEvent]) -> [Vec2] {
        events.compactMap {
            if case .move(let to) = $0 { return to }
            return nil
        }
    }

    // MARK: - Defaults & decoding

    func testDefaults() {
        let c = GestureConfig.default
        XCTAssertTrue(c.crissCrossDisableEnabled, "the tracking-off wave ships on")
        XCTAssertEqual(c.crissCrossDisableCrossings, 2,
                       "one full wave: cross over, then back")
    }

    func testFieldsDecodeAndTolerateGarbage() throws {
        let known = try JSONDecoder().decode(
            GestureConfig.self,
            from: Data(#"{"crissCrossDisableEnabled":false,"crissCrossDisableCrossings":4}"#.utf8))
        XCTAssertFalse(known.crissCrossDisableEnabled)
        XCTAssertEqual(known.crissCrossDisableCrossings, 4)

        let bogus = try JSONDecoder().decode(
            GestureConfig.self,
            from: Data(#"{"crissCrossDisableEnabled":"nah","crissCrossDisableCrossings":"two"}"#.utf8))
        XCTAssertTrue(bogus.crissCrossDisableEnabled, "a mistyped field keeps its default")
        XCTAssertEqual(bogus.crissCrossDisableCrossings, 2)
    }

    // MARK: - The wave

    func testFullWaveDisablesTracking() {
        XCTAssertEqual(disables(wave(crossings: 2)), 1,
                       "two side trades — over and back — is the default wave")
    }

    func testSingleCrossingDoesNotFire() {
        XCTAssertEqual(disables(wave(crossings: 1)), 0)
    }

    func testConfiguredCrossingCountIsHonored() {
        engine.config.crissCrossDisableCrossings = 3
        var leftX = 0.3, rightX = 0.7
        var events = holdPair(leftX: leftX, rightX: rightX, count: 4)
        events += trade(leftX: &leftX, rightX: &rightX)
        events += trade(leftX: &leftX, rightX: &rightX)
        XCTAssertEqual(disables(events), 0, "two trades are not enough at three")
        XCTAssertEqual(disables(trade(leftX: &leftX, rightX: &rightX)), 1)
    }

    func testDisabledNeverFires() {
        engine.config.crissCrossDisableEnabled = false
        XCTAssertEqual(disables(wave(crossings: 4)), 0)
    }

    func testRelaxedHandsCrossingDoNotFire() {
        // Open but not splayed: the pose never engages, however hard they wave.
        let events = wave(crossings: 3) { wrist, chirality in
            SyntheticHand.openRelaxed(wrist: wrist, chirality: chirality)
        }
        XCTAssertEqual(disables(events), 0)
    }

    func testFistsCrossingDoNotFire() {
        let events = wave(crossings: 3) { wrist, chirality in
            SyntheticHand.fist(wrist: wrist, chirality: chirality)
        }
        XCTAssertEqual(disables(events), 0)
    }

    func testUnknownChiralityNeverCountsACrossing() {
        let events = wave(crossings: 4) { wrist, _ in
            SyntheticHand.openSplayed(wrist: wrist, chirality: .unknown)
        }
        XCTAssertEqual(disables(events), 0,
                       "without left/right labels the palms can't be ordered")
    }

    func testOneSplayedHandAloneNeverEngagesAndCursorStaysLive() {
        var events: [GestureEvent] = []
        for x in [0.3, 0.4, 0.5, 0.6, 0.7, 0.6, 0.5, 0.4, 0.3] {
            defer { t += dt }
            events += engine.process(HandFrame(time: t, hands: [
                SyntheticHand.openSplayed(wrist: Vec2(x, 0.7), chirality: .right),
            ])).events
        }
        XCTAssertEqual(disables(events), 0)
        XCTAssertFalse(moves(events).isEmpty, "a lone hand still drives the cursor")
    }

    // MARK: - Parking

    func testCursorParksOnceTheWaveIsUnderway() {
        _ = wave(crossings: 1)
        // Both hands drift with the pose held: mid-wave, the cursor must not follow.
        var events: [GestureEvent] = []
        for i in 1...4 {
            events += feedPair(leftX: 0.7 - Double(i) * 0.02, rightX: 0.3 + Double(i) * 0.02)
        }
        XCTAssertTrue(moves(events).isEmpty,
                      "after the first crossing the cursor parks until the wave resolves")
    }

    func testCursorFreeAgainAfterTheStallTimeout() {
        _ = wave(crossings: 1)
        _ = holdPair(leftX: 0.7, rightX: 0.3, count: 70) // > 2 s: the wave resets
        let events = holdPair(leftX: 0.65, rightX: 0.35, count: 3)
        XCTAssertFalse(moves(events).isEmpty, "a stalled wave lets the cursor go")
    }

    // MARK: - Robustness

    func testPartnerDropoutMidWaveGetsTheGrace() {
        var leftX = 0.3, rightX = 0.7
        var events = holdPair(leftX: leftX, rightX: rightX, count: 4)
        events += trade(leftX: &leftX, rightX: &rightX)
        // Vision loses one hand for ~0.2 s (inside the grace) mid-wave.
        for _ in 0..<6 {
            defer { t += dt }
            events += engine.process(HandFrame(time: t, hands: [
                SyntheticHand.openSplayed(wrist: Vec2(leftX, 0.7), chirality: .left),
            ])).events
        }
        events += holdPair(leftX: leftX, rightX: rightX, count: 2)
        events += trade(leftX: &leftX, rightX: &rightX)
        XCTAssertEqual(disables(events), 1, "a brief dropout must not eat the wave")
    }

    func testPartnerGoneBeyondGraceResetsTheCount() {
        var leftX = 0.3, rightX = 0.7
        var events = holdPair(leftX: leftX, rightX: rightX, count: 4)
        events += trade(leftX: &leftX, rightX: &rightX)
        // One hand gone for ~0.4 s: past the grace, the wave restarts.
        for _ in 0..<12 {
            defer { t += dt }
            events += engine.process(HandFrame(time: t, hands: [
                SyntheticHand.openSplayed(wrist: Vec2(leftX, 0.7), chirality: .left),
            ])).events
        }
        events += holdPair(leftX: leftX, rightX: rightX, count: 4)
        events += trade(leftX: &leftX, rightX: &rightX)
        XCTAssertEqual(disables(events), 0,
                       "the crossing before the dropout no longer counts")
    }

    func testStallTimeoutResetsTheCount() {
        var leftX = 0.3, rightX = 0.7
        var events = holdPair(leftX: leftX, rightX: rightX, count: 4)
        events += trade(leftX: &leftX, rightX: &rightX)
        events += holdPair(leftX: leftX, rightX: rightX, count: 70) // > 2 s stall
        events += trade(leftX: &leftX, rightX: &rightX)
        XCTAssertEqual(disables(events), 0,
                       "a crossing two seconds ago is not part of this wave")
        events = trade(leftX: &leftX, rightX: &rightX)
        XCTAssertEqual(disables(events), 1,
                       "…but the wave restarts cleanly: two fresh trades fire")
    }

    func testMidSessionDisableResetsProgress() {
        var leftX = 0.3, rightX = 0.7
        _ = holdPair(leftX: leftX, rightX: rightX, count: 4)
        _ = trade(leftX: &leftX, rightX: &rightX)
        engine.config.crissCrossDisableEnabled = false
        engine.config.crissCrossDisableEnabled = true
        XCTAssertEqual(disables(trade(leftX: &leftX, rightX: &rightX)), 0,
                       "the crossing made before the toggle is forgotten")
    }

    func testSingleFrameChiralityGlitchDoesNotCountACrossing() {
        var events = holdPair(leftX: 0.3, rightX: 0.7, count: 4)
        // One frame with the labels swapped (the palms appear to trade sides).
        events += engine.process(HandFrame(time: t, hands: [
            SyntheticHand.openSplayed(wrist: Vec2(0.3, 0.7), chirality: .right),
            SyntheticHand.openSplayed(wrist: Vec2(0.7, 0.7), chirality: .left),
        ])).events
        t += dt
        events += holdPair(leftX: 0.3, rightX: 0.7, count: 4)
        // One real trade: were the glitch counted, this would be the second
        // crossing and fire.
        var leftX = 0.3, rightX = 0.7
        events += trade(leftX: &leftX, rightX: &rightX)
        XCTAssertEqual(disables(events), 0,
                       "a one-frame label swap must not survive the side debounce")
    }

    func testDippingAFingerExitsAndBlocksTheButtonsMeanwhile() {
        _ = holdPair(leftX: 0.3, rightX: 0.7, count: 4) // engaged
        // The left hand dips its index as if to click. While the wave is
        // engaged the buttons are blocked; the dip is also the deliberate
        // exit, so after the debounce the machine lets go and the click
        // machinery works again from scratch.
        var events: [GestureEvent] = []
        for _ in 0..<2 {
            defer { t += dt }
            events += engine.process(HandFrame(time: t, hands: [
                SyntheticHand.mouseTap(indexDown: true, wrist: Vec2(0.3, 0.7)),
                SyntheticHand.openSplayed(wrist: Vec2(0.7, 0.7), chirality: .right),
            ])).events
        }
        XCTAssertFalse(events.contains { if case .buttonDown = $0 { return true }; return false },
                       "no press may begin while the wave is engaged")
    }
}
