import XCTest
@testable import PawvisCore

/// Latency with the *shipping* smoothing (the rest of the suite turns it
/// off): a realistic partial index dip under Vision-like landmark jitter,
/// counted in frames from dip onset to buttonDown and lift onset to
/// buttonUp. Before the click bank had its own light filter, a half-depth
/// tap never clicked at all and releases trailed the lift by up to 6 frames.
final class ClickLatencyTests: XCTestCase {
    struct LCG {
        var s: UInt64
        mutating func next() -> Double {
            s = s &* 6364136223846793005 &+ 1442695040888963407
            return Double(s >> 11) / Double(1 << 53)
        }
        mutating func gauss() -> Double {
            let u = max(next(), 1e-12), v = next()
            return (-2 * log(u)).squareRoot() * cos(2 * .pi * v)
        }
    }

    static func lerp(_ a: Hand, _ b: Hand, _ t: Double, noise: Double, rng: inout LCG) -> Hand {
        var h = Hand(chirality: a.chirality, confidence: 1)
        for j in HandJoint.allCases {
            guard let p = a[j], let q = b[j] else { continue }
            let x = p.x + (q.x - p.x) * t + noise * rng.gauss()
            let y = p.y + (q.y - p.y) * t + noise * rng.gauss()
            h.setPoint(Vec2(x, y), for: j)
        }
        return h
    }

    func config(_ smoothing: OneEuroFilter.Params? = nil) -> GestureConfig {
        var c = GestureConfig.default
        c.reachMode = .manual
        c.controlTrigger = .anyHand
        if let smoothing { c.smoothing = smoothing }
        return c
    }

    /// Returns (down frame, up frame) counted from dip onset / lift onset,
    /// nil when the button never moved, plus resting cursor travel.
    func run(depth: Double, holdFrames: Int, noise: Double,
             config: GestureConfig) -> (down: Int?, up: Int?, restTravel: Double) {
        let engine = GestureEngine(config: config)
        var rng = LCG(s: 42)
        let open = SyntheticHand.mouseTap(indexDown: false)
        let dipped = SyntheticHand.mouseTap(indexDown: true)
        var t = 0.0
        var frame = 0
        func step(_ amount: Double) -> [GestureEvent] {
            let h = Self.lerp(open, dipped, amount, noise: noise, rng: &rng)
            defer { frame += 1; t += 1.0 / 30 }
            return engine.process(HandFrame(time: t, hands: [h])).events
        }
        var restTravel = 0.0
        var last: Vec2?
        for _ in 0..<60 {
            for e in step(0) {
                if case .move(let to) = e {
                    if let l = last { restTravel += to.distance(to: l) }
                    last = to
                }
            }
        }
        // Dip over 3 frames (~100 ms) to `depth`, hold, lift over 3 frames.
        var profile: [Double] = [depth / 3, 2 * depth / 3]
        profile += Array(repeating: depth, count: holdFrames + 1)
        let liftStart = profile.count
        profile += [2 * depth / 3, depth / 3]
        profile += Array(repeating: 0, count: 30)
        var down: Int?, up: Int?
        for (i, amount) in profile.enumerated() {
            for e in step(amount) {
                if case .buttonDown(.left, _, _) = e, down == nil { down = i }
                if case .buttonUp(.left, _, _) = e, up == nil { up = i - liftStart }
            }
        }
        return (down, up, restTravel)
    }

    func testDipsClickAndReleaseWithinThreeFrames() {
        for depth in [0.5, 0.7, 1.0] {
            for hold in [2, 6] {
                let r = run(depth: depth, holdFrames: hold, noise: 0.002, config: config())
                let label = "depth \(depth), hold \(hold)"
                XCTAssertNotNil(r.down, "\(label): the tap must click")
                XCTAssertLessThanOrEqual(r.down ?? .max, 3, label)
                XCTAssertNotNil(r.up, "\(label): the lift must release")
                XCTAssertLessThanOrEqual(r.up ?? .max, 3, label)
            }
        }
    }
}

extension ClickLatencyTests {
    /// Cursor lag while the hand sweeps, and resting wander, per smoothing.
    func sweep(_ p: OneEuroFilter.Params, noise: Double) -> (lag: Double, rest: Double) {
        let engine = GestureEngine(config: config(p))
        var rng = LCG(s: 7)
        var t = 0.0
        var cursor: Vec2?
        var rest = 0.0
        func feed(_ wristX: Double) {
            let h = Self.lerp(SyntheticHand.mouseTap(indexDown: false, wrist: Vec2(wristX, 0.7)),
                              SyntheticHand.mouseTap(indexDown: false, wrist: Vec2(wristX, 0.7)),
                              0, noise: noise, rng: &rng)
            for e in engine.process(HandFrame(time: t, hands: [h])).events {
                if case .move(let to) = e {
                    if let c = cursor, wristX == 0.35 { rest += to.distance(to: c) }
                    cursor = to
                }
            }
            t += 1.0 / 30
        }
        for _ in 0..<90 { feed(0.35) }
        rest /= 3 // per second
        // Unfiltered reference: the same sweep with smoothing off.
        let ref = GestureEngine(config: config(OneEuroFilter.Params(minCutoff: 1e9, beta: 0, dCutoff: 1e9)))
        var refCursor: Vec2?
        var lags: [Double] = []
        var tt = t
        for i in 0..<10 { // 0.3 wrist units in 1/3 s
            let x = 0.35 + 0.03 * Double(i + 1)
            feed(x)
            let h = SyntheticHand.mouseTap(indexDown: false, wrist: Vec2(x, 0.7))
            for e in ref.process(HandFrame(time: tt, hands: [h])).events {
                if case .move(let to) = e { refCursor = to }
            }
            tt += 1.0 / 30
            if let c = cursor, let r = refCursor { lags.append(abs(r.x - c.x)) }
        }
        return (lags.max() ?? 0, rest)
    }

    /// sporecaster's 0.014 beta trailed this sweep by 0.13 screens; the
    /// normalized tuning must cut that hard without wandering more at rest.
    func testCursorTracksASweepWithoutRestingWander() {
        let old = sweep(.landmark, noise: 0.002)
        let new = sweep(.normalizedLandmark, noise: 0.002)
        XCTAssertLessThan(new.lag, 0.06)
        XCTAssertLessThan(new.lag, old.lag / 2)
        XCTAssertLessThanOrEqual(new.rest, old.rest)
    }
}

extension ClickLatencyTests {
    /// Phantom presses from landmark jitter alone: an open, still hand for
    /// 30 s at increasing Vision-like noise must never click.
    func testJitterAloneNeverClicks() {
        for noise in [0.002, 0.004, 0.006, 0.008] {
            let engine = GestureEngine(config: config())
            var rng = LCG(s: 99)
            let open = SyntheticHand.mouseTap(indexDown: false)
            var downs = 0
            for i in 0..<900 {
                let h = Self.lerp(open, open, 0, noise: noise, rng: &rng)
                for e in engine.process(HandFrame(time: Double(i) / 30, hands: [h])).events {
                    if case .buttonDown = e { downs += 1 }
                }
            }
            XCTAssertEqual(downs, 0, "noise \(noise)")
        }
    }
}
