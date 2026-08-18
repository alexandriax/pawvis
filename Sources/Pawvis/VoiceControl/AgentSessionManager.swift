import Combine
import Foundation
import PawvisCore

/// One agent CLI run, as the UI sees it: what was asked, what the process
/// has printed so far, and how it ended. Value snapshots — the manager
/// republishes the array on every change, so SwiftUI views stay live without
/// nested observation.
struct AgentSessionSnapshot: Identifiable, Equatable {
    enum Phase: Equatable {
        case running
        case finished(success: Bool, message: String)

        var isRunning: Bool { self == .running }
    }

    let id: UUID
    let tool: AgentCLIExecutor.Tool
    let instruction: String
    let startedAt: Date
    var tail: [String] = []
    var phase: Phase = .running
}

/// Launches and tracks background agent CLI runs (Claude Code / Codex).
///
/// Every run streams: stdout/stderr are read incrementally (never a blocking
/// read-to-end — a grandchild holding the pipe open must not be able to hang
/// the app or swallow the outcome), the last lines feed the corner activity
/// panel and the Settings list live, and a run can be cancelled from either.
/// `run` always resolves — normal exit, timeout (SIGTERM, then SIGKILL if
/// ignored), launch failure, or user cancel — so the caller can always flash
/// an outcome.
///
/// Every CLI runs as the leader of its own process group
/// (`GroupLeaderProcess`), and cancellation signals the group: the agents run
/// with permission prompts bypassed, so "cancel" has to take down the shell
/// commands the agent already spawned, not just the CLI that spawned them.
/// For the same reason, quitting Pawvis funnels through `shutdownOnAppQuit()`
/// — no run may keep working headless after its cancel UI is gone.
@MainActor
final class AgentSessionManager: ObservableObject {
    static let shared = AgentSessionManager()

    @Published private(set) var sessions: [AgentSessionSnapshot] = []

    var runningCount: Int { sessions.filter { $0.phase.isRunning }.count }

    /// Streamed lines kept per session for the panel.
    private static let tailLines = 8
    /// Cap on collected output text (verdict parsing needs the end anyway).
    private static let maxCollectedBytes = 262_144
    /// Grace between SIGTERM and SIGKILL for a process that ignores the first.
    private static let killGraceSeconds: TimeInterval = 3
    /// At app quit there is no run loop left for the 3s escalation, so quit
    /// waits at most this long for SIGTERM to land before SIGKILLing groups.
    private static let quitGraceSeconds: TimeInterval = 0.5
    /// How long a finished session stays visible before being cleared.
    private static let lingerSeconds: TimeInterval = 4

    private final class Run {
        let id = UUID()
        let tool: AgentCLIExecutor.Tool
        let process = GroupLeaderProcess()
        var stdoutRemnant = Data()
        var stderrRemnant = Data()
        var collectedText = ""
        var resultText: String?
        var resultIsError: Bool?
        var continuation: CheckedContinuation<ExecutionOutcome, Never>?
        var timeoutItem: DispatchWorkItem?
        var killItem: DispatchWorkItem?
        var cancelled = false
        var timedOut = false
        var timeoutSeconds = 0

        init(tool: AgentCLIExecutor.Tool) {
            self.tool = tool
        }
    }

    private var runs: [UUID: Run] = [:]
    private let overlay = AgentActivityOverlay()

    var showInScreenCapture = false {
        didSet { overlay.showInScreenCapture = showInScreenCapture }
    }

    private init() {
        overlay.bind(to: self)
    }

    // MARK: - API

