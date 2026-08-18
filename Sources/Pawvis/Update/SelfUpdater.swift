import AppKit
import CryptoKit
import Foundation

/// Replaces the running app bundle with a downloaded one.
///
/// A running app can't overwrite itself, so this stages the new bundle
/// alongside the old one and hands the swap to a detached shell script that
/// waits for this process to exit first. Nothing is touched until the download
/// has been unzipped, identified as Pawvis, and verified by `codesign`.
enum SelfUpdater {
    /// Where the verified replacement is waiting, if `install` succeeded.
    private(set) static var stagedBundle: URL?

    /// Where a swap script that had to roll back leaves its breadcrumb. The
    /// process that hit the failure is gone by definition — it quit to let
    /// the script run — so this is how the *next* launch finds out.
    private static var failureMarkerURL: URL {
        let base = FileManager.default.urls(for: .applicationSupportDirectory, in: .userDomainMask).first
            ?? FileManager.default.temporaryDirectory
        return base.appendingPathComponent("Pawvis", isDirectory: true)
            .appendingPathComponent("last-update-failed.txt")
    }

    /// Reads and clears the failure marker, if a swap rolled back since the
    /// last time this ran. One-shot by design: call once at launch and the
    /// message surfaces exactly once, through the ordinary "failed" update
    /// state — there is no separate persisted history of update failures.
    static func consumeFailureMarker() -> String? {
        let url = failureMarkerURL
        guard let data = try? Data(contentsOf: url) else { return nil }
        try? FileManager.default.removeItem(at: url)
        let text = String(decoding: data, as: UTF8.self)
            .trimmingCharacters(in: .whitespacesAndNewlines)
        return text.isEmpty ? nil : text
    }

    static func install(zipAt zipURL: URL) throws {
        let fm = FileManager.default
        let currentBundle = Bundle.main.bundleURL
        guard currentBundle.pathExtension == "app" else {
            throw UpdateError.message("Pawvis isn't running from an app bundle — update manually.")
        }
        // Fail before doing any work if we can't write the destination (e.g.
        // the app lives somewhere requiring admin rights).
        guard fm.isWritableFile(atPath: currentBundle.deletingLastPathComponent().path) else {
            throw UpdateError.message(
                "Can't write to \(currentBundle.deletingLastPathComponent().path) — move Pawvis to your Applications folder and try again.")
        }

        let workDir = fm.temporaryDirectory
            .appendingPathComponent("PawvisUpdate-\(UUID().uuidString)", isDirectory: true)
        try fm.createDirectory(at: workDir, withIntermediateDirectories: true)

        try run("/usr/bin/ditto", ["-x", "-k", zipURL.path, workDir.path],
                failure: "Could not unpack the download")

        guard let newBundle = try findAppBundle(in: workDir, fm: fm) else {
            throw UpdateError.message("The download didn't contain Pawvis.app")
        }
        guard bundleIdentifier(of: newBundle) == Bundle.main.bundleIdentifier else {
            throw UpdateError.message("The download isn't Pawvis")
        }
        // Verifies the bundle's own code seal — catches truncation or tampering
        // in transit. (Ad-hoc signatures verify fine; this is integrity, not
        // trust, which HTTPS to GitHub provides.)
        try run("/usr/bin/codesign", ["--verify", "--deep", newBundle.path],
                failure: "The downloaded app failed signature verification")

        stagedBundle = newBundle
    }

