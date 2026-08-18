import Foundation
import XCTest
@testable import PawvisCore

/// The export/import format (`PawvisGestureFile`) and the pure merge that
/// backs the Gestures tab's Import button: round-trip, tolerant element
/// drop, future-version refusal, and every collision rule the merge must
/// honor (fresh id on an id clash, renamed on a name clash, action/tuning
/// carried over intact).
final class PawvisGestureFileTests: XCTestCase {
    private func gesture(name: String = "Snap", id: UUID = UUID(),
                          sensitivity: Double = 0.7, holdSeconds: Double = 0.3,
                          action: GestureAction? = GestureAction(kind: .desktopRight)) -> TrainedGesture {
        TrainedGesture(id: id, name: name, handCount: 1, template: [[0.1, 0.2], [0.3, 0.4]],
                       duration: 0.5, baseThreshold: 0.15, sensitivity: sensitivity,
                       holdSeconds: holdSeconds, action: action)
    }

    // MARK: - Format

    func testRoundTrip() throws {
        // A whole-second timestamp: ISO 8601 (deliberately chosen so the
        // exported file is human-readable) doesn't carry sub-second
        // precision, so an arbitrary `Date()` would round-trip a few hundred
        // microseconds off and fail an exact equality check for a reason
        // that has nothing to do with what this test is actually checking.
        let exportedAt = ISO8601DateFormatter().date(from: "2026-01-01T12:00:00Z")!
        let file = PawvisGestureFile(gestures: [gesture(name: "Sweep"), gesture(name: "Snap")],
                                     exportedAt: exportedAt)
        let data = try file.encoded()
        let decoded = try PawvisGestureFile.decoded(from: data)
        XCTAssertEqual(decoded, file)
        XCTAssertEqual(decoded.formatVersion, PawvisGestureFile.currentFormatVersion)
    }

    func testFutureFormatVersionRefusesToDecode() {
        let json = """
        {"formatVersion": 2, "exportedAt": "2026-01-01T00:00:00Z", "gestures": []}
        """
        XCTAssertThrowsError(try PawvisGestureFile.decoded(from: json.data(using: .utf8)!)) { error in
            guard case PawvisGestureFile.DecodeError.newerFormat(let version) = error else {
                return XCTFail("expected .newerFormat, got \(error)")
            }
            XCTAssertEqual(version, 2)
            XCTAssertNotNil(error.localizedDescription)
        }
    }

    func testUnreadableGestureDropsAlone() throws {
        let json = """
        {"formatVersion": 1, "exportedAt": "2026-01-01T00:00:00Z", "gestures": [
            {"broken": true},
            {"id": "6F9619FF-8B86-D011-B42D-00C04FC964FF", "name": "Good",
             "handCount": 1, "template": [[0.1, 0.2]], "duration": 0.5, "baseThreshold": 0.1}
        ]}
        """
        let decoded = try PawvisGestureFile.decoded(from: json.data(using: .utf8)!)
        XCTAssertEqual(decoded.gestures.count, 1)
        XCTAssertEqual(decoded.gestures.first?.name, "Good")
    }

    func testMissingExportedAtDefaultsRatherThanFailing() throws {
        let json = """
        {"formatVersion": 1, "gestures": []}
        """
        let decoded = try PawvisGestureFile.decoded(from: json.data(using: .utf8)!)
        XCTAssertEqual(decoded.gestures.count, 0)
    }

    // MARK: - Merge

    func testMergeAppendsNonCollidingGestures() {
        let existing = [gesture(name: "Sweep")]
        let importing = [gesture(name: "Snap")]
        let result = TrainedGestureImport.merge(existing: existing, importing: importing)
        XCTAssertEqual(result.gestures.count, 2)
        XCTAssertEqual(result.added.map(\.name), ["Snap"])
        XCTAssertEqual(result.renamedCount, 0)
        XCTAssertEqual(result.added.first?.id, importing.first?.id, "no collision — id is untouched")
    }

