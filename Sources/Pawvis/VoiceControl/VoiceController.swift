import Foundation
import PawvisCore

/// Orchestrates voice control: the on-device speech engine feeds the
/// wake-word command parser; commands run through the executor (and, for
/// free-form ones, the visual-context resolver); typing mode drives synthetic
/// keystrokes. Toggled from the menu bar.
@MainActor
final class VoiceController: ObservableObject {
    enum State: Equatable {
        case off
        case connecting
        case listening   // armed; waiting for the wake word
        case typing      // typing what you say
        case resolving   // consulting the on-screen context for a command
        case error(String)

        var isActive: Bool {
            switch self {
            case .off, .error: return false
            default: return true
            }
        }
    }

    @Published private(set) var state: State = .off
    @Published private(set) var lastTranscript: String = ""
    /// Transient confirmation ("Opening Safari"), auto-cleared.
    @Published private(set) var notice: String?

    private let parser = VoiceControlParser()
    private let typer = TextTyper()
    private let executor = CommandExecutor()
    private let screenContext = ScreenContextProvider()
    private var engine: SpeechEngine?
    private var config = VoiceControlConfig()
    private var pauseTimer: Timer?
    private var noticeTimer: Timer?

    var hud: VoiceHUD {
        switch state {
        case .off: return .hidden
        case .connecting: return .connecting
        case .listening:
            if let notice { return .notice(notice) }
            return .listening(wakeWord: config.wakeWord)
        case .typing: return .typing(String(lastTranscript.suffix(60)))
        case .resolving: return .resolving
        case .error(let message): return .error(message)
        }
    }

    func setConfig(_ config: VoiceControlConfig) {
        self.config = config
        parser.config = config
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
            state = .error("Voice control is disabled in Settings")
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
        pauseTimer?.invalidate()
        pauseTimer = nil
        clearNotice()
        state = .off
        lastTranscript = ""
    }

    private func launchEngine() {
        let engine = SpeechEngine(config: config)
        self.engine = engine
        parser.beginListening()
        engine.onEvent = { [weak self] event in
            self?.handle(event)
        }
        engine.start()
    }

    private func handle(_ event: SpeechEvent) {
        switch event {
        case .ready:
            syncStateFromParser()

        case .delta(let itemId, let text):
            let actions = parser.handleDelta(itemId: itemId, delta: text)
            typer.perform(actions)
            if parser.state == .typing {
                lastTranscript += text
                armPauseTimer() // speech is ongoing — push the pause out
            }

        case .completed(let itemId, let transcript):
            let result = parser.handleCompleted(itemId: itemId, transcript: transcript)
            typer.perform(result.typing)
            lastTranscript = parser.state == .typing ? transcript : ""
            if let command = result.command {
                execute(command)
            }
            syncStateFromParser()
            armPauseTimer()

        case .failed(let message):
            engine?.stop()
            engine = nil
            state = .error(message)
        }
    }

    // MARK: - Commands

    private func execute(_ command: VoiceCommand) {
        switch command {
        case .stopVoiceControl:
            stop()
        case .resolve(let transcript):
            resolveWithContext(transcript)
        default:
            Task { [weak self] in
                guard let self else { return }
                self.show(await self.executor.execute(command))
            }
        }
    }

    /// Free-form command: look at the screen around the pointer, ask the
    /// on-device model what to do, escalate to the full screen if the target
    /// isn't nearby.
    private func resolveWithContext(_ transcript: String) {
        guard config.visualContextEnabled else {
            flashNotice("Didn't recognize a command: “\(transcript)”")
            return
        }
        guard #available(macOS 26.0, *), VisualIntentResolver.isSupported else {
            flashNotice("“\(transcript)” needs Apple Intelligence (macOS 26)")
            return
        }
        state = .resolving
        Task { [weak self] in
            guard let self else { return }
            let outcome = await VisualIntentResolver.resolveAndExecute(
                transcript: transcript,
                screenContext: self.screenContext,
                executor: self.executor)
            if self.state == .resolving {
                self.syncStateFromParser()
            }
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

    // MARK: - Typing pause

    /// Typing mode ends on its own after a quiet spell — no stop phrase
    /// needed. Re-armed on every delta and completed utterance.
    private func armPauseTimer() {
        pauseTimer?.invalidate()
        pauseTimer = nil
        guard parser.state == .typing else { return }
        pauseTimer = Timer.scheduledTimer(
            withTimeInterval: max(1.0, config.typingPauseSeconds), repeats: false
        ) { [weak self] _ in
            Task { @MainActor in
                guard let self, self.state.isActive else { return }
                if self.parser.handlePauseTimeout() {
                    self.lastTranscript = ""
                    self.syncStateFromParser()
                    self.flashNotice("Stopped typing (pause)")
                }
            }
        }
    }

    // MARK: - Notices

    private func flashNotice(_ text: String) {
        notice = text
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

    private func syncStateFromParser() {
        guard state.isActive else { return }
        state = parser.state == .typing ? .typing : .listening
    }
}
