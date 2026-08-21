import XCTest
@testable import PawvisCore

final class AttentionGateTests: XCTestCase {
    /// Enabled with the default (sensitivity 0.5) tuning.
    private func enabledConfig() -> AttentionGate.Config {
        var settings = AttentionConfig()
        settings.enabled = true
        return settings.gateConfig()
    }

    private let facing = AttentionGate.Observation(faceSeen: true, yaw: 0, pitch: 0)
    private let turnedAway = AttentionGate.Observation(faceSeen: true, yaw: 1.2, pitch: 0)

    /// Feed one observation per 0.1 s (the app's ~10 Hz sampling) for a
    /// duration, returning the last verdict.
    @discardableResult
    private func feed(_ gate: inout AttentionGate, _ observation: AttentionGate.Observation,
                      from start: TimeInterval, seconds: TimeInterval,
                      interacting: Bool = false) -> Bool {
        var verdict = gate.attentive
        var time = start
        while time <= start + seconds {
            verdict = gate.assess(observation, interacting: interacting, at: time)
            time += 0.1
        }
        return verdict
    }

    // MARK: Disabled

    func testDisabledIsAlwaysAttentive() {
        var gate = AttentionGate() // default config: disabled
        XCTAssertTrue(feed(&gate, .noFace, from: 0, seconds: 30))
        XCTAssertTrue(gate.attentive)
    }

    // MARK: Closing

    func testFacingStaysAttentive() {
        var gate = AttentionGate(config: enabledConfig())
        XCTAssertTrue(feed(&gate, facing, from: 0, seconds: 30))
    }

    func testAGlanceAwayCostsNothing() {
        var gate = AttentionGate(config: enabledConfig())
        feed(&gate, facing, from: 0, seconds: 5)
        // Half the away delay: still attentive.
        XCTAssertTrue(feed(&gate, turnedAway, from: 5.1, seconds: 0.4))
        // And looking back wipes the evidence — the clock starts over.
        feed(&gate, facing, from: 5.6, seconds: 0.1)
        XCTAssertTrue(feed(&gate, turnedAway, from: 5.8, seconds: 0.8))
    }

    func testSustainedLookAwayCloses() {
        var gate = AttentionGate(config: enabledConfig())
        feed(&gate, facing, from: 0, seconds: 1)
        XCTAssertFalse(feed(&gate, turnedAway, from: 1.1, seconds: 1.5))
    }

    func testNoFaceCountsAsAway() {
        var gate = AttentionGate(config: enabledConfig())
        feed(&gate, facing, from: 0, seconds: 1)
        XCTAssertFalse(feed(&gate, .noFace, from: 1.1, seconds: 1.5))
    }

    func testPitchAloneCloses() {
        var gate = AttentionGate(config: enabledConfig())
        let faceDown = AttentionGate.Observation(faceSeen: true, yaw: 0, pitch: -1.0)
        XCTAssertFalse(feed(&gate, faceDown, from: 0, seconds: 1.5))
    }

    func testMissingAnglesCountAsFacing() {
        // Vision reporting a face but no yaw/pitch must not read as away.
        var gate = AttentionGate(config: enabledConfig())
        let bare = AttentionGate.Observation(faceSeen: true)
        XCTAssertTrue(feed(&gate, bare, from: 0, seconds: 30))
    }

    // MARK: Reopening

    func testLookingBackReopensAfterTheReturnDelay() {
        var gate = AttentionGate(config: enabledConfig())
        feed(&gate, turnedAway, from: 0, seconds: 1.5)
        XCTAssertFalse(gate.attentive)
        // One facing sample is not enough…
        XCTAssertFalse(gate.assess(facing, interacting: false, at: 2.0))
        // …but a sustained look back is.
        XCTAssertTrue(feed(&gate, facing, from: 2.1, seconds: 0.5))
    }

    func testReopeningDemandsTheReturnMargin() {
        let config = enabledConfig()
        var gate = AttentionGate(config: config)
        feed(&gate, turnedAway, from: 0, seconds: 1.5)
        XCTAssertFalse(gate.attentive)
        // Hovering just inside the open gate's limit — but not the margin —
        // must not reopen it (that head is oscillating at the threshold).
        let hovering = AttentionGate.Observation(
            faceSeen: true, yaw: config.maxOffAngle - 0.001, pitch: 0)
        XCTAssertFalse(feed(&gate, hovering, from: 2, seconds: 5))
        // Fully back inside the margin does.
        let back = AttentionGate.Observation(
            faceSeen: true, yaw: config.maxOffAngle - config.returnMargin - 0.001, pitch: 0)
        XCTAssertTrue(feed(&gate, back, from: 7.1, seconds: 0.5))
    }

