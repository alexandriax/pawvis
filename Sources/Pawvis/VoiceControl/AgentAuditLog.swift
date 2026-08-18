import AppKit
import Foundation

/// Persistent local record of agent hand-offs, as JSON lines in
/// `~/Library/Application Support/Pawvis/agent-log.jsonl`: one `sent` line
/// when an instruction is actually handed to a CLI, one `outcome` line when
/// the run ends, tied together by a shared id. Append-only — an outcome
/// never rewrites its sent line, so a crash mid-run leaves an honest record
/// of what was sent with no outcome.
///
/// The instruction is sensitive (it is whatever the user said), so the file
/// is readable by the user only (0600, re-pinned on every write) and none of
/// its content ever reaches os_log — failures of the log itself are logged
/// without the entry.
///
/// Growth is capped: past ~1 MB the file rotates to `agent-log.1.jsonl`
/// (replacing the previous rotation), so the log holds the recent history
/// plus one file of older history and never more.
@MainActor
final class AgentAuditLog {
    static let shared = AgentAuditLog()

    /// One JSON line. `instruction` is set on `sent` lines; `success` and
    /// `outcome` on `outcome` lines.
    private struct Entry: Codable {
        var kind: String
        var id: String
        var at: String
        var tool: String
        var instruction: String?
        var success: Bool?
        var outcome: String?
    }

    /// Rotate once the current file grows past this.
    private static let rotateAtBytes = 1_048_576

    private let directoryURL: URL
    var fileURL: URL { directoryURL.appendingPathComponent("agent-log.jsonl") }
    private var rotatedURL: URL { directoryURL.appendingPathComponent("agent-log.1.jsonl") }

    init(directory: URL? = nil) {
        directoryURL = directory ?? FileManager.default
            .urls(for: .applicationSupportDirectory, in: .userDomainMask)[0]
            .appendingPathComponent("Pawvis", isDirectory: true)
    }

    // MARK: - API

    /// The instruction is being handed to the CLI right now.
    func recordSent(id: UUID, tool: AgentCLIExecutor.Tool, instruction: String) {
        append(Entry(kind: "sent", id: id.uuidString, at: Self.timestamp(),
                     tool: tool.rawValue, instruction: instruction))
    }

    /// The run ended — success, failure, timeout, cancel, or launch failure.
    /// `outcome` is the same line the user sees flash in the capsule.
    func recordOutcome(id: UUID, tool: AgentCLIExecutor.Tool, success: Bool, outcome: String) {
        append(Entry(kind: "outcome", id: id.uuidString, at: Self.timestamp(),
                     tool: tool.rawValue, success: success, outcome: outcome))
    }

    /// Show the log in Finder (Settings → Voice → "Open agent log"). An
    /// empty file is created first so there is always something to select.
    func revealInFinder() {
        try? ensureFile()
        NSWorkspace.shared.activateFileViewerSelecting([fileURL])
    }

    // MARK: - File plumbing

    private func append(_ entry: Entry) {
        do {
            let encoder = JSONEncoder()
            encoder.outputFormatting = [.sortedKeys, .withoutEscapingSlashes]
            var line = try encoder.encode(entry)
            line.append(UInt8(ascii: "\n"))
            try ensureFile()
            rotateIfNeeded()
            let handle = try FileHandle(forWritingTo: fileURL)
            defer { try? handle.close() }
            try handle.seekToEnd()
            try handle.write(contentsOf: line)
        } catch {
            // The log must never take the hand-off down, and the failure
            // message must never carry the entry's content.
            Log.voice.error("Agent audit log write failed: \(error.localizedDescription, privacy: .public)")
        }
    }

    private func ensureFile() throws {
        let fm = FileManager.default
        if !fm.fileExists(atPath: directoryURL.path) {
            try fm.createDirectory(
                at: directoryURL, withIntermediateDirectories: true,
                attributes: [.posixPermissions: 0o700])
        }
        if !fm.fileExists(atPath: fileURL.path) {
            fm.createFile(atPath: fileURL.path, contents: Data(),
                          attributes: [.posixPermissions: 0o600])
        } else {
            // Re-pin on every write: the instruction stays user-only even if
            // something else loosened the file.
            try? fm.setAttributes([.posixPermissions: 0o600], ofItemAtPath: fileURL.path)
        }
    }

    private func rotateIfNeeded() {
        let fm = FileManager.default
        guard let size = (try? fm.attributesOfItem(atPath: fileURL.path))?[.size] as? Int,
              size >= Self.rotateAtBytes else { return }
        try? fm.removeItem(at: rotatedURL)
        try? fm.moveItem(at: fileURL, to: rotatedURL)
        fm.createFile(atPath: fileURL.path, contents: Data(),
                      attributes: [.posixPermissions: 0o600])
    }

    private static func timestamp() -> String {
        ISO8601DateFormatter().string(from: Date())
    }
}
