import AppKit
import Foundation
import PawvisCore

/// A fully-jointed open hand for driving the engine (the custom-gesture
/// smoke needs a pose that passes the strict open-hand check, which the
/// partial hand below deliberately can't).
private func openHand(wrist: Vec2, scale: Double = 0.15) -> Hand {
    var joints: [HandJoint: Vec2] = [.wrist: wrist]
    let dirs: [(Finger, Vec2, Vec2)] = [
        (.index, Vec2(-0.25, -0.95), Vec2(0.06, -0.998)),
        (.middle, Vec2(0, -1.0), Vec2(0, -1)),
        (.ring, Vec2(0.22, -0.95), Vec2(-0.03, -1)),
        (.little, Vec2(0.42, -0.85), Vec2(-0.10, -0.995)),
    ]
    for (finger, mcpOffset, dir) in dirs {
        let mcp = wrist + mcpOffset * scale
        joints[finger.mcp] = mcp
        joints[finger.pip] = mcp + dir * (0.45 * scale)
        joints[finger.dip] = mcp + dir * (0.70 * scale)
        joints[finger.tip] = mcp + dir * (0.95 * scale)
    }
    let thumbTip = wrist + Vec2(-0.95, -0.70) * scale
    joints[.thumbCMC] = wrist + Vec2(-0.35, -0.25) * scale
    joints[.thumbMP] = wrist.lerp(to: thumbTip, t: 0.45)
    joints[.thumbIP] = wrist.lerp(to: thumbTip, t: 0.72)
    joints[.thumbTip] = thumbTip
    return Hand(chirality: .right, confidence: 1, joints: joints)
}

