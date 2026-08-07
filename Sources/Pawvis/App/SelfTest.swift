import Foundation
import PawvisCore

/// Headless smoke test (`Pawvis --selftest`): exercises the core pipeline
/// pieces that don't need camera/mic/permissions, so CI or a fresh checkout
/// can verify the binary is sane without launching the UI.
func runSelfTest() -> Int32 {
    var failures = 0
    var checks = 0

    func check(_ name: String, _ condition: @autoclosure () -> Bool) {
        checks += 1
        if condition() {
            print("PASS \(name)")
        } else {
            failures += 1
            print("FAIL \(name)")
        }
    }

    // Gesture engine processes frames without crashing and stays quiet on empties.
    // `.anyHand`: the partial synthetic hand below can't show the open-hand
    // control trigger (it has no ring finger), and this test is about the
    // pipeline, not the trigger.
    var engineConfig = GestureConfig.default
    engineConfig.controlTrigger = .anyHand
    let engine = GestureEngine(config: engineConfig)
    var quiet = true
    for i in 0..<60 {
        let (events, _) = engine.process(HandFrame(time: Double(i) / 30, hands: []))
        if !events.isEmpty { quiet = false }
    }
    check("engine.emptyFramesProduceNoEvents", quiet)

    // A synthetic hand produces a cursor.
    var joints: [HandJoint: Vec2] = [
        .wrist: Vec2(0.5, 0.7), .middleMCP: Vec2(0.5, 0.55),
        .indexMCP: Vec2(0.46, 0.56), .indexPIP: Vec2(0.45, 0.49),
        .indexDIP: Vec2(0.445, 0.45), .indexTip: Vec2(0.44, 0.42),
        .thumbTip: Vec2(0.36, 0.60),
        .littleMCP: Vec2(0.56, 0.58),
    ]
    joints[.middlePIP] = Vec2(0.50, 0.48)
    joints[.middleTip] = Vec2(0.50, 0.40)
    let hand = Hand(chirality: .right, confidence: 1, joints: joints)
    let (_, overlay) = engine.process(HandFrame(time: 3, hands: [hand]))
    check("engine.syntheticHandYieldsCursor", overlay.cursor != nil)
    check("engine.overlayHasFingertips", !(overlay.hands.first?.fingertips.isEmpty ?? true))

    // Settings roundtrip.
    var settings = PawvisSettings.default
    settings.gestures.pinchEngageRatio = 0.42
    if let data = try? JSONEncoder().encode(settings),
       let decoded = try? JSONDecoder().decode(PawvisSettings.self, from: data) {
        check("settings.roundtrip", decoded == settings)
    } else {
        check("settings.roundtrip", false)
    }

    // Launch-at-login: on by default, and the pure reconcile rules agree.
    // (Deliberately no SMAppService call — a smoke test must not leave a login
    // item registered on the machine that ran it.)
    check("launchAtLogin.defaultsOn", PawvisSettings.default.general.launchAtLogin)
    check("launchAtLogin.firstLaunchRegisters", LaunchAtLoginPolicy.reconcile(
        desired: true, status: .notRegistered, defaultApplied: false) == .register)
    check("launchAtLogin.respectsSystemSettingsRemoval", LaunchAtLoginPolicy.reconcile(
        desired: true, status: .notRegistered, defaultApplied: true) == .adoptDisabled)

    // Voice parser: one-shot commands, wake word required for each.
    let parser = VoiceControlParser()
    let typed = parser.parse("Pawvis type hello world")
    check("voice.wakeTypeIsOneShot", typed == VoiceParseResult(typing: [.type("hello world")]))
    check("voice.noWakeNoAction", parser.parse("type hello world") == VoiceParseResult())
    let goTo = parser.parse("Pawvis go to alexandria dot com")
    check("voice.goToParses", goTo.command == .goTo(url: "alexandria.com"))
    let press = parser.parse("Pavis press command shift T")
    check("voice.pressWithFuzzyWake",
          press.command == .press(KeyChord(key: "t", modifiers: [.command, .shift])))
    let open = parser.parse("Pawvis open Safari")
    check("voice.openParses", open.command == .open(app: "Safari"))
    check("voice.wakePrefixGate",
          parser.hasWakePrefix("Pawvis do the thing") && !parser.hasWakePrefix("random speech"))

    print(failures == 0 ? "SELFTEST OK (\(checks) checks)" : "SELFTEST FAILED (\(failures) failures)")
    return failures == 0 ? 0 : 1
}
