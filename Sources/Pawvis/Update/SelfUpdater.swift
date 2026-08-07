import AppKit
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
        let script = """
        #!/bin/bash
        # Wait for Pawvis to exit before replacing its bundle.
        for _ in $(seq 1 100); do
            kill -0 \(ProcessInfo.processInfo.processIdentifier) 2>/dev/null || break
            sleep 0.1
        done
        rm -rf "\(currentBundle.path)"
        /usr/bin/ditto "\(staged.path)" "\(currentBundle.path)" || exit 1
        # Downloads carry a quarantine flag; left in place, Gatekeeper blocks
        # the app we just installed on the user's behalf.
        /usr/bin/xattr -dr com.apple.quarantine "\(currentBundle.path)" 2>/dev/null
        rm -rf "\(staged.deletingLastPathComponent().path)"
        /usr/bin/open "\(currentBundle.path)"
        """
        runDetached(script: script)
    }

    private static func spawnRelaunch(target: URL) {
        let script = """
        #!/bin/bash
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
            process.executableURL = URL(fileURLWithPath: "/bin/bash")
            process.arguments = [scriptURL.path]
            try process.run() // detached: we exit immediately after
        } catch {
            Log.app.error("Relaunch failed: \(error.localizedDescription, privacy: .public)")
        }
    }

    // MARK: - Helpers

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
