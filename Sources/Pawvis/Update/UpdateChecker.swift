import AppKit
import Foundation
import PawvisCore

/// Checks GitHub Releases for a newer Pawvis and, on request, installs it in
/// place and relaunches.
///
/// Automatic checks run at most once every 24 hours (`UpdatePolicy`); manual
/// checks always run. All the decision logic — is a check due, is a release
/// worth offering, how do two versions compare — lives in PawvisCore where it
/// is unit-tested; this type owns only I/O and UI state.
@MainActor
final class UpdateChecker: ObservableObject {

    struct Release: Equatable {
        var version: SemanticVersion
        var tag: String
        var notes: String
        var pageURL: URL
        var downloadURL: URL?
    }

    enum State: Equatable {
        case idle
        case checking
        case upToDate
        case available(Release)
        case downloading(Double)   // 0…1
        case installing
        case readyToRelaunch
        case failed(String)
    }

    @Published private(set) var state: State = .idle
    @Published private(set) var lastChecked: Date?

    /// True when an update is waiting — drives the menu bar badge.
    var updateAvailable: Bool {
        if case .available = state { return true }
        return false
    }

    private enum Key {
        static let lastChecked = "Pawvis.update.lastChecked"
        static let skippedVersion = "Pawvis.update.skippedVersion"
        static let automaticChecks = "Pawvis.update.automaticChecks"
    }

    private static let releasesURL = URL(
        string: "https://api.github.com/repos/alexandriax/pawvis/releases/latest")!

    private let defaults = UserDefaults.standard
    private var downloadTask: Task<Void, Never>?

    var automaticChecksEnabled: Bool {
        get { defaults.object(forKey: Key.automaticChecks) as? Bool ?? true }
        set {
            defaults.set(newValue, forKey: Key.automaticChecks)
            objectWillChange.send()
        }
    }

    init() {
        lastChecked = defaults.object(forKey: Key.lastChecked) as? Date
    }

    // MARK: - Checking

    /// Called at launch: checks only if enabled and a day has passed.
    func checkIfDue() {
        guard automaticChecksEnabled,
              UpdatePolicy.shouldAutoCheck(lastChecked: lastChecked, now: Date()) else { return }
        Task { await check(manual: false) }
    }

    func checkNow() {
        Task { await check(manual: true) }
    }

    private func check(manual: Bool) async {
        if case .downloading = state { return }
        if case .installing = state { return }
        state = .checking
        do {
            let release = try await fetchLatest()
            let now = Date()
            lastChecked = now
            defaults.set(now, forKey: Key.lastChecked)

            // A manual check ignores a previous "skip", so the user can always
            // get back to a version they dismissed.
            let skipped = manual ? nil : skippedVersion
            if UpdatePolicy.shouldOffer(
                candidate: release.version, current: AppVersion.semantic, skipped: skipped) {
                state = .available(release)
            } else {
                state = .upToDate
            }
        } catch {
            Log.app.error("Update check failed: \(error.localizedDescription, privacy: .public)")
            // A silent background failure shouldn't nag; a manual one should.
            state = manual ? .failed(error.localizedDescription) : .idle
        }
    }

    private var skippedVersion: SemanticVersion? {
        (defaults.string(forKey: Key.skippedVersion)).flatMap(SemanticVersion.init)
    }

    func skipCurrentOffer() {
        guard case .available(let release) = state else { return }
        defaults.set(release.version.description, forKey: Key.skippedVersion)
        state = .idle
    }

    private func fetchLatest() async throws -> Release {
        var request = URLRequest(url: Self.releasesURL)
        request.setValue("application/vnd.github+json", forHTTPHeaderField: "Accept")
        request.setValue("Pawvis/\(AppVersion.current)", forHTTPHeaderField: "User-Agent")
        request.timeoutInterval = 20

        let (data, response) = try await URLSession.shared.data(for: request)
        guard let http = response as? HTTPURLResponse else {
            throw UpdateError.message("No response from GitHub")
        }
        guard http.statusCode == 200 else {
            throw UpdateError.message("GitHub returned \(http.statusCode)")
        }
        guard let json = try JSONSerialization.jsonObject(with: data) as? [String: Any],
              let tag = json["tag_name"] as? String,
              let version = SemanticVersion(tag) else {
            throw UpdateError.message("Could not read the latest release")
        }

        let assets = json["assets"] as? [[String: Any]] ?? []
        let zipURL = assets
            .compactMap { asset -> URL? in
                guard let name = asset["name"] as? String, name.hasSuffix(".zip"),
                      let urlString = asset["browser_download_url"] as? String,
                      let url = URL(string: urlString), url.scheme == "https" else { return nil }
                return url
            }
            .first

        let pageURLString = json["html_url"] as? String
        let pageURL = pageURLString.flatMap(URL.init)
            ?? URL(string: "https://github.com/alexandriax/pawvis/releases/latest")!

        return Release(
            version: version,
            tag: tag,
            notes: (json["body"] as? String ?? "").trimmingCharacters(in: .whitespacesAndNewlines),
            pageURL: pageURL,
            downloadURL: zipURL)
    }

    // MARK: - Installing

    func installAvailableUpdate() {
        guard case .available(let release) = state else { return }
        guard let downloadURL = release.downloadURL else {
            // No attached zip (source-only release): hand off to the browser.
            NSWorkspace.shared.open(release.pageURL)
            return
        }
        downloadTask?.cancel()
        downloadTask = Task { await download(release: release, from: downloadURL) }
    }

    private func download(release: Release, from url: URL) async {
        state = .downloading(0)
        do {
            let (tempFile, response) = try await URLSession.shared.download(from: url)
            if let http = response as? HTTPURLResponse, http.statusCode != 200 {
                throw UpdateError.message("Download failed (HTTP \(http.statusCode))")
            }
            state = .installing
            try await Task.detached(priority: .userInitiated) {
                try SelfUpdater.install(zipAt: tempFile)
            }.value
            state = .readyToRelaunch
        } catch is CancellationError {
            state = .available(release)
        } catch {
            Log.app.error("Update install failed: \(error.localizedDescription, privacy: .public)")
            state = .failed(error.localizedDescription)
        }
    }

    func relaunchNow() {
        SelfUpdater.relaunchAfterQuit()
        NSApp.terminate(nil)
    }
}

enum UpdateError: LocalizedError {
    case message(String)

    var errorDescription: String? {
        switch self {
        case .message(let text): return text
        }
    }
}
