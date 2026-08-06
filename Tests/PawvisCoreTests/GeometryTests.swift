import XCTest
@testable import PawvisCore

final class OneEuroFilterTests: XCTestCase {
    func testFirstSamplePassesThrough() {
        var f = OneEuroFilter()
        XCTAssertEqual(f.filter(3.7, at: 0), 3.7)
    }

    func testConvergesToConstantInput() {
        var f = OneEuroFilter()
        var out = f.filter(0, at: 0)
        for i in 1...200 {
            out = f.filter(5.0, at: Double(i) / 60)
        }
        XCTAssertEqual(out, 5.0, accuracy: 0.01)
    }

    func testReducesJitterVariance() {
        var f = OneEuroFilter(params: .landmark)
        var rng = SystemRandomNumberGenerator() // noise seed irrelevant: we compare variances
        var raw: [Double] = []
        var filtered: [Double] = []
        for i in 0..<300 {
            let noise = Double.random(in: -0.02...0.02, using: &rng)
            let v = 0.5 + noise
            raw.append(v)
            filtered.append(f.filter(v, at: Double(i) / 60))
        }
        func variance(_ xs: [Double]) -> Double {
            let m = xs.reduce(0, +) / Double(xs.count)
            return xs.reduce(0) { $0 + ($1 - m) * ($1 - m) } / Double(xs.count)
        }
        XCTAssertLessThan(variance(Array(filtered.dropFirst(30))),
                          variance(Array(raw.dropFirst(30))) * 0.5,
                          "filter should cut noise variance by well over half")
    }

    func testHigherBetaTracksFastMotionMoreClosely() {
        var slow = OneEuroFilter(params: .init(minCutoff: 1.0, beta: 0.0))
        var fast = OneEuroFilter(params: .init(minCutoff: 1.0, beta: 0.5))
        var slowOut = 0.0, fastOut = 0.0
        for i in 0..<120 {
            let t = Double(i) / 60
            let v = t * 2.0 // fast ramp
            slowOut = slow.filter(v, at: t)
            fastOut = fast.filter(v, at: t)
        }
        let target = (119.0 / 60) * 2
        XCTAssertLessThan(abs(fastOut - target), abs(slowOut - target),
                          "higher beta must lag a fast ramp less")
    }

    func testDtFloorPreventsExplosion() {
        var f = OneEuroFilter()
        _ = f.filter(0, at: 1.0)
        // Identical timestamp: dt clamps to 1e-4 instead of dividing by zero.
        let out = f.filter(1.0, at: 1.0)
        XCTAssertTrue(out.isFinite)
    }

    func testResetForgetsHistory() {
        var f = OneEuroFilter()
        _ = f.filter(100, at: 0)
        _ = f.filter(100, at: 0.016)
        f.reset()
        XCTAssertEqual(f.filter(0, at: 1), 0, "post-reset first sample passes through")
    }

    func test2DFiltersAxesIndependently() {
        var f = OneEuroFilter2D()
        _ = f.filter(Vec2(0, 10), at: 0)
        let out = f.filter(Vec2(0, 10), at: 1.0)
        XCTAssertEqual(out.x, 0, accuracy: 1e-9)
        XCTAssertEqual(out.y, 10, accuracy: 1e-9)
    }
}

final class CoordinateMapperTests: XCTestCase {
    func testIdentityBoxUnmirrored() {
        let m = CoordinateMapper(box: InteractionBox(xMin: 0, xMax: 1, yMin: 0, yMax: 1), mirrored: false)
        XCTAssertEqual(m.map(Vec2(0.3, 0.8)), Vec2(0.3, 0.8))
    }

    func testMirroringFlipsX() {
        let m = CoordinateMapper(box: InteractionBox(xMin: 0, xMax: 1, yMin: 0, yMax: 1), mirrored: true)
        let out = m.map(Vec2(0.2, 0.5))
        XCTAssertEqual(out.x, 0.8, accuracy: 1e-9)
        XCTAssertEqual(out.y, 0.5, accuracy: 1e-9)
    }

    func testInteractionBoxScalesToFullScreen() {
        let m = CoordinateMapper(box: InteractionBox(xMin: 0.2, xMax: 0.8, yMin: 0.25, yMax: 0.75), mirrored: false)
        XCTAssertEqual(m.map(Vec2(0.2, 0.25)).distance(to: Vec2(0, 0)), 0, accuracy: 1e-9)
        XCTAssertEqual(m.map(Vec2(0.8, 0.75)).distance(to: Vec2(1, 1)), 0, accuracy: 1e-9)
        XCTAssertEqual(m.map(Vec2(0.5, 0.5)).distance(to: Vec2(0.5, 0.5)), 0, accuracy: 1e-9)
    }

    func testClampingOnOff() {
        let m = CoordinateMapper(box: InteractionBox(xMin: 0.2, xMax: 0.8, yMin: 0.2, yMax: 0.8), mirrored: false)
        XCTAssertEqual(m.map(Vec2(0.05, 0.9)), Vec2(0, 1))
        let unclamped = m.map(Vec2(0.05, 0.9), clamped: false)
        XCTAssertLessThan(unclamped.x, 0)
        XCTAssertGreaterThan(unclamped.y, 1)
    }

    func testMirroredBoxWorksInMirroredSpace() {
        // Box margins apply after mirroring, so they're symmetric for the user.
        let m = CoordinateMapper(box: InteractionBox(xMin: 0.2, xMax: 0.8, yMin: 0, yMax: 1), mirrored: true)
        // Camera x=0.8 → mirrored 0.2 → box left edge → screen 0.
        XCTAssertEqual(m.map(Vec2(0.8, 0.5)).x, 0, accuracy: 1e-9)
    }
}
