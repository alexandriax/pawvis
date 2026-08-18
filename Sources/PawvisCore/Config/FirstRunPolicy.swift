import Foundation

/// Decides what the first-run flag means for this launch. Pure, like
/// `LaunchAtLoginPolicy`: the caller reads the real camera status and the
/// UserDefaults flag, and performs whatever the verdict says.
///
/// The flag itself (`Pawvis.firstRunCompleted`, see `FirstRun` in the app
/// target) lives in its own UserDefaults key rather than inside the settings
/// JSON, same pattern and same reason as `PawvisLoginItem.defaultApplied`:
/// it records that a launch-time step already happened, so it must survive a
/// settings reset and never travel with an exported settings blob.
public enum FirstRunPolicy {
    public enum Verdict: Equatable, Sendable {
        /// A genuinely new install: show the welcome window and hold
        /// auto-start until its own Start button (the tour is what asks for
        /// the camera, in context, instead of a cold permission dialog).
        case showWelcome
        /// An install that predates onboarding — the camera is already
        /// granted, so the tour would only be in the way. Record completion
        /// and launch exactly as every build before the tour did.
        case adoptCompleted
        /// Every launch after the first: nothing to do.
        case proceedNormally
    }

    /// - Parameters:
    ///   - completed: the persisted first-run flag.
    ///   - cameraGranted: whether camera permission is already granted at
    ///     launch — the mark of an install that was in use before onboarding
    ///     existed (or of a user who granted the camera and closed the tour;
    ///     either way, setup is behind them).
    ///   - automated: `PAWVIS_NO_AUTOSTART` runs. They must stay headless —
    ///     no welcome window — and must not burn the flag for a later real
    ///     launch.
    public static func verdict(
        completed: Bool,
        cameraGranted: Bool,
        automated: Bool
    ) -> Verdict {
        if automated || completed { return .proceedNormally }
        return cameraGranted ? .adoptCompleted : .showWelcome
    }
}