    /// Run the instruction through the agent in the background and report a
    /// flash-ready outcome. Never throws and always resolves; failures come
    /// back as `.failed`.
    func run(instruction: String, tool: AgentCLIExecutor.Tool,
             timeout: TimeInterval) async -> ExecutionOutcome {
        guard let binary = AgentCLIExecutor.binaryPath(for: tool) else {
            return .failed("\(tool.displayName) isn't installed")
        }

        let run = Run(tool: tool)
        run.timeoutSeconds = Int(max(30, timeout))
        runs[run.id] = run
        sessions.append(AgentSessionSnapshot(
            id: run.id, tool: tool, instruction: instruction, startedAt: Date()))
        // The hand-off is happening: this is the moment the instruction
        // leaves the Mac, so it is the moment the audit log records it.
        AgentAuditLog.shared.recordSent(id: run.id, tool: tool, instruction: instruction)

        let process = run.process
        process.executablePath = binary
        process.arguments = tool.arguments(prompt: AgentCLIExecutor.prompt(for: instruction))
        process.currentDirectoryPath = FileManager.default.homeDirectoryForCurrentUser.path
        // GUI apps get a minimal PATH; give the agent a usable one.
        var environment = ProcessInfo.processInfo.environment
        let extra = AgentCLIExecutor.searchDirectories.joined(separator: ":")
        environment["PATH"] = "\(extra):\(environment["PATH"] ?? "/usr/bin:/bin")"
        process.environment = environment

        // stdin is /dev/null inside GroupLeaderProcess.
        let stdout = Pipe()
        let stderr = Pipe()
        process.standardOutput = stdout
        process.standardError = stderr

        installReader(stdout.fileHandleForReading, run: run, isStdout: true)
        installReader(stderr.fileHandleForReading, run: run, isStdout: false)

        let runId = run.id
        process.terminationHandler = { [weak self] _ in
            Task { @MainActor in
                // Small grace so chunks already in flight land before the
                // outcome is computed.
                try? await Task.sleep(for: .milliseconds(300))
                self?.finalize(runId)
            }
        }

        do {
            try process.run()
        } catch {
            Log.voice.error("Agent launch failed (\(tool.rawValue, privacy: .public)): \(error.localizedDescription, privacy: .public)")
            clear(runId, outcome: nil)
            AgentAuditLog.shared.recordOutcome(
                id: runId, tool: tool, success: false,
                outcome: "Couldn't launch \(tool.displayName)")
            return .failed("Couldn't launch \(tool.displayName)")
        }
        Log.voice.log("Agent run started: \(tool.rawValue, privacy: .public) pid \(process.processIdentifier) timeout \(run.timeoutSeconds)s")

        let timeoutItem = DispatchWorkItem { [weak self] in
            guard let self, let run = self.runs[runId],
                  run.process.isRunning else { return }
            run.timedOut = true
            Log.voice.error("Agent run timed out after \(run.timeoutSeconds)s (\(tool.rawValue, privacy: .public) pid \(run.process.processIdentifier))")
            self.terminate(run)
        }
        run.timeoutItem = timeoutItem
        DispatchQueue.main.asyncAfter(
            deadline: .now() + Double(run.timeoutSeconds), execute: timeoutItem)

        return await withCheckedContinuation { continuation in
            run.continuation = continuation
        }
    }

    /// Kill a running session (the panel's ✕ / the Settings Cancel button).
    func cancel(_ id: UUID) {
        guard let run = runs[id], run.process.isRunning else { return }
        run.cancelled = true
        Log.voice.log("Agent run cancelled by user (\(run.tool.rawValue, privacy: .public) pid \(run.process.processIdentifier))")
        terminate(run)
    }

    /// Kill every running session — the spoken brake ("Pawvis, stop").
    /// `cancel(_:)` alone is only reachable from mouse UI, and a voice user
    /// may have neither pointer nor patience mid-run. Returns how many runs
    /// are still alive (already-SIGTERMed ones included, so a repeated
    /// "stop" during the kill grace still reads as braking, not as "nothing
    /// running"); only not-yet-cancelled runs get a new SIGTERM.
    @discardableResult
    func cancelAll() -> Int {
        let alive = runs.values.filter { $0.process.isRunning }
        for run in alive where !run.cancelled {
            cancel(run.id)
        }
        return alive.count
    }

