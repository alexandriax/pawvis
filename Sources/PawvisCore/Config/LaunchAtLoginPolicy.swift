import Foundation

/// Reconciles the persisted "launch at login" preference with what macOS
/// actually has registered. Pure and framework-free (the caller reads the real
/// `SMAppService` status and performs the action), so every rule is testable.
///
/// The hard part is that there are *two* places this preference lives: our
/// settings file and System Settings → General → Login Items. Whoever changed
/// it last should win, and the app must never quietly undo a choice the user
/// made in System Settings — which is exactly what re-registering on every
/// launch would do.
public enum LaunchAtLoginPolicy {
    /// What macOS reports for the login-item registration.
    public enum SystemStatus: Equatable, Sendable {
        /// No login item — whether it was never registered or was removed.
        case notRegistered
        case enabled
        /// Registered, but the user has to switch it on in System Settings.
        case requiresApproval
        /// No registration is possible: the app isn't running from a bundle
        /// (`swift run`), so every register call would fail outright.
        case unavailable
    }

    public enum Action: Equatable, Sendable {
        case doNothing
        case register
        case unregister
        /// The user turned the login item off outside the app; mirror that into
        /// our settings instead of fighting them for it.
        case adoptDisabled
    }

    /// - Parameters:
    ///   - desired: the persisted preference (defaults to on for new installs).
    ///   - status: what macOS currently reports.
    ///   - defaultApplied: whether a previous launch already pushed the
    ///     preference into macOS at least once. Before that, `desired` is just
    ///     our default and we act on it; afterwards, a disagreement means the
    ///     user changed something in System Settings.
    public static func reconcile(
        desired: Bool,
        status: SystemStatus,
        defaultApplied: Bool
    ) -> Action {
        // Nothing to register against, so any action would just throw.
        guard status != .unavailable else { return .doNothing }

        guard defaultApplied else {
            // First launch from a real bundle: enable by default.
            return desired && status == .notRegistered ? .register : .doNothing
        }

        switch (desired, status) {
        case (true, .notRegistered):
            // We registered before and it's gone: the user removed it in
            // System Settings (or moved the app). Follow their lead.
            return .adoptDisabled
        // Approval is the user's to give; re-registering doesn't grant it and
        // the settings pane tells them where to go.
        case (true, .requiresApproval), (true, .enabled):
            return .doNothing
        case (false, .enabled), (false, .requiresApproval):
            return .unregister
        case (false, .notRegistered):
            return .doNothing
        case (_, .unavailable):
            return .doNothing
        }
    }
}
