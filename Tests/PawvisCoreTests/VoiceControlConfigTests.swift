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
