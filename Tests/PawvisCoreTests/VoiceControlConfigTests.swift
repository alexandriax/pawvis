import XCTest
@testable import PawvisCore

/// Decode behavior of `VoiceControlConfig`, focused on the audible-cues
/// toggle: off by default, read when present, and tolerant of junk without
/// taking the rest of the section down.
final class VoiceControlConfigTests: XCTestCase {
    func testAudibleCuesDefaultsOff() {
        XCTAssertFalse(VoiceControlConfig().audibleCues)
    }

    func testDecodeWithoutKeyKeepsDefaultOff() throws {
        let json = Data("{}".utf8)
        let config = try JSONDecoder().decode(VoiceControlConfig.self, from: json)
        XCTAssertFalse(config.audibleCues)
    }

    func testDecodeReadsAudibleCues() throws {
        let json = Data(#"{"audibleCues": true}"#.utf8)
        let config = try JSONDecoder().decode(VoiceControlConfig.self, from: json)
        XCTAssertTrue(config.audibleCues)
    }

    func testDecodeToleratesWrongTypeAndKeepsNeighbors() throws {
        // A corrupted field must fall back to its default without losing the
        // fields around it — the section-tolerance rule every config follows.
        let json = Data(#"{"audibleCues": "loud", "enabled": true, "wakeWord": "Beans"}"#.utf8)
        let config = try JSONDecoder().decode(VoiceControlConfig.self, from: json)
        XCTAssertFalse(config.audibleCues)
        XCTAssertTrue(config.enabled)
        XCTAssertEqual(config.wakeWord, "Beans")
    }

    func testAudibleCuesRoundTripsThroughSettings() throws {
        var settings = PawvisSettings()
        settings.voiceControl.audibleCues = true
        let data = try JSONEncoder().encode(settings)
        let decoded = try JSONDecoder().decode(PawvisSettings.self, from: data)
        XCTAssertTrue(decoded.voiceControl.audibleCues)
        XCTAssertEqual(decoded, settings)
    }
}