    /// App-quit cleanup. `cancelAll()` alone is not enough here: the SIGKILL
    /// escalation is scheduled on a run loop that dies with the app, and a
    /// permissions-bypassed agent must never keep working unattended after
    /// the app (and its cancel UI) is gone. So: SIGTERM every group now, give
    /// them a short bounded window to exit cleanly, then SIGKILL each group
    /// outright — blocking quit for at most ~`quitGraceSeconds`, never the
    /// full 3s escalation.
    func shutdownOnAppQuit() {
        let running = runs.values.filter { $0.process.isRunning }
        guard !running.isEmpty else { return }
        Log.voice.log("Quitting with \(running.count) agent run(s) live; terminating their process groups")
        cancelAll()
        let deadline = Date().addingTimeInterval(Self.quitGraceSeconds)
        while Date() < deadline, running.contains(where: { $0.process.isRunning }) {
            usleep(50_000) // reapers run on their own threads; main can block
        }
        for run in running {
            // Unconditional sweep: a leader can exit on SIGTERM while a
            // grandchild ignores it. Groups that are fully gone are ESRCH,
            // which signalGroup treats as done.
            run.process.signalGroup(SIGKILL)
        }
    }

    // MARK: - Process plumbing

    /// SIGTERM the whole process group now; SIGKILL the group if anything in
    /// it is still alive after the grace period. Group-wide because the CLI
    /// spawns children of its own (shell commands, node workers): signalling
    /// only the CLI used to leave those running as orphans, finishing
    /// permissions-bypassed work nobody could see or stop. The termination
    /// handler fires either way, which is what finalizes the run.
    private func terminate(_ run: Run) {
        guard run.process.isRunning else { return }
        run.process.signalGroup(SIGTERM)
        let pid = run.process.processIdentifier
        let killItem = DispatchWorkItem { [weak self] in
            guard let self, let run = self.runs[run.id] else { return }
            if run.process.isRunning {
                Log.voice.error("Agent ignored SIGTERM; sending SIGKILL to process group \(pid)")
                run.process.signalGroup(SIGKILL)
            }
        }
        run.killItem = killItem
        DispatchQueue.main.asyncAfter(
            deadline: .now() + Self.killGraceSeconds, execute: killItem)
    }

    private func installReader(_ handle: FileHandle, run: Run, isStdout: Bool) {
        let runId = run.id
        handle.readabilityHandler = { [weak self] handle in
            let data = handle.availableData
            if data.isEmpty {
                handle.readabilityHandler = nil
                return
            }
            Task { @MainActor [weak self] in
                self?.consume(data, runId: runId, isStdout: isStdout)
            }
        }
    }

    private func consume(_ data: Data, runId: UUID, isStdout: Bool) {
        guard let run = runs[runId] else { return }
        var buffer = isStdout ? run.stdoutRemnant : run.stderrRemnant
        buffer.append(data)

        var lines: [String] = []
        while let newline = buffer.firstIndex(of: UInt8(ascii: "\n")) {
            let lineData = buffer[buffer.startIndex..<newline]
            buffer.removeSubrange(buffer.startIndex...newline)
            if let line = String(data: lineData, encoding: .utf8) {
                lines.append(line)
            }
        }
        if isStdout { run.stdoutRemnant = buffer } else { run.stderrRemnant = buffer }
        guard !lines.isEmpty else { return }

        var display: [String] = []
        for line in lines {
            if run.tool == .claude, isStdout {
                let parsed = AgentStreamParser.claudeLine(line)
                display.append(contentsOf: parsed.display)
                if let text = parsed.resultText {
                    run.resultText = text
                    run.resultIsError = parsed.resultIsError
                }
                appendCollected(parsed.display.joined(separator: "\n"), to: run)
            } else {
                let trimmed = line.trimmingCharacters(in: .whitespaces)
                if !trimmed.isEmpty { display.append(trimmed) }
                appendCollected(line, to: run)
            }
        }
        guard !display.isEmpty else { return }

        update(runId) { snapshot in
            snapshot.tail = Array((snapshot.tail + display).suffix(Self.tailLines))
        }
    }

