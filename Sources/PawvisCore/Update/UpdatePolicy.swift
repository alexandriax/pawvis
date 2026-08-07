import Foundation

/// When to check for updates, and whether a discovered release is worth
/// telling the user about. Pure and clock-free (the caller supplies `now`), so
/// every rule here is unit-testable.
public enum UpdatePolicy {
    /// Automatic checks happen at most once a day.
    public static let checkInterval: TimeInterval = 24 * 60 * 60

    /// Whether an automatic (background) check should run now. Manual checks
    /// bypass this entirely.
    public static func shouldAutoCheck(
        lastChecked: Date?,
        now: Date,
        interval: TimeInterval = checkInterval
    ) -> Bool {
        guard let lastChecked else { return true } // never checked
        let elapsed = now.timeIntervalSince(lastChecked)
        // A clock that jumped backwards (timezone/NTP) leaves a future
        // timestamp; treat that as due rather than waiting it out.
        return elapsed >= interval || elapsed < 0
    }

    /// Whether `candidate` should be offered over `current`.
    /// - Pre-releases are only offered to users already running one, so a
    ///   stable install is never nudged onto a beta.
    /// - A version the user explicitly skipped stays hidden until something
    ///   newer than it appears.
    public static func shouldOffer(
        candidate: SemanticVersion,
        current: SemanticVersion,
        skipped: SemanticVersion? = nil
    ) -> Bool {
        guard candidate > current else { return false }
        if candidate.isPrerelease && !current.isPrerelease { return false }
        if let skipped, candidate <= skipped { return false }
        return true
    }
}
