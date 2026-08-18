import XCTest
@testable import PawvisCore

final class GestureActionTests: XCTestCase {
    func testKeyChordMappings() {
        // Desktops are not chords: macOS ignores synthetic ⌃←/⌃→ for Spaces,
        // so the app switches through Mission Control's bar instead.
        XCTAssertNil(GestureAction(kind: .desktopLeft).keyChord)
        XCTAssertNil(GestureAction(kind: .desktopRight).keyChord)
        XCTAssertEqual(GestureAction(kind: .missionControl).keyChord,
                       KeyChord(key: "up", modifiers: [.control]))
        XCTAssertEqual(GestureAction(kind: .browserBack).keyChord,
                       KeyChord(key: "[", modifiers: [.command]))
        XCTAssertEqual(GestureAction(kind: .browserForward).keyChord,
                       KeyChord(key: "]", modifiers: [.command]))
        XCTAssertEqual(GestureAction(kind: .nextTab).keyChord,
                       KeyChord(key: "tab", modifiers: [.control]))
        XCTAssertEqual(GestureAction(kind: .keyboardShortcut, argument: "cmd+shift+t").keyChord,
                       KeyChord(key: "t", modifiers: [.command, .shift]))
        XCTAssertNil(GestureAction(kind: .windowLeftHalf).keyChord)
        XCTAssertNil(GestureAction(kind: .openApp, argument: "Safari").keyChord)
        // Volume/brightness ride the hardware media-key path like
        // play/pause — not synthesized key chords.
        XCTAssertNil(GestureAction(kind: .volumeUp).keyChord)
        XCTAssertNil(GestureAction(kind: .volumeDown).keyChord)
        XCTAssertNil(GestureAction(kind: .volumeMute).keyChord)
        XCTAssertNil(GestureAction(kind: .brightnessUp).keyChord)
        XCTAssertNil(GestureAction(kind: .brightnessDown).keyChord)
    }

    func testVolumeAndBrightnessAreMediaKeysInNavigation() {
        let mediaKinds: [GestureAction.Kind] = [
            .volumeUp, .volumeDown, .volumeMute, .brightnessUp, .brightnessDown,
        ]
        for kind in mediaKinds {
            XCTAssertEqual(kind.category, .navigation)
            XCTAssertFalse(kind.needsArgument)
        }
        XCTAssertEqual(GestureAction(kind: .volumeUp).feedback, "Volume up")
        XCTAssertEqual(GestureAction(kind: .volumeDown).feedback, "Volume down")
        XCTAssertEqual(GestureAction(kind: .volumeMute).feedback, "Volume muted")
        XCTAssertEqual(GestureAction(kind: .brightnessUp).feedback, "Brightness up")
        XCTAssertEqual(GestureAction(kind: .brightnessDown).feedback, "Brightness down")
    }

    func testEveryKindHasCategoryNameAndFeedback() {
        for kind in GestureAction.Kind.allCases {
            XCTAssertFalse(kind.displayName.isEmpty)
            let action = GestureAction(kind: kind, argument: "x")
            XCTAssertFalse(action.feedback.isEmpty)
            XCTAssertFalse(action.summary.isEmpty)
        }
    }

    func testCodableRoundTrip() throws {
        let action = GestureAction(kind: .runShellCommand, argument: "open -a Notes")
        let data = try JSONEncoder().encode(action)
        let decoded = try JSONDecoder().decode(GestureAction.self, from: data)
        XCTAssertEqual(decoded, action)
    }

    func testUnknownKindFailsToDecode() {
        let json = Data(#"{"kind":"summonDragons","argument":""}"#.utf8)
        XCTAssertThrowsError(try JSONDecoder().decode(GestureAction.self, from: json))
    }
}

final class ShortcutParserTests: XCTestCase {
    func testPlainForms() {
        XCTAssertEqual(ShortcutParser.chord(from: "cmd+shift+t"),
                       KeyChord(key: "t", modifiers: [.command, .shift]))
        XCTAssertEqual(ShortcutParser.chord(from: "control alt delete"),
                       KeyChord(key: "delete", modifiers: [.control, .option]))
        XCTAssertEqual(ShortcutParser.chord(from: "ctrl-alt-t"),
                       KeyChord(key: "t", modifiers: [.control, .option]))
        XCTAssertEqual(ShortcutParser.chord(from: "F5"), KeyChord(key: "f5"))
        XCTAssertEqual(ShortcutParser.chord(from: "space"), KeyChord(key: "space"))
        XCTAssertEqual(ShortcutParser.chord(from: "cmd+["),
                       KeyChord(key: "[", modifiers: [.command]))
    }

