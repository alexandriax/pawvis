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
        /// The release's published `.sha256` companion, when present.
        var checksumURL: URL?
    }

    enum State: Equatable {
        case idle
        case checking
        case upToDate
        case available(Release)
        case downloading(Double?)  // 0…1, or nil while the size is still unknown
        case installing
        case readyToRelaunch
        case failed(String)
    }

    @Published private(set) var state: State = .idle
    @Published private(set) var lastChecked: Date?

    /// Called when a *check* turns up a release worth offering — the hook the
    /// system notification hangs off. Deliberately not fired by every
    /// transition into `.available` (a cancelled download returns to that state
    /// too, and re-announcing then would be noise).
    var onUpdateFound: ((Release) -> Void)?

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
                onUpdateFound?(release)
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
        func assetURL(suffix: String) -> URL? {
            assets.compactMap { asset -> URL? in
                guard let name = asset["name"] as? String, name.hasSuffix(suffix),
                      let urlString = asset["browser_download_url"] as? String,
                      let url = URL(string: urlString), url.scheme == "https" else { return nil }
                return url
            }.first
        }
        // `.sha256` also ends in no ".zip", so order matters: check the
        // checksum suffix first and exclude it from the zip match.
        let checksumURL = assetURL(suffix: ".zip.sha256")
        let zipURL = assets.compactMap { asset -> URL? in
            guard let name = asset["name"] as? String,
                  name.hasSuffix(".zip"), !name.hasSuffix(".sha256"),
                  let urlString = asset["browser_download_url"] as? String,
                  let url = URL(string: urlString), url.scheme == "https" else { return nil }
            return url
        }.first

        let pageURLString = json["html_url"] as? String
        let pageURL = pageURLString.flatMap(URL.init)
            ?? URL(string: "https://github.com/alexandriax/pawvis/releases/latest")!

        return Release(
            version: version,
            tag: tag,
            notes: (json["body"] as? String ?? "").trimmingCharacters(in: .whitespacesAndNewlines),
            pageURL: pageURL,
            downloadURL: zipURL,
            checksumURL: checksumURL)
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

    /// Disk writes during download are batched to this size rather than one
    /// syscall per byte; it also sets the granularity at which progress is
    /// reconsidered (see `downloadWithProgress`).
    private static let downloadBufferSize = 1 << 16   // 64 KiB
    /// Progress-update throttling: `state` — a `@Published` property — is
    /// only touched at least every this-much fraction of progress…
    private static let progressStep = 0.02
    /// …or at least this often by wall-clock time, whichever comes first.
    private static let progressInterval: TimeInterval = 0.25

    private func download(release: Release, from url: URL) async {
        // Optimistic immediate feedback; downloadWithProgress refines this
        // to determinate as soon as the response headers are in.
        state = .downloading(nil)
        let tempFile = FileManager.default.temporaryDirectory
            .appendingPathComponent("Pawvis-update-\(UUID().uuidString).zip")
        defer { try? FileManager.default.removeItem(at: tempFile) }
        do {
            try await downloadWithProgress(from: url, to: tempFile)
            if let checksumURL = release.checksumURL {
                try await verifyChecksum(of: tempFile, against: checksumURL)
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

    /// Streams `url` to `destination`, reporting fractional progress through
    /// `state` as bytes arrive — instead of `URLSession.download(from:)`,
    /// whose async form only returns once the whole file is on disk, which is
    /// what left the progress bar stuck at empty.
    ///
    /// `URLResponse.expectedContentLength` is `-1` when the server doesn't
    /// send a `Content-Length` (e.g. chunked transfer encoding); that case is
    /// reported as `.downloading(nil)`, which the UI renders as indeterminate
    /// rather than a bar frozen at some fraction that can never be computed.
    private func downloadWithProgress(from url: URL, to destination: URL) async throws {
        let (bytes, response) = try await URLSession.shared.bytes(from: url)
        if let http = response as? HTTPURLResponse, http.statusCode != 200 {
            throw UpdateError.message("Download failed (HTTP \(http.statusCode))")
        }
        let expectedLength = response.expectedContentLength
        state = expectedLength > 0 ? .downloading(0) : .downloading(nil)

        guard FileManager.default.createFile(atPath: destination.path, contents: nil) else {
            throw UpdateError.message("Could not create a file for the download")
        }
        let handle = try FileHandle(forWritingTo: destination)
        defer { try? handle.close() }

        var diskBuffer = Data()
        diskBuffer.reserveCapacity(Self.downloadBufferSize)
        var received: Int64 = 0
        var lastReportedFraction = 0.0
        var lastReportedAt = Date()

        for try await byte in bytes {
            try Task.checkCancellation()
            diskBuffer.append(byte)
            received += 1
            // Flushing (rather than writing every byte) also sets how often
            // progress is reconsidered below, so `Date()` isn't called on
            // every one of what can be tens of millions of bytes.
            guard diskBuffer.count >= Self.downloadBufferSize else { continue }
            try handle.write(contentsOf: diskBuffer)
            diskBuffer.removeAll(keepingCapacity: true)

            guard expectedLength > 0 else { continue }
            let fraction = min(1, Double(received) / Double(expectedLength))
            let now = Date()
            guard fraction - lastReportedFraction >= Self.progressStep
                || now.timeIntervalSince(lastReportedAt) >= Self.progressInterval else { continue }
            state = .downloading(fraction)
            lastReportedFraction = fraction
            lastReportedAt = now
        }
        if !diskBuffer.isEmpty {
            try handle.write(contentsOf: diskBuffer)
        }
        if expectedLength > 0 {
            state = .downloading(1)
        }
    }

    /// Matches the download against the release's published SHA-256. Belt and
    /// braces alongside the codesign check in SelfUpdater: this catches a
    /// corrupt or swapped asset before anything is unpacked.
    private func verifyChecksum(of file: URL, against checksumURL: URL) async throws {
        let (data, response) = try await URLSession.shared.data(from: checksumURL)
        if let http = response as? HTTPURLResponse, http.statusCode != 200 {
            throw UpdateError.message("Could not fetch the update checksum")
        }
        // `shasum -a 256` output: "<hex>  <filename>"
        guard let expected = String(decoding: data, as: UTF8.self)
            .split(whereSeparator: \.isWhitespace).first.map(String.init)?.lowercased(),
              expected.count == 64 else {
            throw UpdateError.message("The update checksum is unreadable")
        }
        let actual = try SelfUpdater.sha256Hex(of: file)
        guard actual == expected else {
            Log.app.error("Update checksum mismatch")
            throw UpdateError.message("The download didn't match its checksum — update cancelled")
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
