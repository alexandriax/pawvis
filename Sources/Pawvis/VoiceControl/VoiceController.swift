import Foundation
import PawvisCore

/// Orchestrates voice control (beta): the on-device speech engine feeds the
/// wake-word parser; recognized commands run through the executor, and
/// free-form ones go to the on-device autopilot loop (or the opt-in agent
/// CLI). Speech without the wake word is ignored entirely — but a bare wake
/// word opens a short capture window, because the speech engine's fast
/// segmentation routinely splits "Pawvis … open Safari" into two finals
/// (the original beta dropped both halves of that silently).
@MainActor
final class VoiceController: ObservableObject {
    enum State: Equatable {
        case off
        case connecting
        case listening   // armed; every command starts with the wake word
        case resolving   // the autopilot is taking its first look
        case working(String)  // mid-run: the latest completed step
        case error(String)

        var isActive: Bool {
            switch self {
            case .off, .error: return false
            default: return true
            }
        }
    }

    @Published private(set) var state: State = .off
    /// Transient confirmation ("Opening Safari"), auto-cleared.
    @Published private(set) var notice: String?

    private let parser = VoiceControlParser()
    private let typer = TextTyper()
    private let executor = CommandExecutor()
    private let agentSessions = AgentSessionManager.shared
    /// The top-of-screen capsule showing what's being heard.
    let transcriptOverlay = TranscriptOverlay()
    /// The bottom-right card streaming autopilot steps, with Cancel.
    let autopilotPanel = AutopilotPanel()
    /// The running autopilot loop, if any — cancelled by "Pawvis stop", by
    /// any new command, and by voice control stopping.
    private var autopilotTask: Task<Void, Never>?
    /// Guards the loop's completion handling against staleness: a cancelled
    /// run resumes from its await one MainActor job AFTER a successor run
    /// has already been installed, and must not clobber the successor's
    /// task handle, panel, or state. Bumped by every new run and by stop().
    private var autopilotGeneration = 0
    /// The in-flight near-wake AI rescue, if any — cancelled by stop() and
    /// superseded by any newer near-wake final. Without the handle, a rescue
    /// still waiting on the model when voice control stopped would come back
    /// a model-latency later and dispatch its command — in agent mode,
    /// STARTING an agent run — while the UI says voice is off.
    private var wakeRescueTask: Task<Void, Never>?
    /// Identifies one voice session (a start() … stop()-or-failure
    /// interval). Every await that can straddle a session boundary — the
    /// mic-permission dialog in start(), the wake rescuer's model round,
    /// an executor round that may fall back to the free-form ladder —
    /// captures this before suspending and drops its continuation on a
    /// mismatch: acting on a stale one executes commands (or launches an
    /// engine) after the user turned voice control off. Bumped by stop()
    /// and by engine failure, so a match also proves the session that
    /// scheduled the work is the one still live.
    private var sessionGeneration = 0
    /// AutopilotEngine is macOS 26-only; the untyped slot lets this
    /// controller keep a deployment floor below that.
    private var autopilotStorage: Any?
    private var engine: SpeechEngine?
    private var config = VoiceControlConfig()
    private var noticeTimer: Timer?
    /// Stitches a bare-wake-word final to the command final that follows it.
    private var gate = UtteranceGate()
    private var gateWindowTimer: Timer?
    /// The in-flight utterance (shown in the capsule only once it starts
    /// with the wake word, or while the capture window is open).
    private var liveItemId: String?
    private var liveText = ""
    /// Whether the capsule showed this utterance live — if it did and the
    /// final is then dropped, the user must be told why, never left staring
    /// at a capsule that just vanished.
    private var liveShown = false
    /// Whether any live hypothesis of this utterance strictly matched the
    /// wake word. The final often revises the wake word into ordinary words
    /// ("Pawvis" → "Paw this"); a delta that matched is evidence the user
    /// addressed us, and the final's command shouldn't be dropped for the
    /// recognizer's second thoughts.
    private var liveWakeMatched = false

