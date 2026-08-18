import XCTest
@testable import PawvisCore

/// The engine-level story for custom gestures: fired kinds surface as
/// `.customGesture` events, an engaged grab parks the cursor, and a press
/// stands detection down.
final class CustomGestureEngineTests: XCTestCase {
    var engine: GestureEngine!

    override func setUp() {
        super.setUp()
        var config = GestureConfig.default
        config.interactionBox = InteractionBox(xMin: 0, xMax: 1, yMin: 0, yMax: 1)
        config.reachMode = .manual
        config.mirrorCamera = false
        config.smoothing = OneEuroFilter.Params(minCutoff: 1e9, beta: 0, dCutoff: 1e9)
        config.controlTrigger = .anyHand
        engine = GestureEngine(config: config)
    }

    private func enable(_ gestures: CustomGesture...) {
        var custom = CustomGestureDetector.Config()
        custom.enabled = Set(gestures)
        engine.customConfig = custom
    }

    private func customFires(_ events: [GestureEvent]) -> [CustomGesture] {
        events.compactMap {
            if case .customGesture(let gesture) = $0 { return gesture }
            return nil
        }
    }

    private func moves(_ events: [GestureEvent]) -> [Vec2] {
        events.compactMap {
            if case .move(let to) = $0 { return to }
            return nil
        }
    }

    func testFlingSurfacesAsEvent() {
        enable(.grabFlingRight)
        var events: [GestureEvent] = []
        var t = 0.0
        var wrist = Vec2(0.4, 0.55)
        for _ in 0..<3 {
            events += engine.process(HandFrame(time: t, hands: [SyntheticHand.openRelaxed(wrist: wrist)])).events
            t += 1.0 / 30
        }
        for i in 0..<12 {
            if i >= 3 { wrist = wrist + Vec2(0.03, 0) }
            events += engine.process(HandFrame(time: t, hands: [SyntheticHand.gathered(wrist: wrist)])).events
            t += 1.0 / 30
        }
        XCTAssertEqual(customFires(events), [.grabFlingRight])
    }

    func testGrabParksCursorUntilRelease() {
        enable(.grabFlingRight)
        var t = 0.0
        let start = Vec2(0.5, 0.55)
        for _ in 0..<3 {
            _ = engine.process(HandFrame(time: t, hands: [SyntheticHand.openRelaxed(wrist: start)]))
            t += 1.0 / 30
        }
        // Engage the grab in place, then drag it: the cursor must not move.
        var grabbed: [GestureEvent] = []
        var wrist = start
        for i in 0..<12 {
            if i >= 3 { wrist = wrist + Vec2(0.03, 0) }
            grabbed += engine.process(HandFrame(time: t, hands: [SyntheticHand.gathered(wrist: wrist)])).events
            t += 1.0 / 30
        }
        XCTAssertEqual(moves(grabbed), [], "an engaged grab parks the cursor")
        XCTAssertEqual(customFires(grabbed), [.grabFlingRight])

        // Released and moving open again: the cursor follows once more.
        var released: [GestureEvent] = []
        for _ in 0..<6 {
            wrist = wrist + Vec2(0.02, 0)
            released += engine.process(HandFrame(time: t, hands: [SyntheticHand.openRelaxed(wrist: wrist)])).events
            t += 1.0 / 30
        }
        XCTAssertFalse(moves(released).isEmpty, "release must unpark the cursor")
    }

    func testSweepingPalmBlocksClickEngage() {
        // A dip that appears while the palm is sweeping is motion blur, not a
        // click (measured: two phantom clicks in one clip of swipes). Engage
        // waits until the hand settles; the dip then lands normally.
        var t = 0.0
        var wrist = Vec2(0.2, 0.6)
        for _ in 0..<4 {
            _ = engine.process(HandFrame(time: t, hands: [SyntheticHand.mouseTap(indexDown: false, wrist: wrist)]))
            t += 1.0 / 30
        }
        var sweeping: [GestureEvent] = []
        for _ in 0..<8 { // index dipped the whole way through a fast sweep
            wrist = wrist + Vec2(0.05, 0)
            sweeping += engine.process(HandFrame(time: t, hands: [SyntheticHand.mouseTap(indexDown: true, wrist: wrist)])).events
            t += 1.0 / 30
        }
        XCTAssertFalse(sweeping.contains { if case .buttonDown = $0 { return true } else { return false } },
                       "no press may begin mid-sweep")
        var settled: [GestureEvent] = []
        for _ in 0..<4 { // hand stops, dip still held: now it's a real press
            settled += engine.process(HandFrame(time: t, hands: [SyntheticHand.mouseTap(indexDown: true, wrist: wrist)])).events
            t += 1.0 / 30
        }
        XCTAssertTrue(settled.contains { if case .buttonDown = $0 { return true } else { return false } },
                      "the press lands once the palm settles")
    }

    func testGesturesOnlyModeFiresGesturesWithoutMouse() {
        // The hands-as-a-remote mode: the trigger never arms, so nothing
        // reaches the mouse — while the custom gestures fire exactly as
        // they would with control armed.
        var config = engine.config
        config.controlTrigger = .gesturesOnly
        engine.config = config
        enable(.thumbsUp)

        var events: [GestureEvent] = []
        var t = 0.0
        var wrist = Vec2(0.3, 0.6)
        for _ in 0..<6 { // an open hand travelling: would move the cursor
            wrist = wrist + Vec2(0.03, 0)
            events += engine.process(HandFrame(time: t, hands: [SyntheticHand.openRelaxed(wrist: wrist)])).events
            t += 1.0 / 30
        }
        for _ in 0..<8 { // a held index dip: would click
            events += engine.process(HandFrame(time: t, hands: [SyntheticHand.mouseTap(indexDown: true, wrist: wrist)])).events
            t += 1.0 / 30
        }
        for _ in 0..<15 { // the bound gesture still works
            events += engine.process(HandFrame(time: t, hands: [SyntheticHand.thumbSignal(.up, wrist: wrist)])).events
            t += 1.0 / 30
        }

        XCTAssertFalse(events.contains { event in
            switch event {
            case .move, .drag, .buttonDown, .buttonUp, .scroll: return true
            default: return false
            }
        }, "gestures-only must never emit a mouse event")
        XCTAssertEqual(customFires(events), [.thumbsUp])
    }

