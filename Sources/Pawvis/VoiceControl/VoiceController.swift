import Foundation
import PawvisCore

/// Orchestrates voice control (beta): the on-device speech engine feeds the
/// wake-word parser; recognized commands run through the executor, and
/// free-form ones go to the on-device intent mapper (or the opt-in agent
/// CLI). Every command is one-shot — nothing keeps listening-side state
/// between utterances, and speech without the wake word is ignored entirely.
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
    private let agent = AgentCLIExecutor()
    /// The top-of-screen capsule showing what's being heard.
    let transcriptOverlay = TranscriptOverlay()
    private var engine: SpeechEngine?
    private var config = VoiceControlConfig()
    private var noticeTimer: Timer?
    /// The in-flight utterance (shown in the capsule only once it starts
    /// with the wake word).
    private var liveItemId: String?
    private var liveText = ""

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
        liveItemId = nil
        liveText = ""
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

    private func handle(_ event: SpeechEvent) {
        switch event {
        case .ready:
            if state.isActive { state = .listening }

        case .delta(let itemId, let text):
            if itemId != liveItemId {
                liveItemId = itemId
                liveText = ""
            }
            liveText += text
            // The capsule shows only speech addressed to Pawvis — ambient
            // conversation is never displayed.
            let live = liveText.trimmingCharacters(in: .whitespacesAndNewlines)
            if parser.hasWakePrefix(live) {
                transcriptOverlay.showLive(live)
            }

        case .completed(_, let transcript):
            liveItemId = nil
            liveText = ""
            if let tool = AgentCLIExecutor.Tool(rawValue: config.agentExecutor) {
                handleAgentUtterance(transcript, tool: tool)
                return
            }
            guard parser.hasWakePrefix(transcript) else {
                // A partial hypothesis may have matched and shown the
                // capsule; the final says it wasn't for us.
                transcriptOverlay.hide()
                return
            }
            transcriptOverlay.complete(transcript)
            let result = parser.parse(transcript)
            typer.perform(result.typing)
            if let command = result.command {
                execute(command, fallbackTranscript: parser.wakeRemainder(transcript))
            }

        case .failed(let message):
            engine?.stop()
            engine = nil
            state = .error(message)
        }
    }

    // MARK: - Commands

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
    /// only — agent mode never reaches the grammar (see
    /// `handleAgentUtterance`). The transcript is already stripped of the
    /// wake word — clean for the intent mapper (with screen grounding for
    /// commands that refer to what's visible).
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

    /// Agent mode is a pipe: everything spoken after the wake word goes to
    /// the chosen agent CLI verbatim — the local grammar doesn't intercept.
    /// Two exceptions: "stop listening" (and friends) still works instantly,
    /// because turning voice control off must never wait on an agent round
    /// trip; and a bare wake word does nothing. When the strict wake gate
    /// rejects the utterance but the opening chunks *nearly* match the wake
    /// word, the on-device model gets one chance to confirm the mishearing
    /// and recover the command — unconfirmed utterances are dropped unseen.
    private func handleAgentUtterance(_ transcript: String, tool: AgentCLIExecutor.Tool) {
        if parser.wakeRemainder(transcript) != nil {
            transcriptOverlay.complete(transcript)
            if case .stopVoiceControl? = parser.parse(transcript).command {
                stop()
                return
            }
            dispatchToAgent(parser.wakeRemainder(transcript), tool: tool)
            return
        }
        guard #available(macOS 26.0, *), WakeRescuer.isSupported,
              let nearRemainder = parser.nearWakeRemainder(transcript)?
                  .trimmingCharacters(in: .whitespacesAndNewlines),
              !nearRemainder.isEmpty else {
            transcriptOverlay.hide()
            return
        }
        Task { [weak self] in
            guard let self else { return }
            let confirmed = (try? await WakeRescuer.confirmsInstruction(nearRemainder)) ?? false
            guard confirmed else {
                self.transcriptOverlay.hide()
                return
            }
            self.transcriptOverlay.complete(transcript)
            self.dispatchToAgent(nearRemainder, tool: tool)
        }
    }

    private func dispatchToAgent(_ command: String?, tool: AgentCLIExecutor.Tool) {
        let cleaned = command?.trimmingCharacters(in: .whitespacesAndNewlines) ?? ""
        // Bare wake word — attention with nothing to do.
        guard !cleaned.isEmpty else { return }
        runAgent(cleaned, tool: tool)
    }

    /// Background agent run: voice control stays fully responsive (the run
    /// doesn't hold the parser or the HUD state); the capsule shows a
    /// persistent "working" note until the outcome flash replaces it.
    private func runAgent(_ transcript: String, tool: AgentCLIExecutor.Tool) {
        transcriptOverlay.showLive("🤖 \(tool.displayName): “\(transcript)”…")
        notice = "\(tool.displayName) is working…"
        let timeout = config.agentTimeoutSeconds
        Task { [weak self] in
            guard let self else { return }
            let outcome = await self.agent.run(
                instruction: transcript, tool: tool, timeout: timeout)
            self.show(outcome)
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
