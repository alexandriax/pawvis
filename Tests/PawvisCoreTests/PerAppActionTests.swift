import Foundation
import XCTest
@testable import PawvisCore

/// The per-app binding rule: one gesture, different apps, different actions.
/// The decision is a pure function (`PerAppAction`), so every branch is
/// spelled out here; the app layer only supplies the frontmost bundle ID.
final class PerAppActionTests: XCTestCase {
    private let keynote = AppActionOverride(
        bundleID: "com.apple.iWork.Keynote", appName: "Keynote",
        action: GestureAction(kind: .pressReturn))
    private let chrome = AppActionOverride(
        bundleID: "com.google.Chrome", appName: "Google Chrome",
        action: GestureAction(kind: .keyboardShortcut, argument: "cmd+shift+m"))
    private let base = GestureAction(kind: .playPause)

    // MARK: - The pure resolution rule

    func testBaseOnlyResolvesBaseEverywhere() {
        XCTAssertEqual(PerAppAction.resolve(base: base, overrides: [],
                                            frontmostBundleID: "com.apple.Safari"), base)
        XCTAssertEqual(PerAppAction.resolve(base: base, overrides: [],
                                            frontmostBundleID: nil), base)
    }

    func testMatchingOverrideWinsOverBase() {
        let resolved = PerAppAction.resolve(base: base, overrides: [keynote, chrome],
                                            frontmostBundleID: "com.google.Chrome")
        XCTAssertEqual(resolved, chrome.action)
    }

    func testNoMatchFallsBackToBase() {
        let resolved = PerAppAction.resolve(base: base, overrides: [keynote, chrome],
                                            frontmostBundleID: "com.apple.Safari")
        XCTAssertEqual(resolved, base)
    }

    func testUnknownFrontmostFallsBackToBase() {
        XCTAssertEqual(PerAppAction.resolve(base: base, overrides: [keynote],
                                            frontmostBundleID: nil), base)
    }

    func testOverridesWithoutBaseGateTheGestureToTheirApps() {
        // The app-gated gesture: fires in the listed apps, nowhere else.
        XCTAssertEqual(PerAppAction.resolve(base: nil, overrides: [keynote],
                                            frontmostBundleID: keynote.bundleID),
                       keynote.action)
        XCTAssertNil(PerAppAction.resolve(base: nil, overrides: [keynote],
                                          frontmostBundleID: "com.apple.Safari"))
        XCTAssertNil(PerAppAction.resolve(base: nil, overrides: [keynote],
                                          frontmostBundleID: nil))
    }

    func testNilEverythingIsInert() {
        XCTAssertNil(PerAppAction.resolve(base: nil, overrides: [],
                                          frontmostBundleID: "com.apple.Safari"))
        XCTAssertNil(PerAppAction.resolve(base: nil, overrides: [],
                                          frontmostBundleID: nil))
    }

    func testUnassignedOverrideChangesNothing() {
        // An override row waiting for its action behaves like it isn't there.
        let waiting = AppActionOverride(bundleID: "com.apple.Safari", appName: "Safari")
        XCTAssertEqual(PerAppAction.resolve(base: base, overrides: [waiting],
                                            frontmostBundleID: "com.apple.Safari"), base)
        XCTAssertNil(PerAppAction.resolve(base: nil, overrides: [waiting],
                                          frontmostBundleID: "com.apple.Safari"))
    }

    func testFiresAnywhereIsTheDetectionGate() {
        let waiting = AppActionOverride(bundleID: "com.apple.Safari", appName: "Safari")
        XCTAssertTrue(PerAppAction.firesAnywhere(base: base, overrides: []))
        XCTAssertTrue(PerAppAction.firesAnywhere(base: nil, overrides: [keynote]))
        XCTAssertFalse(PerAppAction.firesAnywhere(base: nil, overrides: [waiting]))
        XCTAssertFalse(PerAppAction.firesAnywhere(base: nil, overrides: []))
    }

    // MARK: - Through CustomGestureSettings

    private var settingsWithOverrides: CustomGestureSettings {
        var settings = CustomGestureSettings()
        settings.bindings = [
            CustomGestureBinding(gesture: .thumbsUp, action: base,
                                 overrides: [keynote, chrome]),
            CustomGestureBinding(gesture: .shaka, overrides: [keynote]), // app-gated
        ]
        return settings
    }

    func testSettingsResolveTheFrontmostOverride() {
        let settings = settingsWithOverrides
        XCTAssertEqual(settings.action(for: .thumbsUp,
                                       frontmostBundleID: keynote.bundleID),
                       keynote.action)
        XCTAssertEqual(settings.action(for: .thumbsUp,
                                       frontmostBundleID: "com.apple.Safari"), base)
        XCTAssertEqual(settings.action(for: .shaka,
                                       frontmostBundleID: keynote.bundleID),
                       keynote.action)
        XCTAssertNil(settings.action(for: .shaka, frontmostBundleID: "com.apple.Safari"))
    }