    func testPointedDrummingNeverClicksAndParksTheCursor() {
        // Off-beat drumming swings the index-vs-middle differential exactly
        // like index taps; the pointed-pose park must bar both buttons and
        // hold the cursor still even with control armed.
        var t = 0.0
        for _ in 0..<4 {
            _ = engine.process(HandFrame(time: t, hands: [SyntheticHand.openRelaxed()]))
            t += 1.0 / 30
        }
        var early: [GestureEvent] = []
        var parked: [GestureEvent] = []
        for i in 0..<30 {
            let events = engine.process(
                HandFrame(time: t, hands: [SyntheticHand.pointedOffbeat(struck: i % 2 == 1)])).events
            if i < 3 { early += events } else { parked += events }
            t += 1.0 / 30
        }
        let all = early + parked
        XCTAssertFalse(all.contains { if case .buttonDown = $0 { return true } else { return false } },
                       "a drumming pointed hand must never click")
        XCTAssertEqual(moves(parked), [], "the cursor parks while the hand is pointed")
    }

    func testRaisedHandRecoversTheCursorAfterPointedPark() {
        var t = 0.0
        for _ in 0..<4 {
            _ = engine.process(HandFrame(time: t, hands: [SyntheticHand.openRelaxed()]))
            t += 1.0 / 30
        }
        for i in 0..<10 {
            _ = engine.process(HandFrame(time: t, hands: [SyntheticHand.pointedOffbeat(struck: i % 2 == 1)]))
            t += 1.0 / 30
        }
        var events: [GestureEvent] = []
        var wrist = Vec2(0.5, 0.7)
        for _ in 0..<10 {
            wrist = wrist + Vec2(0.02, 0)
            events += engine.process(HandFrame(time: t, hands: [SyntheticHand.openRelaxed(wrist: wrist)])).events
            t += 1.0 / 30
        }
        XCTAssertFalse(moves(events).isEmpty, "an upright hand takes the cursor back")
    }

    func testTrainedGestureSurfacesAsEvent() {
        // A trained swipe, compiled straight into the engine: the fire
        // arrives as a .trainedGesture event with the stored id.
        func swipe(_ progress: Double) -> Hand {
            SyntheticHand.openRelaxed(wrist: Vec2(0.30 + 0.28 * progress, 0.60))
        }
        let recorder = TakeRecorder()
        var takes: [GestureTake] = []
        for _ in 0..<3 {
            var t = 0.0
            recorder.begin(handCount: 1, at: t)
            for _ in 0..<8 {
                _ = recorder.feed([GestureTrace.snapshot(of: swipe(0), minJointConfidence: 0.25)!], at: t)
                t += 1.0 / 30
            }
            for i in 0..<15 {
                if case .finished(let take)? = recorder.feed(
                    [GestureTrace.snapshot(of: swipe(Double(i) / 14), minJointConfidence: 0.25)!], at: t) {
                    takes.append(take)
                }
                t += 1.0 / 30
            }
            for _ in 0..<30 {
                if case .finished(let take)? = recorder.feed(
                    [GestureTrace.snapshot(of: swipe(1), minJointConfidence: 0.25)!], at: t) {
                    takes.append(take)
                }
                t += 1.0 / 30
            }
        }
        guard let build = TrainedGestureBuilder.build(takes: takes) else {
            return XCTFail("no build from \(takes.count) takes")
        }
        let id = UUID()
        var trained = TrainedGestureDetector.Config()
        trained.gestures = [TrainedGestureDetector.Compiled(
            id: id, handCount: 1, template: build.template,
            duration: build.duration, threshold: build.baseThreshold * 1.15)]
        engine.trainedConfig = trained

        var events: [GestureEvent] = []
        var t = 100.0
        for _ in 0..<20 {
            events += engine.process(HandFrame(time: t, hands: [swipe(0)])).events
            t += 1.0 / 30
        }
        for i in 0..<15 {
            events += engine.process(HandFrame(time: t, hands: [swipe(Double(i) / 14)])).events
            t += 1.0 / 30
        }
        for _ in 0..<25 {
            events += engine.process(HandFrame(time: t, hands: [swipe(1)])).events
            t += 1.0 / 30
        }
        let fired = events.compactMap { event -> UUID? in
            if case .trainedGesture(let id) = event { return id }
            return nil
        }
        XCTAssertEqual(fired, [id])
    }

    func testEngineResetClearsDetector() {
        enable(.thumbsUp)
        var t = 0.0
        for _ in 0..<8 {
            _ = engine.process(HandFrame(time: t, hands: [SyntheticHand.thumbSignal(.up)]))
            t += 1.0 / 30
        }
        engine.reset()
        var events: [GestureEvent] = []
        for _ in 0..<6 { // under the dwell, counted from scratch after reset
            events += engine.process(HandFrame(time: t, hands: [SyntheticHand.thumbSignal(.up)])).events
            t += 1.0 / 30
        }
        XCTAssertEqual(customFires(events), [])
    }
}
