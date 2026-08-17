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
