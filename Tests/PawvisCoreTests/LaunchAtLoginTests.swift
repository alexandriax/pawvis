import XCTest
@testable import PawvisCore

final class LaunchAtLoginPolicyTests: XCTestCase {
    private func reconcile(
        _ desired: Bool,
        _ status: LaunchAtLoginPolicy.SystemStatus,
        applied: Bool
    ) -> LaunchAtLoginPolicy.Action {
        LaunchAtLoginPolicy.reconcile(desired: desired, status: status, defaultApplied: applied)
    }

    func testFirstLaunchEnablesByDefault() {
        XCTAssertEqual(reconcile(true, .notRegistered, applied: false), .register)
    }

    func testFirstLaunchWithTheSettingOffRegistersNothing() {
        XCTAssertEqual(reconcile(false, .notRegistered, applied: false), .doNothing)
    }

    func testFirstLaunchWhenAlreadyRegisteredDoesNothing() {
        XCTAssertEqual(reconcile(true, .enabled, applied: false), .doNothing)
    }

    func testSteadyStateAgreementIsLeftAlone() {
        XCTAssertEqual(reconcile(true, .enabled, applied: true), .doNothing)
        XCTAssertEqual(reconcile(false, .notRegistered, applied: true), .doNothing)
    }

    func testTurningTheSettingOffUnregisters() {
        XCTAssertEqual(reconcile(false, .enabled, applied: true), .unregister)
        XCTAssertEqual(reconcile(false, .requiresApproval, applied: true), .unregister)
    }

    /// The important one: after the default has been applied once, a missing
    /// registration means the user removed it in System Settings. Re-adding it
    /// every launch would make the app impossible to switch off.
    func testRemovalInSystemSettingsIsAdoptedNotReversed() {
        XCTAssertEqual(reconcile(true, .notRegistered, applied: true), .adoptDisabled)
    }

    /// Approval is the user's to give; re-registering doesn't grant it, and the
    /// setting stays on so the settings pane can point them at System Settings.
    func testPendingApprovalIsLeftPending() {
        XCTAssertEqual(reconcile(true, .requiresApproval, applied: true), .doNothing)
        XCTAssertEqual(reconcile(true, .requiresApproval, applied: false), .doNothing)
    }

    /// An unbundled binary (`swift run`) can't be a login item — every action
    /// would just throw.
    func testUnavailableNeverActs() {
        for desired in [true, false] {
            for applied in [true, false] {
                XCTAssertEqual(reconcile(desired, .unavailable, applied: applied), .doNothing)
            }
        }
    }
}

final class GeneralConfigLaunchAtLoginTests: XCTestCase {
    func testDefaultsToOn() {
        XCTAssertTrue(GeneralConfig().launchAtLogin)
        XCTAssertTrue(PawvisSettings.default.general.launchAtLogin)
    }

    func testSurvivesRoundTrip() throws {
        var settings = PawvisSettings.default
        settings.general.launchAtLogin = false
        let decoded = try JSONDecoder().decode(
            PawvisSettings.self, from: JSONEncoder().encode(settings))
        XCTAssertFalse(decoded.general.launchAtLogin)
    }

    /// Settings written before this setting existed decode with it on, so
    /// upgrading enables launch at login the same way a fresh install does.
    func testMissingKeyDecodesToOn() throws {
        let json = Data(#"{"general":{"startTrackingOnLaunch":false}}"#.utf8)
        let decoded = try JSONDecoder().decode(PawvisSettings.self, from: json)
        XCTAssertTrue(decoded.general.launchAtLogin)
        XCTAssertFalse(decoded.general.startTrackingOnLaunch)
    }
}