    var hud: VoiceHUD {
        switch state {
        case .off: return .hidden
        case .connecting: return .connecting
        case .listening:
            if let notice { return .notice(notice) }
            return .listening(wakeWord: config.wakeWord)
        case .resolving: return .resolving
        case .working(let line): return .working(line)
        case .error(let message): return .error(message)
        }
    }

    @available(macOS 26.0, *)
    private var autopilot: AutopilotEngine {
        if let engine = autopilotStorage as? AutopilotEngine { return engine }
        let engine = AutopilotEngine()
        autopilotStorage = engine
        return engine
    }

    func setConfig(_ config: VoiceControlConfig) {
        var config = config
        // Strict wake acceptance whenever the agent hand-off is live: there
        // an accepted utterance is arbitrary execution, so the ladder drops
        // its loosest tiers — no glued-speech stitching, and the capture
        // window stops taking the next final verbatim (handleFinal threads
        // the same flag into the gate). This is app policy, decided here;
        // PawvisCore just takes the flag, and it is never persisted.
        config.strictWake = !config.agentExecutor.isEmpty
        self.config = config
        parser.config = config
        executor.aiAppNameRescueEnabled = config.visualContextEnabled
        transcriptOverlay.enabled = config.transcriptOverlayEnabled
        transcriptOverlay.timeout = config.transcriptOverlaySeconds
        transcriptOverlay.manualDismiss = config.transcriptOverlayManualDismiss
        if !config.transcriptOverlayEnabled {
            transcriptOverlay.hide()
        }
    }

    /// Menu bar entry point.
    func toggle() {
        if state.isActive {
            stop()
        } else {
            start()
        }
    }

    func start() {
        guard !state.isActive else { return }
        guard config.enabled else {
            state = .error("Voice control (beta) is off — enable it in Settings → Voice")
            return
        }

        switch Permissions.microphone() {
        case .denied:
            state = .error("Microphone access denied — enable in System Settings")
            return
        case .notDetermined:
            state = .connecting
            let session = sessionGeneration
            Task { [weak self] in
                let granted = await Permissions.requestMicrophone()
                guard let self else { return }
                // The system dialog sits open as long as the user leaves
                // it, and .connecting is an active state — the menu toggle
                // can stop() voice control while it's up. A grant that
                // lands after that must not launch an engine: that is a
                // hot mic running under state == .off, recognizing and
                // executing commands. (No engine exists yet on this path,
                // so a stale grant has nothing to tear down.)
                guard self.sessionGeneration == session else {
                    Log.voice.log("Mic permission resolved after voice control stopped — engine not launched")
                    return
                }
                if granted {
                    self.launchEngine()
                } else {
                    self.state = .error("Microphone access denied")
                }
            }
            return
        case .granted:
            state = .connecting
            launchEngine()
        }
    }

    func stop() {
        sessionGeneration += 1
        autopilotGeneration += 1
        autopilotTask?.cancel()
        autopilotTask = nil
        wakeRescueTask?.cancel()
        wakeRescueTask = nil
        autopilotPanel.hide()
        engine?.stop()
        engine = nil
        clearNotice()
        transcriptOverlay.hide()
        gate.disarm()
        gateWindowTimer?.invalidate()
        gateWindowTimer = nil
        liveItemId = nil
        liveText = ""
        liveShown = false
        state = .off
    }

    /// Cancels a running autopilot loop without touching the engine — voice
    /// stays listening. The task's own outcome handling flashes "Stopped".
    func cancelAutopilot() {
        autopilotTask?.cancel()
    }

