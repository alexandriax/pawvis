import Foundation

/// Runs free-form voice commands through an installed agent CLI (Claude Code
/// or Codex) instead of the built-in visual resolver — opt-in, because the
/// agent runs headless with ALL permission checks bypassed and can execute
/// arbitrary shell commands on the user's behalf.
///
/// The agent is asked to end its reply with a `DONE:`/`FAILED:` line, which
/// becomes the flash message in the transcript capsule.
@MainActor
final class AgentCLIExecutor {
    enum Tool: String {
        case claude
        case codex

        var displayName: String {
            switch self {
            case .claude: return "Claude Code"
            case .codex: return "Codex CLI"
            }
        }

        var binaryName: String { rawValue }

        /// Headless, auto-approved invocation. Verified live for Claude Code
        /// (v2.1.216): `claude -p <prompt> --dangerously-skip-permissions`.
        /// Codex: `codex exec` with its own bypass flag; --skip-git-repo-check
        /// because the working directory is $HOME, not a repo.
        func arguments(prompt: String) -> [String] {
            switch self {
            case .claude:
                return ["-p", prompt, "--dangerously-skip-permissions"]
            case .codex:
                return ["exec", "--dangerously-bypass-approvals-and-sandbox",
                        "--skip-git-repo-check", prompt]
            }
        }
    }

    /// Where agent CLIs actually live for GUI apps (which don't inherit a
    /// login shell's PATH).
    private static let searchDirectories = [
        NSString("~/.local/bin").expandingTildeInPath,
        "/opt/homebrew/bin",
        "/usr/local/bin",
        NSString("~/bin").expandingTildeInPath,
        "/usr/bin",
    ]

    private static var resolvedPaths: [Tool: String] = [:]

    /// Filesystem path of the tool's binary, or nil if it isn't installed.
    static func binaryPath(for tool: Tool) -> String? {
        if let cached = resolvedPaths[tool] { return cached }
        for directory in searchDirectories {
            let candidate = (directory as NSString).appendingPathComponent(tool.binaryName)
            if FileManager.default.isExecutableFile(atPath: candidate) {
                resolvedPaths[tool] = candidate
                return candidate
            }
        }
        return nil
    }

    private static func prompt(for instruction: String) -> String {
        """
        You are the voice-command agent for Pawvis on this Mac. The user spoke \
        a command; fulfill it now, autonomously, using the simplest direct \
        means available to you (shell commands, `open`, AppleScript via \
        `osascript`, etc.). Do not ask questions.

        Spoken command: "\(instruction)"

        End your reply with exactly one final line:
        DONE: <what you did, under 10 words>
        or
        FAILED: <why, under 10 words>
        """
    }

    /// Run the instruction through the agent in the background and report a
    /// flash-ready outcome. Never throws; failures come back as `.failed`.
    func run(instruction: String, tool: Tool, timeout: TimeInterval) async -> ExecutionOutcome {
        guard let binary = Self.binaryPath(for: tool) else {
            return .failed("\(tool.displayName) isn't installed")
        }
        let arguments = tool.arguments(prompt: Self.prompt(for: instruction))
        let clampedTimeout = max(30, timeout)

        let result: (output: String, status: Int32)
        do {
            result = try await Self.launch(
                binary: binary, arguments: arguments, timeout: clampedTimeout)
        } catch is TimeoutError {
            Log.voice.error("Agent run timed out after \(Int(clampedTimeout))s: \(instruction, privacy: .public)")
            return .failed("\(tool.displayName) timed out")
        } catch {
            Log.voice.error("Agent launch failed: \(error.localizedDescription, privacy: .public)")
            return .failed("Couldn't launch \(tool.displayName)")
        }

        return Self.outcome(from: result.output, status: result.status, tool: tool)
    }

    /// The agent's last DONE:/FAILED: line is the user-facing message; fall
    /// back to the exit status when it didn't follow the format.
    private static func outcome(from output: String, status: Int32, tool: Tool) -> ExecutionOutcome {
        let lines = output
            .split(separator: "\n", omittingEmptySubsequences: true)
            .map { $0.trimmingCharacters(in: .whitespaces) }
        if let verdict = lines.last(where: { $0.hasPrefix("DONE:") || $0.hasPrefix("FAILED:") }) {
            if verdict.hasPrefix("DONE:") {
                let summary = verdict.dropFirst("DONE:".count)
                    .trimmingCharacters(in: .whitespaces)
                return .done(notice: "✅ \(summary.isEmpty ? "Done" : summary)")
            }
            let reason = verdict.dropFirst("FAILED:".count)
                .trimmingCharacters(in: .whitespaces)
            return .failed(reason.isEmpty ? "\(tool.displayName) couldn't do it" : reason)
        }
        if status == 0 {
            return .done(notice: "✅ Done (\(tool.displayName))")
        }
        let tail = lines.suffix(2).joined(separator: " ")
        return .failed(tail.isEmpty ? "\(tool.displayName) exited with an error" : String(tail.prefix(120)))
    }

    private struct TimeoutError: Error {}

    /// Launch off the main actor, collect stdout+stderr, kill on timeout.
    private static func launch(
        binary: String, arguments: [String], timeout: TimeInterval
    ) async throws -> (output: String, status: Int32) {
        try await withThrowingTaskGroup(of: (String, Int32).self) { group in
            let process = Process()
            process.executableURL = URL(fileURLWithPath: binary)
            process.arguments = arguments
            process.currentDirectoryURL = FileManager.default.homeDirectoryForCurrentUser
            // GUI apps get a minimal PATH; give the agent a usable one.
            var environment = ProcessInfo.processInfo.environment
            let extra = searchDirectories.joined(separator: ":")
            environment["PATH"] = "\(extra):\(environment["PATH"] ?? "/usr/bin:/bin")"
            process.environment = environment

            let pipe = Pipe()
            process.standardOutput = pipe
            process.standardError = pipe
            process.standardInput = FileHandle.nullDevice

            group.addTask {
                try process.run()
                // Drain fully before waiting: a full pipe buffer deadlocks
                // the child if we wait first.
                let data = pipe.fileHandleForReading.readDataToEndOfFile()
                process.waitUntilExit()
                return (String(data: data, encoding: .utf8) ?? "", process.terminationStatus)
            }
            group.addTask {
                try await Task.sleep(for: .seconds(timeout))
                throw TimeoutError()
            }

            do {
                guard let first = try await group.next() else {
                    throw TimeoutError()
                }
                group.cancelAll()
                return first
            } catch {
                if process.isRunning { process.terminate() }
                group.cancelAll()
                throw error
            }
        }
    }
}