    func testSymbolForms() {
        XCTAssertEqual(ShortcutParser.chord(from: "⌘⇧T"),
                       KeyChord(key: "t", modifiers: [.command, .shift]))
        XCTAssertEqual(ShortcutParser.chord(from: "⌃⌥→"),
                       KeyChord(key: "right", modifiers: [.control, .option]))
        XCTAssertEqual(ShortcutParser.chord(from: "^t"),
                       KeyChord(key: "t", modifiers: [.control]))
    }

    func testRejects() {
        XCTAssertNil(ShortcutParser.chord(from: ""))
        XCTAssertNil(ShortcutParser.chord(from: "cmd+shift")) // no key
        XCTAssertNil(ShortcutParser.chord(from: "cmd+banana"))
        XCTAssertNil(ShortcutParser.chord(from: "t shift")) // modifier after key
        XCTAssertNil(ShortcutParser.chord(from: "a b")) // two keys
    }

    func testDisplay() {
        XCTAssertEqual(ShortcutParser.display(KeyChord(key: "t", modifiers: [.command, .shift])),
                       "⇧⌘T")
        XCTAssertEqual(ShortcutParser.display(KeyChord(key: "return", modifiers: [])), "↩")
        XCTAssertEqual(ShortcutParser.display(KeyChord(key: "left", modifiers: [.control])), "⌃←")
    }
}

final class WindowPlacementTests: XCTestCase {
    private let screen = WindowPlacement.Frame(x: 0, y: 25, width: 1200, height: 775)
    private let window = WindowPlacement.Frame(x: 100, y: 100, width: 600, height: 400)

    private func place(_ kind: GestureAction.Kind) -> WindowPlacement.Frame? {
        WindowPlacement.frame(for: kind, visible: screen, current: window)
    }

    func testHalves() {
        XCTAssertEqual(place(.windowLeftHalf),
                       WindowPlacement.Frame(x: 0, y: 25, width: 600, height: 775))
        XCTAssertEqual(place(.windowRightHalf),
                       WindowPlacement.Frame(x: 600, y: 25, width: 600, height: 775))
        XCTAssertEqual(place(.windowTopHalf),
                       WindowPlacement.Frame(x: 0, y: 25, width: 1200, height: 387.5))
        XCTAssertEqual(place(.windowBottomHalf),
                       WindowPlacement.Frame(x: 0, y: 412.5, width: 1200, height: 387.5))
    }

    func testThirds() {
        XCTAssertEqual(place(.windowLeftTwoThirds),
                       WindowPlacement.Frame(x: 0, y: 25, width: 800, height: 775))
        XCTAssertEqual(place(.windowRightTwoThirds),
                       WindowPlacement.Frame(x: 400, y: 25, width: 800, height: 775))
        XCTAssertEqual(place(.windowLeftThird),
                       WindowPlacement.Frame(x: 0, y: 25, width: 400, height: 775))
        XCTAssertEqual(place(.windowRightThird),
                       WindowPlacement.Frame(x: 800, y: 25, width: 400, height: 775))
    }

    func testQuarters() {
        XCTAssertEqual(place(.windowTopLeftQuarter),
                       WindowPlacement.Frame(x: 0, y: 25, width: 600, height: 387.5))
        XCTAssertEqual(place(.windowBottomRightQuarter),
                       WindowPlacement.Frame(x: 600, y: 412.5, width: 600, height: 387.5))
    }

    func testMaximizeAndCenter() {
        XCTAssertEqual(place(.windowMaximize), screen)
        XCTAssertEqual(place(.windowCenter),
                       WindowPlacement.Frame(x: 300, y: 212.5, width: 600, height: 400))
    }

    func testCenterShrinksOversizedWindow() {
        let huge = WindowPlacement.Frame(x: 0, y: 0, width: 4000, height: 3000)
        let centered = WindowPlacement.frame(for: .windowCenter, visible: screen, current: huge)
        XCTAssertEqual(centered, screen)
    }

    func testNonPlacementKindsReturnNil() {
        XCTAssertNil(place(.windowMinimize))
        XCTAssertNil(place(.windowNextDisplay))
        XCTAssertNil(place(.desktopLeft))
        XCTAssertNil(place(.openApp))
        XCTAssertNil(place(.volumeUp))
    }