    func testMasterSwitchStillWinsOverOverrides() {
        var settings = settingsWithOverrides
        settings.enabled = false
        XCTAssertNil(settings.action(for: .thumbsUp, frontmostBundleID: keynote.bundleID))
        XCTAssertTrue(settings.detectorConfig().enabled.isEmpty)
    }

    func testAppGatedBindingIsStillDetected() {
        // No base action, but a per-app one: the detector must watch it —
        // the frontmost check happens at fire time.
        XCTAssertEqual(settingsWithOverrides.detectorConfig().enabled, [.thumbsUp, .shaka])

        // All-unassigned everywhere is not detected at all.
        var settings = CustomGestureSettings()
        settings.bindings = [CustomGestureBinding(
            gesture: .shaka,
            overrides: [AppActionOverride(bundleID: "com.apple.Safari", appName: "Safari")])]
        XCTAssertTrue(settings.detectorConfig().enabled.isEmpty)
    }

    // MARK: - Persistence

    func testSettingsTreeRoundTripsWithOverrides() throws {
        var settings = PawvisSettings.default
        settings.customGestures = settingsWithOverrides
        settings.trainedGestures.gestures = [TrainedGesture(
            name: "Sweep", handCount: 1, template: [[0.1, 0.2]],
            duration: 0.5, baseThreshold: 0.1,
            action: nil, overrides: [chrome])]
        let data = try JSONEncoder().encode(settings)
        let decoded = try JSONDecoder().decode(PawvisSettings.self, from: data)
        XCTAssertEqual(decoded, settings)
    }

    func testUnreadableOverrideDropsAloneAndDuplicatesCollapse() throws {
        // No bundleID = no override (drops alone); an unknown action kind
        // keeps its row, unassigned; a duplicate app keeps the first row.
        let json = Data("""
        {"bindings": [
            {"gesture": "thumbsUp",
             "action": {"kind": "playPause", "argument": ""},
             "overrides": [
                {"appName": "Broken, no bundle id",
                 "action": {"kind": "pressReturn", "argument": ""}},
                {"bundleID": "com.apple.Safari", "appName": "Safari",
                 "action": {"kind": "portalGun", "argument": ""}},
                {"bundleID": "com.google.Chrome", "appName": "Google Chrome",
                 "action": {"kind": "nextTab", "argument": ""}},
                {"bundleID": "com.google.Chrome", "appName": "Chrome again",
                 "action": {"kind": "previousTab", "argument": ""}}
             ]}
        ]}
        """.utf8)
        let settings = try JSONDecoder().decode(CustomGestureSettings.self, from: json)
        let binding = try XCTUnwrap(settings.binding(for: .thumbsUp))
        XCTAssertEqual(binding.action?.kind, .playPause, "the binding itself is untouched")
        XCTAssertEqual(binding.overrides.map(\.bundleID),
                       ["com.apple.Safari", "com.google.Chrome"])
        XCTAssertNil(binding.overrides[0].action, "unknown kind leaves the row unassigned")
        XCTAssertEqual(binding.overrides[1].action?.kind, .nextTab,
                       "the duplicate keeps the first occurrence")
    }

    func testTrainedGestureKeepsItsRecordWhenAnOverrideIsUnreadable() throws {
        let json = Data("""
        {"gestures": [
            {"id": "6F9619FF-8B86-D011-B42D-00C04FC964FF", "name": "Good",
             "handCount": 1, "template": [[0.1, 0.2]], "duration": 0.5,
             "baseThreshold": 0.1,
             "overrides": [
                {"appName": "no bundle id"},
                {"bundleID": "com.apple.iWork.Keynote",
                 "action": {"kind": "pressReturn", "argument": ""}}
             ]}
        ]}
        """.utf8)
        let decoded = try JSONDecoder().decode(TrainedGestureSettings.self, from: json)
        let gesture = try XCTUnwrap(decoded.gestures.first)
        XCTAssertEqual(gesture.overrides.count, 1)
        XCTAssertEqual(gesture.overrides.first?.bundleID, "com.apple.iWork.Keynote")
        XCTAssertEqual(gesture.overrides.first?.appName, "com.apple.iWork.Keynote",
                       "a missing display name falls back to the bundle ID")
        XCTAssertEqual(gesture.resolvedAction(frontmostBundleID: "com.apple.iWork.Keynote")?.kind,
                       .pressReturn)
        XCTAssertNil(gesture.resolvedAction(frontmostBundleID: nil))
    }

    func testTrainedDetectorWatchesAppGatedGestures() {
        var settings = TrainedGestureSettings()
        settings.gestures = [
            TrainedGesture(name: "Gated", handCount: 1, template: [[0.1, 0.2]],
                           duration: 0.5, baseThreshold: 0.1, overrides: [keynote]),
            TrainedGesture(name: "Inert", handCount: 1, template: [[0.1, 0.2]],
                           duration: 0.5, baseThreshold: 0.1),
        ]
        let config = settings.detectorConfig(enabled: true)
        XCTAssertEqual(config.gestures.count, 1, "gated is watched, inert is not")
        XCTAssertEqual(config.gestures.first?.id, settings.gestures[0].id)
    }
}