    private func appendCollected(_ text: String, to run: Run) {
        guard !text.isEmpty else { return }
        run.collectedText += text + "\n"
        if run.collectedText.utf8.count > Self.maxCollectedBytes {
            run.collectedText = String(run.collectedText.suffix(Self.maxCollectedBytes / 2))
        }
    }

    // MARK: - Outcome

    private func finalize(_ runId: UUID) {
        guard let run = runs[runId] else { return }
        run.timeoutItem?.cancel()
        run.killItem?.cancel()

        // Flush any unterminated last line.
        for (data, isStdout) in [(run.stdoutRemnant, true), (run.stderrRemnant, false)] where !data.isEmpty {
            consume(Data("\n".utf8), runId: runId, isStdout: isStdout)
        }

        let status = run.process.terminationStatus
        let outcome = outcome(for: run, status: status)
        let kind = if case .done = outcome { "done" } else { "failed" }
        Log.voice.log("Agent run finished (\(run.tool.rawValue, privacy: .public), status \(status)): \(kind, privacy: .public)")
        clear(runId, outcome: outcome)
    }

    private func outcome(for run: Run, status: Int32) -> ExecutionOutcome {
        if run.cancelled {
            return .failed("Cancelled \(run.tool.displayName) run")
        }
        if run.timedOut {
            return .failed("\(run.tool.displayName) timed out after \(run.timeoutSeconds)s")
        }

        // The agent's own DONE:/FAILED: line is the user-facing message; for
        // Claude it lives in the stream's `result` payload, for Codex in the
        // plain output. Fall back to the exit status when the agent didn't
        // follow the format.
        let verdictSource = run.resultText ?? run.collectedText
        switch AgentVerdict.extract(from: verdictSource) {
        case .done(let summary):
            return .done(notice: "✅ \(summary.isEmpty ? "Done" : summary)")
        case .failed(let reason):
            return .failed(reason.isEmpty ? "\(run.tool.displayName) couldn't do it" : reason)
        case .none:
            break
        }
        if run.resultIsError == false, let result = run.resultText,
           !result.trimmingCharacters(in: .whitespaces).isEmpty {
            return .done(notice: "✅ \(String(result.prefix(120)))")
        }
        if status == 0 {
            return .done(notice: "✅ Done (\(run.tool.displayName))")
        }
        let tail = run.collectedText
            .split(separator: "\n", omittingEmptySubsequences: true)
            .suffix(2).joined(separator: " ")
        return .failed(tail.isEmpty
            ? "\(run.tool.displayName) exited with an error"
            : String(tail.prefix(120)))
    }

    /// Resolve the awaiting caller, show the outcome on the session card for
    /// a moment, then drop the session.
    private func clear(_ runId: UUID, outcome: ExecutionOutcome?) {
        guard let run = runs.removeValue(forKey: runId) else { return }
        run.timeoutItem?.cancel()
        run.killItem?.cancel()

        if let outcome {
            switch outcome {
            case .done(let notice):
                AgentAuditLog.shared.recordOutcome(
                    id: runId, tool: run.tool, success: true, outcome: notice ?? "Done")
            case .failed(let message):
                AgentAuditLog.shared.recordOutcome(
                    id: runId, tool: run.tool, success: false, outcome: message)
            }
            update(runId) { snapshot in
                switch outcome {
                case .done(let notice):
                    snapshot.phase = .finished(success: true, message: notice ?? "Done")
                case .failed(let message):
                    snapshot.phase = .finished(success: false, message: message)
                }
            }
            DispatchQueue.main.asyncAfter(deadline: .now() + Self.lingerSeconds) { [weak self] in
                self?.sessions.removeAll { $0.id == runId }
            }
        } else {
            sessions.removeAll { $0.id == runId }
        }

        run.continuation?.resume(returning: outcome ?? .failed("Agent run never started"))
        run.continuation = nil
    }

    private func update(_ id: UUID, _ mutate: (inout AgentSessionSnapshot) -> Void) {
        guard let index = sessions.firstIndex(where: { $0.id == id }) else { return }
        mutate(&sessions[index])
    }
}