/// The grab pose: every fingertip (thumb included) bunched at one point in
/// front of the palm — the fling smoke's gathered hand.
private func gatheredHand(wrist: Vec2, scale: Double = 0.15) -> Hand {
    var hand = openHand(wrist: wrist, scale: scale)
    let bunch = wrist + Vec2(-0.3, -1.5) * scale
    let tips: [HandJoint] = [.thumbTip, .indexTip, .middleTip, .ringTip, .littleTip]
    for (i, tip) in tips.enumerated() {
        hand.setPoint(bunch + Vec2(Double(i) * 0.02 - 0.04, 0) * scale, for: tip)
    }
    return hand
}

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

    // Custom gestures: a bound grab & fling fires through the engine end to
    // end, and the settings tree carries bindings intact.
    var customEngineConfig = GestureConfig.default
    customEngineConfig.controlTrigger = .anyHand
    customEngineConfig.mirrorCamera = false
    customEngineConfig.reachMode = .manual
    customEngineConfig.interactionBox = InteractionBox(xMin: 0, xMax: 1, yMin: 0, yMax: 1)
    customEngineConfig.smoothing = OneEuroFilter.Params(minCutoff: 1e9, beta: 0, dCutoff: 1e9)
    let customEngine = GestureEngine(config: customEngineConfig)
    var customDetection = CustomGestureDetector.Config()
    customDetection.enabled = [.grabFlingRight]
    customEngine.customConfig = customDetection
    var flingFired = false
    var wrist = Vec2(0.4, 0.55)
    var tick = 0.0
    for i in 0..<16 {
        let hand: Hand
        if i < 3 {
            hand = openHand(wrist: wrist) // pause open: the deliberate transition
        } else {
            if i >= 6 { wrist = wrist + Vec2(0.03, 0) } // gather at rest, then fling
            hand = gatheredHand(wrist: wrist)
        }
        let (events, _) = customEngine.process(HandFrame(time: tick, hands: [hand]))
        if events.contains(.customGesture(.grabFlingRight)) { flingFired = true }
        tick += 1.0 / 30
    }
    check("customGesture.boundFlingFires", flingFired)

    var boundSettings = PawvisSettings.default
    boundSettings.customGestures.bindings = [
        CustomGestureBinding(gesture: .grabFlingLeft,
                             action: GestureAction(kind: .windowLeftHalf)),
    ]
    if let data = try? JSONEncoder().encode(boundSettings),
       let decoded = try? JSONDecoder().decode(PawvisSettings.self, from: data) {
        check("customGesture.settingsRoundtrip", decoded == boundSettings)
    } else {
        check("customGesture.settingsRoundtrip", false)
    }
    check("customGesture.shortcutParses",
          ShortcutParser.chord(from: "cmd+shift+t")
          == KeyChord(key: "t", modifiers: [.command, .shift]))
    check("customGesture.actionChordPressable",
          GestureAction(kind: .browserBack).keyChord.map(TextTyper.canPress) == true)

    // Launch-at-login: on by default, and the pure reconcile rules agree.
    // (Deliberately no SMAppService call — a smoke test must not leave a login
    // item registered on the machine that ran it.)
    check("launchAtLogin.defaultsOn", PawvisSettings.default.general.launchAtLogin)
    check("launchAtLogin.firstLaunchRegisters", LaunchAtLoginPolicy.reconcile(
        desired: true, status: .notRegistered, defaultApplied: false) == .register)
    check("launchAtLogin.respectsSystemSettingsRemoval", LaunchAtLoginPolicy.reconcile(
        desired: true, status: .notRegistered, defaultApplied: true) == .adoptDisabled)

    // First run: the welcome tour shows only for a genuinely new install.
    // An install that already granted the camera predates onboarding and
    // adopts completion instead; automated (PAWVIS_NO_AUTOSTART) runs stay
    // headless and leave the flag alone.
    check("firstRun.newInstallSeesWelcome", FirstRunPolicy.verdict(
        completed: false, cameraGranted: false, automated: false) == .showWelcome)
    check("firstRun.grantedCameraAdoptsCompleted", FirstRunPolicy.verdict(
        completed: false, cameraGranted: true, automated: false) == .adoptCompleted)
    check("firstRun.completedLaunchesNormally", FirstRunPolicy.verdict(
        completed: true, cameraGranted: false, automated: false) == .proceedNormally)
    check("firstRun.automatedRunsStayHeadless", FirstRunPolicy.verdict(
        completed: false, cameraGranted: false, automated: true) == .proceedNormally)

    // Look-to-control: on by default; only a *sustained* look away closes
    // the gate, a press in flight holds it open, and looking back reopens
    // it.
    check("attention.defaultsOn", PawvisSettings.default.attention.enabled)
    var attentionOn = AttentionConfig()
    attentionOn.enabled = true
    var attentionGate = AttentionGate(config: attentionOn.gateConfig())
    let attentionAway = AttentionGate.Observation(faceSeen: true, yaw: 1.2)
    check("attention.glanceCostsNothing",
          attentionGate.assess(attentionAway, interacting: false, at: 0)
          && attentionGate.assess(attentionAway, interacting: false, at: 0.5))
    check("attention.sustainedAwayCloses",
          !attentionGate.assess(attentionAway, interacting: false, at: 1.5))
    check("attention.heldPressHoldsOpen", {
        var gate = AttentionGate(config: attentionOn.gateConfig())
        _ = gate.assess(attentionAway, interacting: true, at: 0)
        return gate.assess(attentionAway, interacting: true, at: 30)
    }())
    check("attention.lookingBackReopens", {
        let facing = AttentionGate.Observation(faceSeen: true, yaw: 0, pitch: 0)
        _ = attentionGate.assess(facing, interacting: false, at: 2)
        return attentionGate.assess(facing, interacting: false, at: 2.5)
    }())

    // Voice parser: one-shot commands, wake word required for each.
    let parser = VoiceControlParser()
    let typed = parser.parse("Pawvis type hello world")
    check("voice.wakeTypeIsOneShot", typed == VoiceParseResult(typing: [.type("hello world")]))
    check("voice.noWakeNoAction", parser.parse("type hello world") == VoiceParseResult())
    let goTo = parser.parse("Pawvis go to alexandria dot com")
    check("voice.goToParses", goTo.command == .goTo(url: "alexandria.com", app: nil))
    let press = parser.parse("Pavis press command shift T")
    check("voice.pressWithFuzzyWake",
          press.command == .press(KeyChord(key: "t", modifiers: [.command, .shift])))
    let open = parser.parse("Pawvis open Safari")
    check("voice.openParses", open.command == .open(app: "Safari"))
    check("voice.wakePrefixGate",
          parser.hasWakePrefix("Pawvis do the thing") && !parser.hasWakePrefix("random speech"))
    check("voice.bareStopCancels", parser.parse("Pawvis stop").command == .cancelActivity)
    check("voice.stopListeningStillStops",
          parser.parse("Pawvis stop listening").command == .stopVoiceControl)
    check("voice.closeWindowChord", parser.parse("Pawvis close the window").command
          == .press(KeyChord(key: "w", modifiers: [.command])))
    check("voice.parseableCompositeBecomesSequence",
          parser.parse("Pawvis close the window and open Safari").command
          == .sequence([.press(KeyChord(key: "w", modifiers: [.command])),
                        .open(app: "Safari")]))
    check("voice.reportedCompositeIsDeterministic",
          parser.parse("Pawvis pause this, open up a new tab, and go to youtube dot com").command
          == .sequence([.mediaKey(.playPause),
                        .press(KeyChord(key: "t", modifiers: [.command])),
                        .goTo(url: "youtube.com", app: nil)]))
    check("voice.unownedClauseStaysWhole",
          parser.parse("Pawvis close the window and click submit").command
          == .resolve(transcript: "close the window and click submit"))
    check("voice.fillerBeforeWakeStillWakes",
          parser.parse("Um, Pawvis, open Safari").command == .open(app: "Safari"))

    // Agent confirm answers live in their own parse entry: "yes" answers a
    // pending read-back and is never a general command, stop still denies,
    // and a real command is a replacement, not an answer. The read-back
    // itself defaults ON.
    check("voice.confirmYesAnswersOnlyTheReadBack",
          parser.confirmResponse("yes") == .confirm
          && parser.parse("Pawvis yes").command == .resolve(transcript: "yes"))
    check("voice.confirmStopDenies", parser.confirmResponse("please stop") == .deny)
    check("voice.confirmCommandIsNotAnAnswer",
          parser.confirmResponse("open safari") == nil)
    check("voice.agentConfirmDefaultsOn", VoiceControlConfig().agentConfirm)

    // Wake-acceptance hardening: "jarvis" left the default aliases (a stock
    // movie wake word gave any TV audio a full-trust accept), and agent mode
    // runs the ladder strict — no glued-speech tier, and the capture window
    // takes only finals that parse deterministically or carry the wake word.
    check("voice.defaultAliasesExcludeJarvis",
          !VoiceControlConfig().wakeWordAliases.contains("jarvis")
          && parser.parse("Jarvis open Safari") == VoiceParseResult())
    check("voice.shortWakeWordsHaveNoFuzz",
          !VoiceControlParser.supportsFuzzyMatching("rex")
          && VoiceControlParser.supportsFuzzyMatching("Pawvis"))
    let strictParser = VoiceControlParser()
    strictParser.config.strictWake = true
    check("voice.strictWakeRefusesGluedSpeech",
          strictParser.parse("anyway whatever Pawvis open Safari") == VoiceParseResult()
          && parser.parse("anyway whatever Pawvis open Safari").command == .open(app: "Safari"))
    check("voice.strictWakeKeepsInitialAndFillerTiers",
          strictParser.parse("Pawvis quit chrome").command == .quit(app: "chrome")
          && strictParser.parse("Um, Pawvis, open Safari").command == .open(app: "Safari"))
    var strictGate = UtteranceGate()
    let strictBar: (String) -> Bool = { strictParser.remainderIsDeterministicCommand($0) }
    check("voice.strictWindowArmsOnBareWake",
          strictGate.decide(remainder: "", transcript: "Pawvis", now: 0,
                            strictCommandBar: strictBar) == .armed)
    check("voice.strictWindowRefusesAmbientFinal",
          strictGate.decide(remainder: nil, transcript: "she went home yesterday", now: 1,
                            strictCommandBar: strictBar) == .ignored)
    var verbatimGate = UtteranceGate()
    _ = verbatimGate.decide(remainder: "", transcript: "Pawvis", now: 0)
    check("voice.defaultWindowStaysVerbatim",
          verbatimGate.decide(remainder: nil, transcript: "she went home yesterday", now: 1)
          == .command("she went home yesterday"))

    // Voice routing: the simple-operations class must resolve in the
    // deterministic grammar and NEVER reach the GUI loop. This table is the
    // completion criterion for "open discord dot com in Chrome"-class
    // commands — the case the loop once spent two minutes flailing on.
    let simpleRoutes: [(String, VoiceCommand)] = [
        ("open discord dot com in Chrome", .goTo(url: "discord.com", app: "Chrome")),
        ("open discord dot com", .goTo(url: "discord.com", app: nil)),
        ("go to github dot com in safari", .goTo(url: "github.com", app: "safari")),
        ("open discord in chrome", .webSearch(query: "discord", app: "chrome")),
        ("search for sloth videos in firefox",
         .webSearch(query: "sloth videos", app: "firefox")),
        ("open notes", .open(app: "notes")),
    ]
    for (utterance, expected) in simpleRoutes {
        check("voice.route.\(utterance)",
              parser.parse("Pawvis \(utterance)").command == expected)
    }
    check("voice.multiClauseOpenIsATaskNotAnAppName",
          parser.parse("Pawvis open notes and start a new note").command
          == .resolve(transcript: "open notes and start a new note"))
    // Free-form commands translate before they loop; only genuinely visual
    // goals go straight to the screen.
    check("voice.clickGoalsGoStraightToLoop",
          AutopilotPolicy.goesStraightToLoop(goal: "click sign in"))
    check("voice.freeFormTranslatesFirst",
          !AutopilotPolicy.goesStraightToLoop(goal: "make the text bigger"))
    check("voice.translationCompiles",
          TranslationPolicy.command(from: IntentTranslation(
              intent: .goToURL, argument: "discord dot com", app: "Chrome"))
          == .goTo(url: "discord.com", app: "Chrome"))
    check("voice.needsScreenStaysVisual",
          TranslationPolicy.command(from: IntentTranslation(intent: .needsScreen)) == nil)

    // Autopilot policy: the pure loop rules the engine runs on.
    check("autopilot.multiClauseStartsFullScreen",
          AutopilotPolicy.initialScope(goal: "open notes and start a new note") == .fullScreen)
    check("autopilot.simpleGoalStartsNearPointer",
          AutopilotPolicy.initialScope(goal: "click sign in") == .nearPointer)
    let prompt = AutopilotPolicy.buildPrompt(
        goal: "click sign in", history: [],
        screen: AutopilotScreen(elements: [
            AutopilotElement(label: "Sign in", kind: "button", actionable: true,
                             x: 10, y: 10, width: 80, height: 24),
        ]),
        tokenBudget: 2000)
    check("autopilot.promptGoalLast", prompt.hasSuffix("Goal: “click sign in”"))
    let stuck = AutopilotPolicy.ProposedRecord(
        signature: 1, step: AutopilotStep(action: .click, elementIndex: 0))
    check("autopilot.noProgressAborts",
          AutopilotPolicy.shouldAbortNoProgress([stuck, stuck, stuck]))

    // Desktop switching steps between *desktops*: the window server's ring
    // mixes user desktops (type 0) with full-screen app spaces (type 4),
    // and stepping into someone's full-screen window reads as window
    // shuffling, not desktop switching (measured: the reported symptom).
    let ring: [SpaceSwitcher.Space] = [
        .init(id: 1, isDesktop: true), .init(id: 40, isDesktop: false),
        .init(id: 2, isDesktop: true), .init(id: 41, isDesktop: false),
        .init(id: 3, isDesktop: true),
    ]
    check("spaces.rightSkipsFullscreen",
          SpaceSwitcher.neighborDesktop(in: ring, active: 1, direction: .right) == 2)
    check("spaces.leftSkipsFullscreen",
          SpaceSwitcher.neighborDesktop(in: ring, active: 3, direction: .left) == 2)
    check("spaces.fullscreenExitsToNearestDesktop",
          SpaceSwitcher.neighborDesktop(in: ring, active: 41, direction: .left) == 2)
    check("spaces.edgeReportsNoNeighbor",
          SpaceSwitcher.neighborDesktop(in: ring, active: 1, direction: .left) == nil)
    // The Dock-swipe walks every ring entry, so a skipped full-screen
    // space costs an extra swipe step; exiting a full-screen space to the
    // adjacent desktop is a single step.
    check("spaces.swipeCrossesFullscreenInTwoSteps",
          SpaceSwitcher.swipeSteps(in: ring, from: 1, to: 2) == 2)
    check("spaces.swipeExitsFullscreenInOneStep",
          SpaceSwitcher.swipeSteps(in: ring, from: 41, to: 2) == 1)
    check("spaces.swipeStepsNilOffRing",
          SpaceSwitcher.swipeSteps(in: ring, from: 99, to: 2) == nil)
    // The swipe lands on the display under the pointer, so that display is
    // the one whose ring gets walked — matched by UUID, with nothing to
    // choose in the single-display (or spanning "Main") arrangement, and a
    // refusal rather than a guess when the match fails.
    let uuidA = "AAAAAAAA-0000-0000-0000-000000000000"
    let twoDisplays: [SpaceSwitcher.DisplayRing] = [
        .init(identifier: uuidA, current: 1, spaces: ring),
        .init(identifier: "BBBBBBBB-0000-0000-0000-000000000000", current: 7,
              spaces: [.init(id: 7, isDesktop: true), .init(id: 8, isDesktop: true)]),
    ]
    check("spaces.singleDisplayNeedsNoPointerMatch",
          SpaceSwitcher.pointerDisplay(
              in: [.init(identifier: "Main", current: 1, spaces: ring)],
              pointerUUID: nil)?.identifier == "Main")
    check("spaces.pointerPicksItsDisplay",
          SpaceSwitcher.pointerDisplay(in: twoDisplays, pointerUUID: uuidA)?.current == 1)
    check("spaces.unmatchedPointerRefuses",
          SpaceSwitcher.pointerDisplay(in: twoDisplays, pointerUUID: "CCCC") == nil)

    // Menu chips stay readable in both appearances. These sit on translucent
    // menu material where a too-light fill has washed out before, so the
    // check is on the numbers rather than on someone remembering to look:
    // every chip's type must clear WCAG AA (4.5:1) against its own fill,
    // in light mode and in dark. Resolving them here also proves the
    // dynamic colors actually flip, which a fixed palette never had to.
    for (name, chip) in PawvisTheme.allChips {
        for (appearanceName, appearance) in [("light", NSAppearance.Name.aqua),
                                             ("dark", NSAppearance.Name.darkAqua)] {
            guard let appearance = NSAppearance(named: appearance) else {
                check("chips.\(name).\(appearanceName)Available", false)
                continue
            }
            let fill = chip.fill.resolved(for: appearance)
            let text = chip.text.resolved(for: appearance)
            let ratio = fill.contrastRatio(against: text)
            check("chips.\(name).\(appearanceName)ContrastAA \(String(format: "%.2f", ratio)):1",
                  ratio >= 4.5)
        }
        // A chip that resolves to one color in both appearances is a chip
        // that forgot to be dynamic.
        let light = chip.fill.resolved(for: NSAppearance(named: .aqua)!)
        let dark = chip.fill.resolved(for: NSAppearance(named: .darkAqua)!)
        check("chips.\(name).fillIsDynamic", light != dark)
    }

    // The Gesture Guide's posed hands have to be *in* the bundle. Missing art
    // doesn't crash and doesn't look broken: every row quietly falls back to
    // an SF Symbol, which is exactly the wrong-gesture picture the drawings
    // replaced. Only worth asserting from a real bundle — a bare binary has
    // no Resources to look in, and CI runs this against `build/Pawvis.app`.
    if Bundle.main.bundleIdentifier != nil, Bundle.main.bundleURL.pathExtension == "app" {
        // Every finger the right-click picker offers needs its own pose; the
        // index is not one of them (it already drives the left button). Every
        // custom gesture ships a pose too — the gallery and the guide both
        // draw them.
        let poses = ["take-control", "move", "click", "drag", "scroll", "stop-tracking"]
            + Finger.allCases.filter { $0 != .index }.map { "right-click-\($0.rawValue)" }
            + CustomGesture.allCases.map(\.glyphName)
        for name in poses {
            check("guide.glyph.\(name)", PawvisGlyph.gesture(name, size: 40) != nil)
        }
        // The guide's whole-gesture panels (`full-*`), one per row it can
        // show — same fallback story, same reason to assert.
        let panels = ["full-take-control", "full-move", "full-click", "full-drag",
                      "full-scroll", "full-stop-tracking", "full-wiggle",
                      "full-wiggle-pointed", "full-thumbs", "full-shaka", "full-grab"]
            + Finger.allCases.filter { $0 != .index }.map { "full-right-click-\($0.rawValue)" }
        for name in panels {
            check("guide.panel.\(name)", PawvisGlyph.guidePanel(name, width: 108) != nil)
        }
    }

    print(failures == 0 ? "SELFTEST OK (\(checks) checks)" : "SELFTEST FAILED (\(failures) failures)")
    return failures == 0 ? 0 : 1
}
