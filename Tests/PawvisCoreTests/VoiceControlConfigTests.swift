import XCTest
@testable import PawvisCore

/// Decode behavior of the agent-confirm setting: the safety default is ON,
/// and the section stays field-tolerant like every other config.
final class AgentConfirmConfigTests: XCTestCase {
    private func decode(_ json: String) throws -> VoiceControlConfig {
        try JSONDecoder().decode(VoiceControlConfig.self, from: Data(json.utf8))
    }

    func testAgentConfirmDefaultsOn() {
        XCTAssertTrue(VoiceControlConfig().agentConfirm)
    }

    func testAgentConfirmDefaultsOnWhenKeyAbsent() throws {
        // Settings written by earlier builds don't carry the key: decoding
        // them must land on confirm ON, not silently off.
        let config = try decode(#"{"enabled":true,"agentExecutor":"claude"}"#)
        XCTAssertTrue(config.agentConfirm)
        XCTAssertEqual(config.agentExecutor, "claude")
        XCTAssertTrue(config.enabled)
    }

    func testAgentConfirmExplicitOffDecodes() throws {
        // Switching the read-back off is a real choice and must persist.
        let config = try decode(#"{"agentConfirm":false}"#)
        XCTAssertFalse(config.agentConfirm)
    }

    func testAgentConfirmSurvivesRoundTrip() throws {
        var config = VoiceControlConfig()
        config.agentConfirm = false
        let decoded = try JSONDecoder().decode(
            VoiceControlConfig.self, from: JSONEncoder().encode(config))
        XCTAssertEqual(decoded, config)
        XCTAssertFalse(decoded.agentConfirm)
    }

    func testMistypedAgentConfirmFallsBackToOn() throws {
        // Field-tolerant like every other field: a wrong type is ignored
        // (back to the safe default) rather than failing the section.
        let config = try decode(#"{"agentConfirm":"nope","enabled":true}"#)
        XCTAssertTrue(config.agentConfirm)
        XCTAssertTrue(config.enabled)
    }

    func testUnknownKeysAreIgnoredAroundIt() throws {
        let config = try decode(#"{"someFutureKey":123,"agentConfirm":false}"#)
        XCTAssertFalse(config.agentConfirm)
    }
}


/// Decode behavior of `VoiceControlConfig`, focused on the audible-cues
/// toggle: off by default, read when present, and tolerant of junk without
/// taking the rest of the section down.
final class AudibleCuesConfigTests: XCTestCase {
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
