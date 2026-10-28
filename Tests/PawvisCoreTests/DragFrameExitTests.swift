import XCTest
@testable import PawvisCore

/// A drag whose hand slips out of the camera frame: the press survives a
/// short absence, and a hand that comes back still dipped after the press
/// was given up must lift before it can press again.
final class DragFrameExitTests: XCTestCase {
    private var engine: GestureEngine!
    private var t = 0.0

    override func setUp() {
        super.setUp()
        engine = GestureEngine(config: GestureEngineTests.testConfig())
        t = 0
    }

    @discardableResult
    private func feed(_ hands: [Hand], _ frames: Int) -> [GestureEvent] {
        var events: [GestureEvent] = []
        for _ in 0..<frames {
            events += engine.process(HandFrame(time: t, hands: hands)).events
            t += 1.0 / 30
        }
        return events
    }

    private func hand(dipped: Bool, x: Double) -> [Hand] {
        [SyntheticHand.mouseTap(indexDown: dipped, wrist: Vec2(x, 0.7))]
    }

    private func downs(_ e: [GestureEvent]) -> Int {
        e.filter { if case .buttonDown = $0 { return true }; return false }.count
    }

    private func ups(_ e: [GestureEvent]) -> Int {
        e.filter { if case .buttonUp = $0 { return true }; return false }.count
    }

    private func drags(_ e: [GestureEvent]) -> Int {
        e.filter { if case .drag = $0 { return true }; return false }.count
    }

    /// Open, press, and drag to the right — the press is in flight after.
    private func startDrag() {
        feed(hand(dipped: false, x: 0.3), 10)
        XCTAssertEqual(downs(feed(hand(dipped: true, x: 0.3), 12)), 1)
        for i in 1...6 { feed(hand(dipped: true, x: 0.3 + 0.05 * Double(i)), 1) }
    }

    func testDragSurvivesABriefExitAndContinues() {
        startDrag()
        XCTAssertEqual(ups(feed([], 18)), 0, "0.6 s out of frame must not release the drag")
        let back = feed(hand(dipped: true, x: 0.7), 6)
        XCTAssertEqual(downs(back), 0, "no fresh press on return")
        XCTAssertEqual(ups(back), 0)
        XCTAssertGreaterThan(drags(back), 0, "the same drag carries on where the hand came back")
        XCTAssertEqual(ups(feed(hand(dipped: false, x: 0.7), 6)), 1, "lifting ends it")
    }

    func testReturningLiftedReleasesTheHeldDrag() {
        startDrag()
        feed([], 18)
        let back = feed(hand(dipped: false, x: 0.7), 6)
        XCTAssertEqual(ups(back), 1)
        XCTAssertEqual(downs(back), 0)
    }

    func testLongExitReleasesAndAReturningDipMustLiftFirst() {
        startDrag()
        XCTAssertEqual(ups(feed([], 60)), 1, "past the held grace the drag is released")
        XCTAssertEqual(downs(feed(hand(dipped: true, x: 0.7), 15)), 0,
                       "a hand back still dipped must not press anew where it re-entered")
        feed(hand(dipped: false, x: 0.7), 4)
        XCTAssertEqual(downs(feed(hand(dipped: true, x: 0.7), 6)), 1, "after a lift, clicks work again")
    }

    func testIdleHandLossStillUsesTheShortGrace() {
        feed(hand(dipped: false, x: 0.3), 10)
        feed([], 12) // 0.4 s: past the short grace, no press held
        XCTAssertEqual(downs(feed(hand(dipped: true, x: 0.5), 10)), 0,
                       "a hand entering already dipped does not click")
        feed(hand(dipped: false, x: 0.5), 3)
        XCTAssertEqual(downs(feed(hand(dipped: true, x: 0.5), 6)), 1)
    }
}
