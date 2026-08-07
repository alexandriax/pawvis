import AppKit
import Foundation
import PawvisCore
import UserNotifications

/// The system notification that announces a waiting update — the banner in the
/// top-right corner, with a button that opens Settings → About, where the
/// install and the release notes already live.
///
/// Two deliberate restraints:
///
/// - **Once per version** (`UpdatePolicy.shouldNotify`). Every launch re-offers
///   the same release for as long as the user hasn't taken it; re-posting the
///   banner each time would turn a useful nudge into nagging. The menu bar item
///   keeps carrying the offer in the meantime.
/// - **Authorization is asked for lazily**, the first time there is genuinely
///   something to say. Asking at launch would put a permission prompt in front
///   of every user on day one, including the ones already up to date.
@MainActor
final class UpdateNotifier: NSObject {

    /// Matched by string in the delegate callback, so these must stay stable
    /// across versions: a banner posted by the old build is very often clicked
    /// *after* the new one is running.
    private enum ID {
        static let category = "com.pawvis.update"
        static let install = "com.pawvis.update.install"
        /// Fixed, so a second post replaces the first rather than stacking.
        static let request = "com.pawvis.update.available"
    }

    private static let lastNotifiedKey = "Pawvis.update.lastNotifiedVersion"

    /// `UNUserNotificationCenter.current()` is only legal inside a real app
    /// bundle: from a bare `swift run` binary it traps on a nil bundle proxy,
    /// which would take `--selftest` down with it. Same gate as `LoginItem`,
    /// for the same reason.
    static var isSupported: Bool {
        Bundle.main.bundleIdentifier != nil && Bundle.main.bundleURL.pathExtension == "app"
    }

    /// Whether the user has explicitly turned Pawvis's notifications off, which
    /// the About tab says out loud — otherwise the banner just never arrives and
    /// there is nothing anywhere to explain why. `.notDetermined` is not
    /// blocked: nobody has been asked yet.
    static func isBlocked() async -> Bool {
        guard isSupported else { return false }
        return await UNUserNotificationCenter.current()
            .notificationSettings().authorizationStatus == .denied
    }

    private let defaults: UserDefaults
    private let showUpdateUI: () -> Void

    init(defaults: UserDefaults = .standard, showUpdateUI: @escaping () -> Void) {
        self.defaults = defaults
        self.showUpdateUI = showUpdateUI
        super.init()
    }

    /// Installs the delegate and the notification category. Must run inside
    /// `applicationDidFinishLaunching` — a delegate set after it returns misses
    /// the launch-time delivery of a banner the user clicked while the app was
    /// not running.
    func start() {
        guard Self.isSupported else { return }
        let center = UNUserNotificationCenter.current()
        center.delegate = self
        center.setNotificationCategories([
            UNNotificationCategory(
                identifier: ID.category,
                actions: [
                    UNNotificationAction(
                        identifier: ID.install,
                        title: "Install…",
                        options: [.foreground])
                ],
                intentIdentifiers: [],
                options: [])
        ])
    }

    /// Announces `release`, unless this version has already had its banner.
    func announce(_ release: UpdateChecker.Release) {
        guard Self.isSupported,
              UpdatePolicy.shouldNotify(candidate: release.version, lastNotified: lastNotified)
        else { return }
        Task { await deliver(release) }
    }

    private func deliver(_ release: UpdateChecker.Release) async {
        let center = UNUserNotificationCenter.current()
        guard await authorized(center) else { return }

        let content = UNMutableNotificationContent()
        content.title = "Pawvis \(release.version) is available"
        content.body = Self.body(for: release)
        content.categoryIdentifier = ID.category

        do {
            // nil trigger: deliver now.
            try await center.add(UNNotificationRequest(
                identifier: ID.request, content: content, trigger: nil))
            // Only after it actually went out — a failed post that marked the
            // version as announced would silently swallow it forever.
            lastNotified = release.version
            Log.app.info("Posted update notification for \(release.version.description, privacy: .public)")
        } catch {
            Log.app.error("Update notification failed: \(error.localizedDescription, privacy: .public)")
        }
    }

    /// Resolves permission, prompting once if macOS has never asked. A denial
    /// is *not* recorded as "announced": if the user later allows notifications,
    /// this version should still get its banner.
    private func authorized(_ center: UNUserNotificationCenter) async -> Bool {
        let status = await center.notificationSettings().authorizationStatus
        switch status {
        case .notDetermined:
            do {
                // Alert only, no sound: an update is worth a banner, not a chime.
                return try await center.requestAuthorization(options: [.alert])
            } catch {
                Log.app.error("Notification authorization failed: \(error.localizedDescription, privacy: .public)")
                return false
            }
        case .denied:
            Log.app.info("Update notification suppressed — notifications are off for Pawvis")
            return false
        default:
            return true
        }
    }

    /// The release's first non-empty line of notes, trimmed of Markdown
    /// scaffolding, or a plain fallback. Notes are arbitrary user-authored
    /// Markdown, so anything longer reads as noise in a banner.
    private static func body(for release: UpdateChecker.Release) -> String {
        let headline = release.notes
            .split(whereSeparator: \.isNewline)
            .lazy
            .map { $0.trimmingCharacters(in: CharacterSet(charactersIn: "#*-> \t")) }
            .first { !$0.isEmpty }
        if let headline, headline.count <= 120 {
            return headline
        }
        return "You're on \(AppVersion.current). Install it from Settings → About."
    }

    private var lastNotified: SemanticVersion? {
        get { defaults.string(forKey: Self.lastNotifiedKey).flatMap(SemanticVersion.init) }
        set { defaults.set(newValue?.description, forKey: Self.lastNotifiedKey) }
    }
}

extension UpdateNotifier: UNUserNotificationCenterDelegate {

    /// Show the banner even when Pawvis is frontmost — with the Settings window
    /// open, the default would be to swallow it silently.
    nonisolated func userNotificationCenter(
        _ center: UNUserNotificationCenter,
        willPresent notification: UNNotification,
        withCompletionHandler completionHandler: @escaping (UNNotificationPresentationOptions) -> Void
    ) {
        completionHandler([.banner, .list])
    }

    /// The button — and a click on the banner body — both land here.
    nonisolated func userNotificationCenter(
        _ center: UNUserNotificationCenter,
        didReceive response: UNNotificationResponse,
        withCompletionHandler completionHandler: @escaping () -> Void
    ) {
        let action = response.actionIdentifier
        guard action == ID.install || action == UNNotificationDefaultActionIdentifier else {
            completionHandler()
            return
        }
        Task { @MainActor in
            self.showUpdateUI()
            completionHandler()
        }
    }
}
