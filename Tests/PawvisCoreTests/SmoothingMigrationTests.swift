import XCTest
@testable import PawvisCore

final class SmoothingMigrationTests: XCTestCase {
    private func decode(_ json: String) throws -> OneEuroFilter.Params {
        try JSONDecoder().decode(GestureConfig.self, from: Data(json.utf8)).smoothing
    }

    func testOldDefaultBecomesNewDefault() throws {
        let p = try decode(#"{"smoothing":{"minCutoff":1.4,"beta":0.014,"dCutoff":1.0}}"#)
        XCTAssertEqual(p, .normalizedLandmark)
    }

    func testOldSliderPositionIsKept() throws {
        let range = OneEuroFilter.Params.responsivenessRange
        let low = try decode(#"{"smoothing":{"minCutoff":1.4,"beta":0.005,"dCutoff":1.0}}"#)
        XCTAssertEqual(low.beta, range.lowerBound, accuracy: 1e-9)
        let high = try decode(#"{"smoothing":{"minCutoff":1.4,"beta":0.09,"dCutoff":1.0}}"#)
        XCTAssertEqual(high.beta, range.upperBound, accuracy: 1e-9)
        XCTAssertEqual(high.minCutoff, OneEuroFilter.Params.normalizedLandmark.minCutoff)
    }

    func testNewScaleAndDisabledFilterPassThrough() throws {
        let p = try decode(#"{"smoothing":{"minCutoff":1.0,"beta":9.0,"dCutoff":1.0}}"#)
        XCTAssertEqual(p.beta, 9.0)
        let off = OneEuroFilter.Params(minCutoff: 1e9, beta: 0, dCutoff: 1e9)
        XCTAssertEqual(GestureConfig.migratedSmoothing(off), off)
    }

    func testRoundTripIsStable() throws {
        var c = GestureConfig.default
        c.smoothing.beta = 3
        let back = try JSONDecoder().decode(GestureConfig.self, from: JSONEncoder().encode(c))
        XCTAssertEqual(back.smoothing, c.smoothing)
    }
}
