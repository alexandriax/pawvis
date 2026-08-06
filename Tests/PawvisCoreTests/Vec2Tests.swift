import XCTest
@testable import PawvisCore

final class Vec2Tests: XCTestCase {
    func testArithmetic() {
        let a = Vec2(1, 2)
        let b = Vec2(3, 5)
        XCTAssertEqual(a + b, Vec2(4, 7))
        XCTAssertEqual(b - a, Vec2(2, 3))
        XCTAssertEqual(a * 2, Vec2(2, 4))
        XCTAssertEqual(2 * a, Vec2(2, 4))
        XCTAssertEqual(b / 2, Vec2(1.5, 2.5))
    }

    func testDistanceAndLength() {
        XCTAssertEqual(Vec2(3, 4).length, 5, accuracy: 1e-12)
        XCTAssertEqual(Vec2(1, 1).distance(to: Vec2(4, 5)), 5, accuracy: 1e-12)
    }

    func testMidpointAndLerp() {
        XCTAssertEqual(Vec2(0, 0).midpoint(with: Vec2(2, 4)), Vec2(1, 2))
        XCTAssertEqual(Vec2(0, 0).lerp(to: Vec2(10, 10), t: 0.25), Vec2(2.5, 2.5))
    }

    func testClampToUnit() {
        XCTAssertEqual(Vec2(-0.5, 1.5).clampedToUnit(), Vec2(0, 1))
        XCTAssertEqual(Vec2(0.3, 0.7).clampedToUnit(), Vec2(0.3, 0.7))
    }

    func testAngleAtVertex() {
        // Right angle.
        XCTAssertEqual(
            Vec2.angle(at: .zero, from: Vec2(1, 0), to: Vec2(0, 1)), .pi / 2, accuracy: 1e-9)
        // Straight line.
        XCTAssertEqual(
            Vec2.angle(at: .zero, from: Vec2(-1, 0), to: Vec2(1, 0)), .pi, accuracy: 1e-9)
        // Degenerate ray reads as straight (extended), by design.
        XCTAssertEqual(Vec2.angle(at: .zero, from: .zero, to: Vec2(1, 0)), .pi, accuracy: 1e-9)
    }

    func testCentroid() {
        XCTAssertEqual(centroid(of: [Vec2(0, 0), Vec2(2, 0), Vec2(1, 3)]), Vec2(1, 1))
        XCTAssertEqual(centroid(of: []), .zero)
    }
}
