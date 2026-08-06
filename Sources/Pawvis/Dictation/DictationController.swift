import Foundation
import PawvisCore

/// Orchestrates voice dictation: mic → realtime transcription → wake-word
/// parser → synthetic typing. Toggled by gesture or from the menu bar.
@MainActor
final class DictationController: ObservableObject {
    enum State: Equatable {
        case off
        case connecting
        case listening   // armed; waiting for a wake word
        case dictating   // typing what you say
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

    private let parser = DictationParser()
    private let typer = TextTyper()
    private let audio = AudioCapture()
    private var client: TranscriptionClient?
    private var config = DictationConfig()
    private var reconnectAttempts = 0
    private var micPermissionRequested = false

    var hud: DictationHUD {
        switch state {
        case .off: return .hidden
        case .connecting: return .connecting
        case .listening: return .listening
        case .dictating: return .dictating(String(lastTranscript.suffix(60)))
        case .error(let message): return .error(message)
        }
    }

    func setConfig(_ config: DictationConfig) {
        self.config = config
        parser.config = config
    }

    /// Gesture / menu entry point.
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
            state = .error("Dictation is disabled in Settings")
            return
        }
        guard let apiKey = APIKeyResolver.resolve() else {
            state = .error("No OpenAI API key — add one in Settings")
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
                    self.connect(apiKey: apiKey)
                } else {
                    self.state = .error("Microphone access denied")
                }
            }
            return
        case .granted:
            state = .connecting
            connect(apiKey: apiKey)
        }
    }

    func stop() {
        audio.stop()
        client?.disconnect()
        client = nil
        state = .off
        lastTranscript = ""
        reconnectAttempts = 0
    }

    private func connect(apiKey: String) {
        parser.beginListening()
        let sessionConfig = RealtimeProtocol.TranscriptionSessionConfig(
            model: config.model,
            language: config.language,
            prompt: "",
            vadSilenceMs: config.vadSilenceMs,
            noiseReduction: config.noiseReduction)

        let client = TranscriptionClient(apiKey: apiKey, config: sessionConfig)
        self.client = client
        client.onEvent = { [weak self] event in
            self?.handleClientEvent(event)
        }
        client.connect()
    }

    private func handleClientEvent(_ event: TranscriptionClient.ClientEvent) {
        switch event {
        case .ready:
            reconnectAttempts = 0
            startAudio()
            syncStateFromParser()

        case .serverEvent(let serverEvent):
            handleServerEvent(serverEvent)

        case .closed(let reason):
            guard state.isActive else { return }
            audio.stop()
            // Transient network drop while armed: retry with backoff.
            if reconnectAttempts < 3, let apiKey = APIKeyResolver.resolve() {
                reconnectAttempts += 1
                let delay = Double(reconnectAttempts)
                state = .connecting
                Log.dictation.info("Reconnecting dictation (attempt \(self.reconnectAttempts)) after: \(reason, privacy: .public)")
                Task { [weak self] in
                    try? await Task.sleep(for: .seconds(delay))
                    guard let self, self.state == .connecting else { return }
                    self.connect(apiKey: apiKey)
                }
            } else {
                state = .error("Dictation connection lost: \(reason)")
            }
        }
    }

    private func handleServerEvent(_ event: RealtimeProtocol.ServerEvent) {
        switch event {
        case .transcriptDelta(let itemId, let delta):
            let actions = parser.handleDelta(itemId: itemId, delta: delta)
            typer.perform(actions)
            if parser.state == .dictating {
                lastTranscript += delta
            }

        case .transcriptCompleted(let itemId, let transcript):
            let actions = parser.handleCompleted(itemId: itemId, transcript: transcript)
            typer.perform(actions)
            lastTranscript = parser.state == .dictating ? transcript : ""
            syncStateFromParser()

        case .transcriptFailed(_, let message):
            Log.dictation.error("Transcription failed: \(message, privacy: .public)")

        case .error(let code, let message):
            // Auth errors are terminal; most others are recoverable and the
            // session stays open.
            if code == "invalid_api_key" {
                stop()
                state = .error("Invalid OpenAI API key")
            } else {
                Log.dictation.error("Realtime error [\(code ?? "-", privacy: .public)]: \(message, privacy: .public)")
            }

        case .sessionCreated, .sessionUpdated, .speechStarted, .speechStopped, .other:
            break
        }
    }

    private func startAudio() {
        guard !audio.isRunning else { return }
        audio.onChunk = { [weak self] data in
            self?.client?.sendAudio(data)
        }
        do {
            try audio.start()
        } catch {
            state = .error("Microphone error: \(error.localizedDescription)")
            client?.disconnect()
            client = nil
        }
    }

    private func syncStateFromParser() {
        guard state.isActive else { return }
        state = parser.state == .dictating ? .dictating : .listening
    }
}