    private func launchEngine() {
        // Defensive: nothing should reach here with an engine live (start()
        // refuses while active, and stale permission grants are dropped),
        // but overwriting one would orphan it with the mic still hot.
        engine?.stop()
        let engine = SpeechEngine(config: config)
        self.engine = engine
        engine.onEvent = { [weak self, weak engine] event in
            // Identity-gated: a stopped engine can still have events queued
            // on the main run loop (the legacy backend's silence-timer
            // finalize doesn't re-check `stopped`; the modern backend's
            // failure hop doesn't either). An event from any engine but the
            // current one is a dead session talking — it must not repaint
            // the capsule, flip state, or dispatch a command.
            guard let self, let engine, self.engine === engine else { return }
            self.handle(event)
        }
        engine.start()
        // Warm the on-device model now so the first free-form command
        // doesn't pay the ~5 s cold-start cost.
        if #available(macOS 26.0, *) {
            if !config.agentExecutor.isEmpty {
                // Agent mode uses the model only to rescue garbled wake words.
                WakeRescuer.prewarm()
            } else if config.visualContextEnabled {
                // The rescuer serves the on-device path too now — a garbled
                // final gets one AI-confirmed second chance either way.
                WakeRescuer.prewarm()
                autopilot.prewarm()
            }
        }
    }

    private var now: TimeInterval { Date().timeIntervalSinceReferenceDate }

    private func handle(_ event: SpeechEvent) {
        switch event {
        case .ready:
            if state.isActive { state = .listening }

        case .hypothesis(let itemId, let text):
            if itemId != liveItemId {
                liveItemId = itemId
                liveShown = false
                liveWakeMatched = false
            }
            // Full hypothesis, not a delta: recognizers revise earlier words
            // mid-utterance, and the capsule repaints with each correction.
            liveText = text
            let live = liveText.trimmingCharacters(in: .whitespacesAndNewlines)
            guard !live.isEmpty else { break }
            if parser.hasWakePrefix(live) { liveWakeMatched = true }
            // The capsule shows only speech addressed to Pawvis — ambient
            // conversation is never displayed. Addressed means: the wake
            // word matched some hypothesis (sticky, so a revision that
            // garbles it away doesn't blank the capsule mid-utterance), the
            // near tier thinks the opening is a mishearing of it ("Paw
            // this…" is usually the user — a final that then drops gets a
            // visible explanation in dropFinal), or the capture window from
            // a bare wake word is open.
            if liveWakeMatched || parser.nearWakeRemainder(live) != nil
                || gate.isArmed(now: now) {
                transcriptOverlay.showLive(live)
                liveShown = true
            }

        case .completed(_, let transcript):
            let showedLive = liveShown
            let wakeHeardLive = liveWakeMatched
            liveItemId = nil
            liveText = ""
            liveShown = false
            liveWakeMatched = false
            handleFinal(transcript, showedLive: showedLive, wakeHeardLive: wakeHeardLive)

        case .failed(let message):
            // Engine failure ends the session as surely as stop(): anything
            // parked on an await from it (a wake rescue mid-model-round, an
            // executor round) must go stale with it, or its continuation
            // would execute a command while the UI shows the error.
            sessionGeneration += 1
            wakeRescueTask?.cancel()
            wakeRescueTask = nil
            engine?.stop()
            engine = nil
            state = .error(message)
        }
    }

    // MARK: - Finalized utterances

    private func handleFinal(_ transcript: String, showedLive: Bool, wakeHeardLive: Bool) {
        let tool = AgentCLIExecutor.Tool(rawValue: config.agentExecutor)
        var remainder = parser.wakeRemainder(transcript)
        // The live hypotheses matched the wake word but the final revised it
        // away ("Pawvis" → "Paw this"): the user addressed us — take the
        // near tier's remainder directly, no AI round needed.
        if remainder == nil, wakeHeardLive,
           let near = parser.nearWakeRemainder(transcript) {
            Log.voice.log("Wake heard live; final revised it — accepting near remainder")
            remainder = near
        }
        // Strict wake (agent mode): the armed window's capture must itself
        // parse deterministically — a wake-carrying final never consults the
        // bar, so "Pawvis quit chrome" (and wake-led free-form speech for
        // the agent) works exactly as before.
        let decision = gate.decide(
            remainder: remainder, transcript: transcript, now: now,
            strictCommandBar: config.strictWake
                ? { [parser] in parser.remainderIsDeterministicCommand($0) }
                : nil)
        gateWindowTimer?.invalidate()
        gateWindowTimer = nil

        switch decision {
        case .command(let command):
            Log.voice.log("Final accepted (wake \(remainder == nil ? "stitched" : "matched", privacy: .public)): \(command, privacy: .private)")
            transcriptOverlay.complete(transcript)
            dispatch(command, tool: tool)

        case .armed:
            // Bare wake word: hold the capsule open and wait for the command
            // (the engine loves to finalize on that pause).
            Log.voice.log("Bare wake word — capture window open")
            transcriptOverlay.showLive("\(config.wakeWord) — listening for your command…")
            gateWindowTimer = Timer.scheduledTimer(
                withTimeInterval: gate.windowSeconds + 0.1, repeats: false
            ) { [weak self] _ in
                Task { @MainActor in
                    // Every final invalidates this timer, so firing means the
                    // window lapsed unused: tidy up. If the user is mid-speech
                    // (capsule live), leave it — the final's own handling
                    // will explain the expired window.
                    guard let self else { return }
                    self.gate.disarm()
                    if !self.liveShown {
                        self.transcriptOverlay.hide()
                    }
                }
            }

        case .ignored:
            handleNoWake(transcript, tool: tool, showedLive: showedLive)
        }
    }

    /// The final didn't start with the wake word and no capture window was
    /// open. Garbled wake words get one AI-confirmed rescue — on the agent
    /// path AND the on-device path (it was agent-only, which left the
    /// default configuration with zero tolerance for a mangled final);
    /// beyond that, an utterance the capsule already showed must end in a
    /// visible explanation, never a silent vanish.
    private func handleNoWake(_ transcript: String, tool: AgentCLIExecutor.Tool?,
                              showedLive: Bool) {
        if tool != nil || config.visualContextEnabled, #available(macOS 26.0, *),
           WakeRescuer.isSupported,
           let nearRemainder = parser.nearWakeRemainder(transcript)?
               .trimmingCharacters(in: .whitespacesAndNewlines),
           !nearRemainder.isEmpty {
            // A newer near-wake final supersedes a rescue still out with
            // the model; the superseded one is cancelled, not raced.
            wakeRescueTask?.cancel()
            let session = sessionGeneration
            wakeRescueTask = Task { [weak self] in
                guard let self else { return }
                let confirmed = (try? await WakeRescuer.confirmsInstruction(nearRemainder)) ?? false
                // The model round takes up to seconds — long enough for
                // voice control to be turned off (or fail, or be turned
                // back on) while it thinks. A confirmation that lands
                // after that must be dropped: dispatching it would run a
                // command — in agent mode, START an agent run — while the
                // UI says voice is off. Session match proves no stop or
                // failure happened since the final arrived.
                guard !Task.isCancelled, self.sessionGeneration == session,
                      self.state.isActive else {
                    Log.voice.log("Near-wake rescue resolved after voice control stopped (or was superseded) — dropped")
                    return
                }
                self.wakeRescueTask = nil
                Log.voice.log("Near-wake rescue \(confirmed ? "confirmed" : "declined", privacy: .public)")
                if confirmed {
                    self.transcriptOverlay.complete(transcript)
                    self.dispatch(nearRemainder, tool: tool)
                } else {
                    self.dropFinal(transcript, showedLive: showedLive)
                }
            }
            return
        }
        dropFinal(transcript, showedLive: showedLive)
    }

    private func dropFinal(_ transcript: String, showedLive: Bool) {
        Log.voice.log("Final dropped (no wake word; shown live: \(showedLive)): \(transcript, privacy: .private)")
        if showedLive {
            // A partial hypothesis matched the wake word but the final lost
            // it — the user watched the capsule accept their words.
            flashNotice("⚠️ Didn't catch “\(config.wakeWord)” — try again")
        } else {
            transcriptOverlay.hide()
        }
    }

    /// Run one wake-stripped command: stop and cancel phrases always work
    /// locally and instantly; agent mode pipes everything else to the chosen
    /// CLI; the on-device path runs the grammar, then the autopilot loop.
    private func dispatch(_ command: String, tool: AgentCLIExecutor.Tool?) {
        // Belt and suspenders under the per-path guards above: a command
        // must never START while the UI says voice control is off. Nothing
        // legitimate is blocked — the eval harnesses (--voice-exec,
        // --selftest) drive the parser and executor directly and never
        // route through this controller.
        guard state.isActive else {
            Log.voice.log("Dispatch dropped — voice control is not active: \(command, privacy: .private)")
            return
        }
        let result = parser.parseRemainder(command)
        if case .stopVoiceControl? = result.command {
            // "Pawvis stop listening" stays what the README promises: local,
            // instant, mic off. Background agent runs are deliberately left
            // to finish — the activity panel belongs to their manager, not
            // to voice state, so they remain visible and cancellable there.
            stop()
            return
        }
        if case .cancelActivity? = result.command {
            // "Pawvis stop": brake whatever is running; with nothing in
            // flight it keeps its original meaning and turns voice off.
            // Background agent runs never live in autopilotTask — they must
            // be braked through their manager, and voice must STAY ON while
            // they wind down: turning it off here would silence the user's
            // only hands-free brake while the agent kept working.
            let agentRuns = agentSessions.cancelAll()
            if autopilotTask != nil || agentRuns > 0 {
                cancelAutopilot()
                if agentRuns > 0 {
                    // Instant acknowledgment — SIGTERM can take seconds to
                    // land; each run's outcome still flashes when it dies.
                    flashNotice(agentRuns == 1
                        ? "Stopping agent run…"
                        : "Stopping \(agentRuns) agent runs…")
                }
            } else {
                stop()
            }
            return
        }
        // Any new command interrupts a running loop — "Pawvis click cancel"
        // during a runaway autopilot means both things the user said.
        cancelAutopilot()
        if let tool {
            runAgent(command, tool: tool)
            return
        }
        typer.perform(result.typing)
        if let parsed = result.command {
            execute(parsed, fallbackTranscript: command)
        }
    }

    // MARK: - Commands (on-device path)

    private func execute(_ command: VoiceCommand, fallbackTranscript: String? = nil) {
        switch command {
        case .stopVoiceControl, .cancelActivity:
            stop()
        case .resolve(let transcript):
            resolveFreeForm(transcript)
        case .sequence(let commands):
            runSequence(commands)
        default:
            let session = sessionGeneration
            Task { [weak self] in
                guard let self else { return }
                let outcome = await self.executor.execute(command)
                // The executor round can outlast the session — a failing
                // app launch waits out waitForFrontmost's timeout, plenty
                // of room for the user to toggle voice off. Post-stop, the
                // free-form rescue below must not restart the model ladder
                // (that resurrects .resolving under a dead mic), and the
                // outcome notice belongs to a session that no longer
                // exists — vanish silently, like superseded loop runs do.
                guard self.sessionGeneration == session, self.state.isActive else { return }
                // The grammar can mis-slice a garbled utterance ("open up
                // safari please" → app "up safari please"). When an app
                // command fails to resolve, hand the whole phrase back to
                // the free-form ladder — which retries with the translator
                // first, never straight into GUI flailing.
                if case .failed = outcome,
                   let fallback = fallbackTranscript,
                   Self.freeFormCanRescue(command) {
                    self.resolveFreeForm(fallback)
                } else {
                    self.show(outcome)
                }
            }
        }
    }

    /// Commands whose failures are usually a mis-sliced argument (worth an
    /// AI retry) rather than a true "can't do that".
    private static func freeFormCanRescue(_ command: VoiceCommand) -> Bool {
        switch command {
        case .open, .switchTo, .quit: return true
        default: return false
        }
    }

    /// A command the deterministic grammar didn't recognize, on-device mode
    /// only — agent mode never reaches the grammar (see `dispatch`). The
    /// ladder matches the on-device model's actual abilities:
    ///
    /// 1. One screen-free translation round — "what single primitive does
    ///    this mean?" — executed deterministically when it compiles. Small
    ///    models translate reliably; they sequence GUI actions badly.
    /// 2. The visual autopilot loop, only for goals that are genuinely
    ///    about the screen (click-family, multi-clause, or translations
    ///    that came back needsScreen/unusable).
    ///
    /// A translated command that then fails reports its failure honestly —
    /// it never cascades into the loop, because the loop drives the same
    /// executor and would only add flailing to the same dead end.
    private func resolveFreeForm(_ goal: String) {
        guard config.visualContextEnabled else {
            flashNotice("Didn't recognize a command: “\(goal)”")
            return
        }
        guard #available(macOS 26.0, *), AutopilotEngine.isSupported else {
            flashNotice("“\(goal)” needs Apple Intelligence (macOS 26)")
            return
        }
        autopilotTask?.cancel()
        autopilotGeneration += 1
        let generation = autopilotGeneration
        // Superseding a run suppresses its own cleanup (the generation
        // guard), so clear its panel here; the loop re-opens it on entry.
        autopilotPanel.hide()
        state = .resolving
        autopilotTask = Task { [weak self] in
            guard let self else { return }
            if !AutopilotPolicy.goesStraightToLoop(goal: goal) {
                let translation = await self.autopilot.translate(goal: goal)
                guard self.autopilotGeneration == generation else { return }
                if Task.isCancelled {
                    self.autopilotTask = nil
                    self.flashNotice("Stopped")
                    if case .resolving = self.state { self.state = .listening }
                    return
                }
                if let translation,
                   let command = TranslationPolicy.command(from: translation) {
                    Log.voice.log("Translated free-form command: \(String(describing: command), privacy: .private)")
                    let outcome = await self.executor.execute(command)
                    guard self.autopilotGeneration == generation else { return }
                    self.autopilotTask = nil
                    self.show(outcome)
                    if case .resolving = self.state { self.state = .listening }
                    return
                }
            }
            await self.runAutopilotLoop(goal: goal, generation: generation)
        }
    }

    /// Deterministic composite ("open chrome and go to youtube dot com"):
    /// every clause already parsed on its own, so run the steps in order,
    /// verifying focus between them. The first step that fails or doesn't
    /// take stops the chain honestly — no model rescue mid-sequence, because
    /// later steps would run against whatever state the failure left behind.
    /// Uses the autopilot task slot so "Pawvis stop" brakes a sequence too.
    private func runSequence(_ commands: [VoiceCommand]) {
        autopilotTask?.cancel()
        autopilotGeneration += 1
        let generation = autopilotGeneration
        autopilotPanel.hide()
        state = .resolving
        autopilotTask = Task { [weak self] in
            guard let self else { return }
            var lastNotice: String?
            for (index, command) in commands.enumerated() {
                if Task.isCancelled { break }
                guard self.autopilotGeneration == generation else { return }
                let outcome = await self.executor.execute(command)
                guard self.autopilotGeneration == generation else { return }
                if Task.isCancelled { break }
                switch outcome {
                case .done(let notice):
                    if let notice {
                        lastNotice = notice
                        self.state = .working(notice)
                    }
                    if let unmet = await self.executor.sequenceSettle(after: command) {
                        self.finishSequence(generation, "⚠️ Step \(index + 1) didn't take: \(unmet)")
                        return
                    }
                case .failed(let message):
                    self.finishSequence(generation, "⚠️ Step \(index + 1) failed: \(message)")
                    return
                }
            }
            if Task.isCancelled {
                self.finishSequence(generation, "Stopped")
                return
            }
            self.finishSequence(
                generation, lastNotice.map { "✓ \($0)" } ?? "✓ Done")
        }
    }

    private func finishSequence(_ generation: Int, _ notice: String) {
        guard autopilotGeneration == generation else { return }
        autopilotTask = nil
        flashNotice(notice)
        switch state {
        case .resolving, .working:
            state = .listening
        default:
            break
        }
    }

    /// The visual loop: look at the screen, act, look again — with the
    /// bottom-right progress panel and Cancel.
    @available(macOS 26.0, *)
    private func runAutopilotLoop(goal: String, generation: Int) async {
        guard autopilotGeneration == generation, !Task.isCancelled else { return }
        autopilotPanel.begin(goal: goal) { [weak self] in
            self?.cancelAutopilot()
        }
        let outcome = await autopilot.run(
            goal: goal, executor: executor
        ) { [weak self] _, line in
            guard let self, self.autopilotGeneration == generation,
                  self.state.isActive else { return }
            self.state = .working(line)
            self.autopilotPanel.append(line: line)
        }
        // A superseded or shut-down run must vanish silently — its
        // successor owns the panel, the notice, and the state now.
        guard autopilotGeneration == generation else { return }
        autopilotTask = nil
        switch outcome {
        case .finished(let notice):
            autopilotPanel.finish(success: true)
            if let notice { flashNotice(notice) }
        case .failed(let message):
            autopilotPanel.finish(success: false)
            flashNotice("⚠️ \(message)")
        case .cancelled:
            autopilotPanel.hide()
            flashNotice("Stopped")
        }
        switch state {
        case .resolving, .working:
            state = .listening
        default:
            break
        }
    }

    // MARK: - Agent runs

    /// Background agent run: voice control stays fully responsive (the run
    /// doesn't hold the parser or the HUD state). The bottom-right activity
    /// panel streams the CLI's output live with a Cancel button, and the
    /// outcome ALWAYS flashes in the capsule — success or failure.
    private func runAgent(_ transcript: String, tool: AgentCLIExecutor.Tool) {
        transcriptOverlay.showLive("🤖 \(tool.displayName): “\(transcript)”…")
        notice = "\(tool.displayName) is working…"
        let timeout = config.agentTimeoutSeconds
        Task { [weak self] in
            guard let self else { return }
            let outcome = await self.agentSessions.run(
                instruction: transcript, tool: tool, timeout: timeout)
            self.showAgentOutcome(outcome, tool: tool)
        }
    }

    /// Unlike on-device actions (whose success is usually self-evident), a
    /// background agent run must always report back — even a bare success.
    private func showAgentOutcome(_ outcome: ExecutionOutcome, tool: AgentCLIExecutor.Tool) {
        switch outcome {
        case .done(let notice):
            flashNotice(notice ?? "✅ Done (\(tool.displayName))")
        case .failed(let message):
            flashNotice("⚠️ \(message)")
        }
    }

    private func show(_ outcome: ExecutionOutcome) {
        switch outcome {
        case .done(let notice):
            if let notice { flashNotice(notice) }
        case .failed(let message):
            flashNotice("⚠️ \(message)")
        }
    }

    // MARK: - Notices

    private func flashNotice(_ text: String) {
        notice = text
        transcriptOverlay.flash(text)
        noticeTimer?.invalidate()
        noticeTimer = Timer.scheduledTimer(
            withTimeInterval: 2.5, repeats: false
        ) { [weak self] _ in
            Task { @MainActor in
                self?.clearNotice()
            }
        }
    }

    private func clearNotice() {
        noticeTimer?.invalidate()
        noticeTimer = nil
        notice = nil
    }
}