    func testTranslatedKeepsRelativePlacement() {
        let source = WindowPlacement.Frame(x: 0, y: 0, width: 1000, height: 800)
        let target = WindowPlacement.Frame(x: 1000, y: 100, width: 2000, height: 1000)
        let window = WindowPlacement.Frame(x: 0, y: 0, width: 500, height: 800)
        let moved = WindowPlacement.translated(window, from: source, to: target)
        XCTAssertEqual(moved, WindowPlacement.Frame(x: 1000, y: 100, width: 1000, height: 1000))
    }
}

final class CustomGestureSettingsTests: XCTestCase {
    func testDefaultsDetectNothing() {
        let settings = CustomGestureSettings()
        XCTAssertTrue(settings.bindings.isEmpty)
        XCTAssertTrue(settings.detectorConfig().enabled.isEmpty)
    }

    func testBoundGestureIsEnabledUnboundIsNot() {
        var settings = CustomGestureSettings()
        settings.bindings = [
            CustomGestureBinding(gesture: .thumbsRight,
                                 action: GestureAction(kind: .desktopRight)),
            CustomGestureBinding(gesture: .fingerWiggle), // no action yet
        ]
        XCTAssertEqual(settings.detectorConfig().enabled, [.thumbsRight])
        XCTAssertEqual(settings.action(for: .thumbsRight)?.kind, .desktopRight)
        XCTAssertNil(settings.action(for: .fingerWiggle))
    }

    func testMasterSwitchDisablesDetectionAndActions() {
        var settings = CustomGestureSettings()
        settings.bindings = [CustomGestureBinding(
            gesture: .thumbsRight, action: GestureAction(kind: .desktopRight))]
        settings.enabled = false
        XCTAssertTrue(settings.detectorConfig().enabled.isEmpty)
        XCTAssertNil(settings.action(for: .thumbsRight))
    }

    func testSensitivityFlowsIntoDetectorConfig() {
        var settings = CustomGestureSettings()
        settings.bindings = [CustomGestureBinding(
            gesture: .fingerWiggle, action: GestureAction(kind: .playPause))]
        settings.wiggleReversals = 5
        settings.holdSeconds = 0.6
        settings.flingTravel = 0.25
        settings.gatherSpread = 0.45
        let config = settings.detectorConfig()
        XCTAssertEqual(config.wiggleReversals, 5)
        XCTAssertEqual(config.holdSeconds, 0.6)
        XCTAssertEqual(config.flingTravel, 0.25)
        XCTAssertEqual(config.gatherSpread, 0.45)
    }

    func testUnknownBindingDropsAloneAndDuplicatesCollapse() throws {
        // "swipeRight" is a real retired gesture: saved swipe bindings must
        // drop exactly like unknown future ones.
        let json = Data("""
        {"enabled": true, "bindings": [
            {"gesture": "fingerWiggle", "action": {"kind": "missionControl", "argument": ""}},
            {"gesture": "swipeRight", "action": {"kind": "desktopRight", "argument": ""}},
            {"gesture": "thumbsUp", "action": {"kind": "portalGun", "argument": ""}},
            {"gesture": "fingerWiggle", "action": {"kind": "desktopLeft", "argument": ""}}
        ]}
        """.utf8)
        let settings = try JSONDecoder().decode(CustomGestureSettings.self, from: json)
        XCTAssertEqual(settings.bindings.map(\.gesture), [.fingerWiggle, .thumbsUp])
        // The unknown *action* keeps its binding, unbound.
        XCTAssertNil(settings.binding(for: .thumbsUp)?.action)
        // The duplicate keeps the first occurrence.
        XCTAssertEqual(settings.binding(for: .fingerWiggle)?.action?.kind, .missionControl)
    }

    func testSettingsTreeRoundTripsWithBindings() throws {
        var settings = PawvisSettings.default
        settings.customGestures.bindings = [
            CustomGestureBinding(gesture: .grabFlingLeft,
                                 action: GestureAction(kind: .windowLeftHalf)),
            CustomGestureBinding(gesture: .fingerWiggle,
                                 action: GestureAction(kind: .runShellCommand,
                                                       argument: "say hi")),
        ]
        settings.customGestures.holdSeconds = 0.5
        let data = try JSONEncoder().encode(settings)
        let decoded = try JSONDecoder().decode(PawvisSettings.self, from: data)
        XCTAssertEqual(decoded, settings)
    }

    func testGestureMetadataIsComplete() {
        for gesture in CustomGesture.allCases {
            XCTAssertFalse(gesture.displayName.isEmpty)
            XCTAssertFalse(gesture.howTo.isEmpty)
            XCTAssertFalse(gesture.glyphName.isEmpty)
            XCTAssertFalse(gesture.symbolName.isEmpty)
        }
    }
}
