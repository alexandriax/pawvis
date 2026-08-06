import Foundation
import PawvisCore

/// Cloud transcription via the OpenAI Realtime API: mic → 24 kHz PCM16 →
/// websocket. Handles transient reconnects internally; emits `.failed` only
/// when retries are exhausted or the error is terminal (bad key).
final class OpenAITranscriptionProvider: TranscriptionProvider {
    var onEvent: ((TranscriptionEvent) -> Void)?

    private let apiKey: String
    private let sessionConfig: RealtimeProtocol.TranscriptionSessionConfig
    private let audio = AudioCapture()
    private var client: TranscriptionClient?
    private var reconnectAttempts = 0
    private var stopped = false

    init(apiKey: String, config: DictationConfig) {
        self.apiKey = apiKey
        self.sessionConfig = RealtimeProtocol.TranscriptionSessionConfig(
            model: config.model,
            language: config.language,
            prompt: "",
            vadSilenceMs: config.vadSilenceMs,
            noiseReduction: config.noiseReduction)
    }

    func start() {
        stopped = false
        connect()
    }

    func stop() {
        stopped = true
        audio.stop()
        client?.disconnect()
        client = nil
    }

    private func connect() {
        let client = TranscriptionClient(apiKey: apiKey, config: sessionConfig)
        self.client = client
        client.onEvent = { [weak self] event in
            self?.handle(event)
        }
        client.connect()
    }

    private func handle(_ event: TranscriptionClient.ClientEvent) {
        guard !stopped else { return }
        switch event {
        case .ready:
            reconnectAttempts = 0
            startAudio()
            onEvent?(.ready)

        case .serverEvent(let serverEvent):
            handleServer(serverEvent)

        case .closed(let reason):
            audio.stop()
            if reconnectAttempts < 3 {
                reconnectAttempts += 1
                let delay = Double(reconnectAttempts)
                Log.dictation.info("Reconnecting dictation (attempt \(self.reconnectAttempts)) after: \(reason, privacy: .public)")
                DispatchQueue.main.asyncAfter(deadline: .now() + delay) { [weak self] in
                    guard let self, !self.stopped else { return }
                    self.connect()
                }
            } else {
                onEvent?(.failed("Connection lost: \(reason)"))
            }
        }
    }

    private func handleServer(_ event: RealtimeProtocol.ServerEvent) {
        switch event {
        case .transcriptDelta(let itemId, let delta):
            onEvent?(.delta(itemId: itemId, text: delta))
        case .transcriptCompleted(let itemId, let transcript):
            onEvent?(.completed(itemId: itemId, transcript: transcript))
        case .transcriptFailed(_, let message):
            Log.dictation.error("Transcription failed: \(message, privacy: .public)")
        case .error(let code, let message):
            // Auth errors are terminal; most others are recoverable in-session.
            if code == "invalid_api_key" {
                stop()
                onEvent?(.failed("Invalid OpenAI API key"))
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
            stop()
            onEvent?(.failed("Microphone error: \(error.localizedDescription)"))
        }
    }
}
