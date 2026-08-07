import AppKit
import Foundation
import PawvisCore
import ServiceManagement

/// The "launch Pawvis at login" registration, backed by `SMAppService.mainApp`
/// (macOS 13+ — no login-item helper bundle, no deprecated
/// `LSSharedFileList`). Decisions live in `LaunchAtLoginPolicy`; this type only
/// reads the real status and performs the action.
@MainActor
final class LoginItemController: ObservableObject {
    /// Set once a real bundle has pushed the preference into macOS, so later
    /// launches can tell "never applied" apart from "the user switched it off
    /// in System Settings".
    private static let defaultAppliedKey = "PawvisLoginItem.defaultApplied"

    @Published private(set) var status: LaunchAtLoginPolicy.SystemStatus
    /// Last register/unregister failure, for the settings pane.
    @Published private(set) var lastError: String?

    private let defaults: UserDefaults

    init(defaults: UserDefaults = .standard) {
        self.defaults = defaults
        status = Self.readStatus()
    }

    /// `SMAppService.mainApp` only means anything for an app bundle with an
    /// identifier — a bare `swift run` binary can't be a login item, and
    /// measured, `register()` on one fails with `SMAppServiceErrorDomain 1`
    /// ("Operation not permitted"). The bundle check is the only reliable way
    /// to tell that apart, because `status` reports `.notFound` either way.
    static var isSupported: Bool {
        Bundle.main.bundleIdentifier != nil && Bundle.main.bundleURL.pathExtension == "app"
    }

    private static func readStatus() -> LaunchAtLoginPolicy.SystemStatus {
        guard isSupported else { return .unavailable }
        switch SMAppService.mainApp.status {
        case .enabled: return .enabled
        case .requiresApproval: return .requiresApproval
        // `.notFound` is what an app that has *never* registered reports;
        // `.notRegistered` is what it reports after an unregister. Both mean
        // "no login item", and treating `.notFound` as unavailable would stop
        // the on-by-default first run from ever registering (measured on
        // macOS 26).
        case .notRegistered, .notFound: return .notRegistered
        @unknown default: return .notRegistered
        }
    }

    func refreshStatus() {
        status = Self.readStatus()
    }

    /// Brings macOS in line with the persisted preference at startup and
    /// returns the value the settings store should keep (which differs from
    /// `desired` when the user turned the login item off in System Settings).
    func reconcileAtLaunch(desired: Bool) -> Bool {
        refreshStatus()
        // A dev run from a bare binary must not burn the first-launch chance,
        // or the installed app would never enable itself.
        guard status != .unavailable else { return desired }

        let action = LaunchAtLoginPolicy.reconcile(
            desired: desired,
            status: status,
            defaultApplied: defaults.bool(forKey: Self.defaultAppliedKey))

        switch action {
        case .register:
            setEnabled(true)
            guard status != .notRegistered else {
                // Registration failed. Leave the first-launch flag unset so the
                // next launch tries again instead of reading a failure as "the
                // user switched it off".
                return desired
            }
        case .unregister:
            setEnabled(false)
        case .adoptDisabled:
            Log.app.info("Login item was removed outside the app — turning the setting off")
        case .doNothing:
            break
        }

        defaults.set(true, forKey: Self.defaultAppliedKey)

        switch action {
        case .register: return true
        case .unregister, .adoptDisabled: return false
        case .doNothing: return desired
        }
    }

    /// Whether the login item is gone *and* we know we once registered it —
    /// i.e. the user removed it in System Settings, and the app's own setting
    /// should follow. Refreshes the status as a side effect.
    func systemHasDisabledIt() -> Bool {
        refreshStatus()
        return status == .notRegistered && defaults.bool(forKey: Self.defaultAppliedKey)
    }

    /// Registers or unregisters the login item. Failures are logged and
    /// surfaced rather than thrown: this is always a side effect of a toggle,
    /// never something the user is blocked on.
    func setEnabled(_ enabled: Bool) {
        guard Self.isSupported else {
            lastError = nil
            refreshStatus()
            return
        }
        do {
            if enabled {
                try SMAppService.mainApp.register()
            } else {
                try SMAppService.mainApp.unregister()
            }
            lastError = nil
            Log.app.info("Login item \(enabled ? "registered" : "unregistered")")
        } catch {
            lastError = error.localizedDescription
            Log.app.error("Login item \(enabled ? "register" : "unregister") failed: \(error.localizedDescription)")
        }
        refreshStatus()
    }

    /// Opens System Settings → General → Login Items, where macOS wants the
    /// user to approve a background item it has flagged.
    func openLoginItemsSettings() {
        guard let url = URL(string: "x-apple.systempreferences:com.apple.LoginItems-Settings.extension") else {
            return
        }
        NSWorkspace.shared.open(url)
    }
}