    /// Spawns the swap script. Call immediately before terminating.
    static func relaunchAfterQuit() {
        let currentBundle = Bundle.main.bundleURL
        guard let staged = stagedBundle else {
            // Nothing staged: just come back up as we are.
            spawnRelaunch(target: currentBundle)
            return
        }
        // A sibling of the current bundle, so setting it aside is a rename
        // on the same volume: atomic, and always reversible if ditto fails.
        let backup = currentBundle.deletingLastPathComponent()
            .appendingPathComponent(
                currentBundle.lastPathComponent + ".pawvis-old-\(UUID().uuidString)")
        let marker = failureMarkerURL
        // Transactional swap: the old bundle is moved aside (never deleted)
        // before ditto runs, and only removed once the new copy is confirmed
        // in place. Any failure — the staged copy missing, the move aside
        // failing, or ditto itself failing — leaves the previous app intact
        // and relaunches it, rather than leaving nothing installed at all.
        let script = """
        #!/bin/sh
        # Wait for Pawvis to exit before touching its bundle.
        for _ in $(seq 1 100); do
            kill -0 \(ProcessInfo.processInfo.processIdentifier) 2>/dev/null || break
            sleep 0.1
        done

        current="\(currentBundle.path)"
        staged="\(staged.path)"
        backup="\(backup.path)"
        marker="\(marker.path)"

        # Leaves a marker the next launch reads and reports through the
        # update UI, plus a line on stderr for anyone looking at the script
        # directly — the app that would normally show a live error is, by
        # definition, the one that just failed to come back up.
        fail() {
            mkdir -p "$(dirname "$marker")" 2>/dev/null
            printf '%s\\n' "$1" > "$marker" 2>/dev/null
            echo "Pawvis update: $1" 1>&2
        }

        # The staged copy lives in a temp directory macOS can reap on its own
        # schedule, and "ready to relaunch" can sit for hours before the user
        # clicks it. If it's gone, there's nothing to install — leave the
        # current app untouched and just bring it back.
        if [ ! -d "$staged" ]; then
            fail "The downloaded update was no longer available, so it wasn't installed. Pawvis is unchanged."
            /usr/bin/open "$current"
            exit 1
        fi

        # Move the old bundle aside instead of deleting it. On the same
        # volume this is an atomic rename, so "$current" is either the old
        # app or briefly missing — never a half-deleted mess — and a failed
        # ditto below can always be undone by moving "$backup" straight back.
        if ! mv "$current" "$backup"; then
            fail "The update could not be installed — Pawvis could not be moved aside, so it was left as-is."
            /usr/bin/open "$current"
            exit 1
        fi

        if /usr/bin/ditto "$staged" "$current"; then
            # Downloads carry a quarantine flag; left in place, Gatekeeper
            # blocks the app we just installed on the user's behalf.
            /usr/bin/xattr -dr com.apple.quarantine "$current" 2>/dev/null
            rm -rf "$backup"
            rm -rf "\(staged.deletingLastPathComponent().path)"
            /usr/bin/open "$current"
        else
            fail "The last update failed to copy into place and was rolled back to the previous version."
            rm -rf "$current" 2>/dev/null
            mv "$backup" "$current"
            /usr/bin/open "$current"
            exit 1
        fi
        """
        runDetached(script: script)
    }

    private static func spawnRelaunch(target: URL) {
        let script = """
        #!/bin/sh
        for _ in $(seq 1 100); do
            kill -0 \(ProcessInfo.processInfo.processIdentifier) 2>/dev/null || break
            sleep 0.1
        done
        /usr/bin/open "\(target.path)"
        """
        runDetached(script: script)
    }

    private static func runDetached(script: String) {
        let scriptURL = FileManager.default.temporaryDirectory
            .appendingPathComponent("pawvis-update-\(UUID().uuidString).sh")
        do {
            try script.write(to: scriptURL, atomically: true, encoding: .utf8)
            try FileManager.default.setAttributes(
                [.posixPermissions: 0o755], ofItemAtPath: scriptURL.path)
            let process = Process()
            process.executableURL = URL(fileURLWithPath: "/bin/sh")
            process.arguments = [scriptURL.path]
            try process.run() // detached: we exit immediately after
        } catch {
            Log.app.error("Relaunch failed: \(error.localizedDescription, privacy: .public)")
        }
    }

    // MARK: - Helpers

    /// Streaming SHA-256 so a large download is never held in memory at once.
    static func sha256Hex(of file: URL) throws -> String {
        let handle = try FileHandle(forReadingFrom: file)
        defer { try? handle.close() }
        var hasher = SHA256()
        while let chunk = try handle.read(upToCount: 1 << 20), !chunk.isEmpty {
            hasher.update(data: chunk)
        }
        return hasher.finalize().map { String(format: "%02x", $0) }.joined()
    }

    private static func findAppBundle(in directory: URL, fm: FileManager) throws -> URL? {
        let contents = try fm.contentsOfDirectory(
            at: directory, includingPropertiesForKeys: nil, options: [.skipsHiddenFiles])
        if let direct = contents.first(where: { $0.pathExtension == "app" }) { return direct }
        // Some zips wrap the app in a folder.
        for entry in contents where entry.hasDirectoryPath {
            if let nested = try findAppBundle(in: entry, fm: fm) { return nested }
        }
        return nil
    }

    private static func bundleIdentifier(of bundleURL: URL) -> String? {
        Bundle(url: bundleURL)?.bundleIdentifier
    }

    @discardableResult
    private static func run(_ launchPath: String, _ arguments: [String], failure: String) throws -> String {
        let process = Process()
        process.executableURL = URL(fileURLWithPath: launchPath)
        process.arguments = arguments
        let pipe = Pipe()
        process.standardOutput = pipe
        process.standardError = pipe
        try process.run()
        let data = pipe.fileHandleForReading.readDataToEndOfFile()
        process.waitUntilExit()
        guard process.terminationStatus == 0 else {
            throw UpdateError.message(failure)
        }
        return String(decoding: data, as: UTF8.self)
    }
}
