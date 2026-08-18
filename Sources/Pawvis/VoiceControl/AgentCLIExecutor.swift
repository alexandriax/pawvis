import Foundation

/// The installed agent CLIs voice commands can be handed to (Claude Code or
/// Codex), and how to invoke them — opt-in, because the agent runs headless
/// with ALL permission checks bypassed and can execute arbitrary shell
/// commands on the user's behalf.
///
/// The processes themselves are launched and tracked by
/// `AgentSessionManager`, which streams their output to the live activity
/// panel and the Settings list. The agent is asked to end its reply with a
/// `DONE:`/`FAILED:` line, which becomes the flash message in the transcript
/// capsule.
@MainActor
enum AgentCLIExecutor {
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
        /// (v2.1.216): `claude -p <prompt> --dangerously-skip-permissions`,
        /// with `--output-format stream-json --verbose` so the run streams
        /// one JSON object per line (assistant turns as they complete, then
        /// the result) instead of staying dark until the end. Codex:
        /// `codex exec` with its own bypass flag, which already streams
        /// progress lines; --skip-git-repo-check because the working
        /// directory is $HOME, not a repo.
        func arguments(prompt: String) -> [String] {
            switch self {
            case .claude:
                return ["-p", prompt, "--dangerously-skip-permissions",
                        "--output-format", "stream-json", "--verbose"]
            case .codex:
                return ["exec", "--dangerously-bypass-approvals-and-sandbox",
                        "--skip-git-repo-check", prompt]
            }
        }
    }

    /// Where agent CLIs actually live for GUI apps (which don't inherit a
    /// login shell's PATH).
    static let searchDirectories = [
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

    static func prompt(for instruction: String) -> String {
        """
        You are the voice-command agent for Pawvis on this Mac, running \
        headless with permission checks disabled. The user spoke a command; \
        act now, autonomously, and do not ask questions.

        Perform the following action using computer use: "\(instruction)"

        Drive the Mac directly — use your computer-use tools (screenshot, \
        click, type) when you have them; otherwise fall back to shell \
        commands, `open`, or AppleScript via `osascript`. The text comes \
        from speech recognition, so read it charitably. But never guess: if \
        the request is ambiguous, garbled, or would be destructive or \
        irreversible, do NOT act on it. Decline instead, with a FAILED: line \
        that says what you heard and why you declined.

        End your reply with exactly one final line:
        DONE: <what you did, under 10 words>
        or
        FAILED: <why, under 10 words>
        """
    }
}