    func testMergeGivesCollidingIDAFreshUUID() {
        let shared = UUID()
        let existing = [gesture(name: "Sweep", id: shared)]
        let importing = [gesture(name: "Different Name", id: shared)]
        let result = TrainedGestureImport.merge(existing: existing, importing: importing)
        XCTAssertEqual(result.gestures.count, 2)
        XCTAssertNotEqual(result.added.first?.id, shared, "a colliding id is never kept — imports are copies")
        XCTAssertEqual(result.added.first?.name, "Different Name", "name didn't collide, so it's untouched")
    }

    func testMergeSuffixesACollidingName() {
        let existing = [gesture(name: "Snap")]
        let importing = [gesture(name: "Snap")]
        let result = TrainedGestureImport.merge(existing: existing, importing: importing)
        XCTAssertEqual(result.renamedCount, 1)
        XCTAssertEqual(result.added.first?.name, "Snap 2")
        XCTAssertNotEqual(result.added.first?.id, existing.first?.id, "same name, different id — still a copy")
    }

    func testMergeClimbsPastExistingSuffixes() {
        let existing = [gesture(name: "Snap"), gesture(name: "Snap 2")]
        let importing = [gesture(name: "Snap")]
        let result = TrainedGestureImport.merge(existing: existing, importing: importing)
        XCTAssertEqual(result.added.first?.name, "Snap 3")
    }

    func testMergeDedupesWithinTheSameImportBatch() {
        // Two same-named gestures arriving in one file must not collide with
        // each other once they land.
        let importing = [gesture(name: "Snap"), gesture(name: "Snap")]
        let result = TrainedGestureImport.merge(existing: [], importing: importing)
        XCTAssertEqual(result.gestures.map(\.name).sorted(), ["Snap", "Snap 2"])
        XCTAssertEqual(result.renamedCount, 1)
    }

    func testMergePreservesActionSensitivityAndHold() {
        let action = GestureAction(kind: .runShellCommand, argument: "say hi")
        let importing = [gesture(name: "Snap", sensitivity: 0.9, holdSeconds: 0.6, action: action)]
        let result = TrainedGestureImport.merge(existing: [], importing: importing)
        XCTAssertEqual(result.added.first?.action, action, "actions travel with the export/import")
        XCTAssertEqual(result.added.first?.sensitivity, 0.9)
        XCTAssertEqual(result.added.first?.holdSeconds, 0.6)
    }

    func testMergeNeverMutatesExisting() {
        let existing = [gesture(name: "Sweep"), gesture(name: "Snap")]
        let result = TrainedGestureImport.merge(existing: existing, importing: [gesture(name: "New")])
        XCTAssertEqual(Array(result.gestures.prefix(2)), existing, "existing entries are untouched, in order")
    }

    // MARK: - End to end (settings → file → merge, no panels)

    /// The panels themselves can't be driven headlessly, but everything they
    /// call can: this exercises the same round trip `TrainedGestureImportExportRow`
    /// performs, minus the NSSavePanel/NSOpenPanel plumbing.
    func testExportThenImportRoundTripsThroughSettings() throws {
        var settings = PawvisSettings()
        settings.trainedGestures.gestures = [gesture(name: "Sweep")]

        let exported = PawvisGestureFile(gestures: settings.trainedGestures.gestures)
        let data = try exported.encoded()

        var otherMachine = PawvisSettings()
        otherMachine.trainedGestures.gestures = [gesture(name: "Different Gesture")]

        let imported = try PawvisGestureFile.decoded(from: data)
        let result = TrainedGestureImport.merge(
            existing: otherMachine.trainedGestures.gestures, importing: imported.gestures)
        otherMachine.trainedGestures.gestures = result.gestures

        XCTAssertEqual(otherMachine.trainedGestures.gestures.count, 2)
        XCTAssertEqual(result.renamedCount, 0)
        XCTAssertTrue(otherMachine.trainedGestures.gestures.contains { $0.name == "Sweep" })
    }
}
