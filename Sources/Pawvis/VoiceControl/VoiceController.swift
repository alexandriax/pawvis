import Foundation
import PawvisCore

/// Orchestrates voice control (beta): the on-device speech engine feeds the
/// wake-word parser; recognized commands run through the executor, and
/// free-form ones go to the on-device intent mapper (or the opt-in agent
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
        case resolving   // consulting the on-device model / screen context
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
    private let screenContext = ScreenContextProvider()
    private let agentSessions = AgentSessionManager.shared
    /// The top-of-screen capsule showing what's being heard.
    let transcriptOverlay = TranscriptOverlay()
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

    var hud: VoiceHUD {
        switch state {
        case .off: return .hidden
        case .connecting: return .connecting
        case .listening:
            if let notice { return .notice(notice) }
            return .listening(wakeWord: config.wakeWord)
        case .resolving: return .resolving
        case .error(let message): return .error(message)
        }
    }

    func setConfig(_ config: VoiceControlConfig) {
        self.config = config
        parser.config = config
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
            Task { [weak self] in
                let granted = await Permissions.requestMicrophone()
                guard let self else { return }
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

    private func launchEngine() {
        let engine = SpeechEngine(config: config)
        self.engine = engine
        engine.onEvent = { [weak self] event in
            self?.handle(event)
        }
        engine.start()
        // Warm the on-device model now so the first mapped command doesn't
        // pay the ~5 s cold-start cost.
        if #available(macOS 26.0, *) {
            if !config.agentExecutor.isEmpty {
                // Agent mode uses the model only to rescue garbled wake words.
                WakeRescuer.prewarm()
            } else if config.visualContextEnabled {
                IntentMapper.prewarm()
                VisualIntentResolver.prewarm()
            }
        }
    }

    private var now: TimeInterval { Date().timeIntervalSinceReferenceDate }

    private func handle(_ event: SpeechEvent) {
        switch event {
        case .ready:
            if state.isActive { state = .listening }

        case .delta(let itemId, let text):
            if itemId != liveItemId {
                liveItemId = itemId
                liveText = ""
                liveShown = false
            }
            liveText += text
            // The capsule shows only speech addressed to Pawvis — ambient
            // conversation is never displayed. While the capture window is
            // open the speech *is* addressed to Pawvis (the wake word was the
            // previous final), so it shows too.
            let live = liveText.trimmingCharacters(in: .whitespacesAndNewlines)
            if parser.hasWakePrefix(live) || gate.isArmed(now: now) {
                transcriptOverlay.showLive(live)
                liveShown = true
            }

        case .completed(_, let transcript):
            let showedLive = liveShown
            liveItemId = nil
            liveText = ""
            liveShown = false
            handleFinal(transcript, showedLive: showedLive)

        case .failed(let message):
            engine?.stop()
            engine = nil
            state = .error(message)
        }
    }

    // MARK: - Finalized utterances

    private func handleFinal(_ transcript: String, showedLive: Bool) {
        let tool = AgentCLIExecutor.Tool(rawValue: config.agentExecutor)
        let remainder = parser.wakeRemainder(transcript)
        let decision = gate.decide(remainder: remainder, transcript: transcript, now: now)
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
    /// open. Agent mode gives garbled wake words one AI-confirmed rescue;
    /// beyond that, an utterance the capsule already showed must end in a
    /// visible explanation, never a silent vanish.
    private func handleNoWake(_ transcript: String, tool: AgentCLIExecutor.Tool?,
                              showedLive: Bool) {
        if tool != nil, #available(macOS 26.0, *), WakeRescuer.isSupported,
           let nearRemainder = parser.nearWakeRemainder(transcript)?
               .trimmingCharacters(in: .whitespacesAndNewlines),
           !nearRemainder.isEmpty {
            Task { [weak self] in
                guard let self else { return }
                let confirmed = (try? await WakeRescuer.confirmsInstruction(nearRemainder)) ?? false
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

    /// Run one wake-stripped command: stop phrases always work locally and
    /// instantly; agent mode pipes everything else to the chosen CLI; the
    /// on-device path runs the grammar, then the intent mapper.
    private func dispatch(_ command: String, tool: AgentCLIExecutor.Tool?) {
        let result = parser.parseRemainder(command)
        if case .stopVoiceControl? = result.command {
            stop()
            return
        }
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
        case .stopVoiceControl:
            stop()
        case .resolve(let transcript):
            handleFreeForm(transcript)
        default:
            Task { [weak self] in
                guard let self else { return }
                let outcome = await self.executor.execute(command)
                // The grammar can mis-slice a garbled utterance ("open up
                // safari please" → app "up safari please"). When an app
                // command fails to resolve, give the intent mapper the whole
                // phrase for a second opinion instead of surfacing the error.
                if case .failed = outcome,
                   let fallback = fallbackTranscript,
                   Self.mapperCanRescue(command) {
                    self.handleFreeForm(fallback)
                } else {
                    self.show(outcome)
                }
            }
        }
    }

    /// Commands whose failures are usually a mis-sliced argument (worth an
    /// AI retry) rather than a true "can't do that".
    private static func mapperCanRescue(_ command: VoiceCommand) -> Bool {
        switch command {
        case .open, .switchTo: return true
        default: return false
        }
    }

    /// A command the deterministic grammar didn't recognize, on-device mode
    /// only — agent mode never reaches the grammar (see `dispatch`). The
    /// transcript is already stripped of the wake word — clean for the
    /// intent mapper (with screen grounding for commands that refer to
    /// what's visible).
    private func handleFreeForm(_ transcript: String) {
        guard config.visualContextEnabled else {
            flashNotice("Didn't recognize a command: “\(transcript)”")
            return
        }
        guard #available(macOS 26.0, *), IntentMapper.isSupported else {
            flashNotice("“\(transcript)” needs Apple Intelligence (macOS 26)")
            return
        }
        state = .resolving
        Task { [weak self] in
            guard let self else { return }
            if Self.isTargetedClick(transcript) {
                // "click <target>" is screen grounding by definition — skip
                // the intent-mapping round trip.
                let outcome = await VisualIntentResolver.resolveAndExecute(
                    transcript: transcript,
                    screenContext: self.screenContext,
                    executor: self.executor)
                self.show(outcome)
            } else {
                do {
                    let intent = try await IntentMapper.map(transcript)
                    await self.perform(intent, transcript: transcript)
                } catch {
                    Log.voice.error("Intent mapping failed: \(error.localizedDescription, privacy: .public)")
                    self.flashNotice("⚠️ Couldn't work out “\(transcript)”")
                }
            }
            if self.state == .resolving {
                self.state = .listening
            }
        }
    }

    /// "click …" / "tap …" with any target words after the verb.
    private static func isTargetedClick(_ transcript: String) -> Bool {
        let tokens = VoiceControlParser.normalize(transcript)
            .split(separator: " ").map(String.init)
        guard let first = tokens.first else { return false }
        var rest = tokens.dropFirst()
        if first == "right" || first == "double", rest.first == "click" || rest.first == "tap" {
            rest = rest.dropFirst()
        } else if first != "click" && first != "tap" {
            return false
        }
        return !rest.isEmpty
    }

    @available(macOS 26.0, *)
    private func perform(_ intent: IntentMapper.MappedIntent, transcript: String) async {
        // The model labels targeted clicks as pointer clicks but still
        // extracts the target — that's a screen action.
        let clickish = intent.action == .clickAtPointer
            || intent.action == .rightClickAtPointer
            || intent.action == .doubleClickAtPointer
        if clickish, let target = intent.argument,
           !target.trimmingCharacters(in: .whitespaces).isEmpty {
            let outcome = await VisualIntentResolver.resolveAndExecute(
                transcript: transcript,
                screenContext: screenContext,
                executor: executor)
            show(outcome)
            return
        }

        switch intent.action {
        case .typeText:
            guard let text = intent.argument, !text.isEmpty else {
                flashNotice("Nothing to type")
                return
            }
            typer.perform([.type(text)])

        case .stopListening:
            stop()

        case .screenAction:
            // Refers to something visible: ground it against the screen
            // around the pointer (escalating to the whole screen if needed).
            let outcome = await VisualIntentResolver.resolveAndExecute(
                transcript: transcript,
                screenContext: screenContext,
                executor: executor)
            show(outcome)

        case .none:
            flashNotice("Didn't understand: “\(transcript)”")

        default:
            if let command = IntentMapper.command(for: intent) {
                show(await executor.execute(command))
            } else {
                flashNotice("Didn't understand: “\(transcript)”")
            }
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