    // MARK: The interaction exemption

    func testAHeldPressHoldsTheGateOpen() {
        var gate = AttentionGate(config: enabledConfig())
        feed(&gate, facing, from: 0, seconds: 1)
        // A long look away mid-drag: the gate must not close.
        XCTAssertTrue(feed(&gate, turnedAway, from: 1.1, seconds: 10, interacting: true))
        // And releasing starts the away clock fresh — the ten seconds of
        // evidence gathered mid-drag must not fire the instant it ends.
        XCTAssertTrue(feed(&gate, turnedAway, from: 11.2, seconds: 0.5))
        XCTAssertFalse(feed(&gate, turnedAway, from: 11.8, seconds: 1.0))
    }

    // MARK: Lifecycle

    func testResetRestoresAttentive() {
        var gate = AttentionGate(config: enabledConfig())
        feed(&gate, turnedAway, from: 0, seconds: 1.5)
        XCTAssertFalse(gate.attentive)
        gate.reset()
        XCTAssertTrue(gate.attentive)
    }

    func testDisablingMidPauseReopens() {
        var gate = AttentionGate(config: enabledConfig())
        feed(&gate, turnedAway, from: 0, seconds: 1.5)
        XCTAssertFalse(gate.attentive)
        var off = gate.config
        off.enabled = false
        gate.setConfig(off)
        XCTAssertTrue(gate.attentive)
    }

    func testRetuningWithoutTheFlipKeepsState() {
        var gate = AttentionGate(config: enabledConfig())
        feed(&gate, turnedAway, from: 0, seconds: 1.5)
        var stricter = gate.config
        stricter.maxOffAngle = 0.1
        gate.setConfig(stricter)
        XCTAssertFalse(gate.attentive, "a sensitivity nudge must not reopen a closed gate by itself")
    }

    // MARK: Settings mapping

    func testSensitivitySweepsTheAngleLimitMonotonically() {
        var relaxed = AttentionConfig(); relaxed.enabled = true; relaxed.sensitivity = 0
        var middle = AttentionConfig(); middle.enabled = true; middle.sensitivity = 0.5
        var strict = AttentionConfig(); strict.enabled = true; strict.sensitivity = 1
        XCTAssertGreaterThan(relaxed.gateConfig().maxOffAngle, middle.gateConfig().maxOffAngle)
        XCTAssertGreaterThan(middle.gateConfig().maxOffAngle, strict.gateConfig().maxOffAngle)
        XCTAssertEqual(relaxed.gateConfig().maxOffAngle,
                       AttentionConfig.relaxedOffAngleDegrees * .pi / 180, accuracy: 1e-9)
        XCTAssertEqual(strict.gateConfig().maxOffAngle,
                       AttentionConfig.strictOffAngleDegrees * .pi / 180, accuracy: 1e-9)
    }

    func testSettingsRoundTripAndTolerantDecode() throws {
        var settings = PawvisSettings()
        settings.attention.enabled = false
        settings.attention.sensitivity = 0.8
        let decoded = try JSONDecoder().decode(
            PawvisSettings.self, from: JSONEncoder().encode(settings))
        XCTAssertEqual(decoded.attention, settings.attention,
                       "a switched-off gate survives the round trip, default or not")

        // On by default, and a settings file that predates the section (or
        // corrupts it) keeps the default instead of failing the tree.
        XCTAssertTrue(PawvisSettings.default.attention.enabled)
        let legacy = try JSONDecoder().decode(PawvisSettings.self, from: Data("{}".utf8))
        XCTAssertEqual(legacy.attention, AttentionConfig())
        let corrupt = try JSONDecoder().decode(
            PawvisSettings.self,
            from: Data(#"{"attention":{"enabled":"yes","sensitivity":9.5}}"#.utf8))
        XCTAssertTrue(corrupt.attention.enabled,
                      "a wrongly-typed flag falls back to the default, like every other field")
        XCTAssertEqual(corrupt.attention.sensitivity, 1.0,
                       "a well-typed, out-of-range sensitivity clamps to the slider's range")
    }
}
