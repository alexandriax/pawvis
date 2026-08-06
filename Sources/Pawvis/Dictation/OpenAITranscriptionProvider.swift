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

    /// Models without server VAD never emit `.completed` on their own — the
    /// client must send input_audio_buffer.commit after each pause in speech.
    private var needsClientCommit: Bool { !sessionConfig.supportsServerVAD }
    private var commitTimer: Timer?
    private var hasUncommittedSpeech = false
    private var commitSilence: TimeInterval {
        Double(sessionConfig.vadSilenceMs) / 1000 + 0.25
    }

    /// Server error codes that no amount of reconnecting will fix.
    private static let terminalErrorCodes: Set<String> = [
        "invalid_api_key", "missing_model", "invalid_model",
        "invalid_value", "beta_api_shape_disabled",
    ]

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
        commitTimer?.invalidate()
        commitTimer = nil
        audio.stop()
        if hasUncommittedSpeech {
            // Best effort: flush the in-flight utterance. Its completion may
            // not arrive before the disconnect, but without this it never would.
            client?.commitUtterance()
            hasUncommittedSpeech = false
        }
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
            if needsClientCommit {
                hasUncommittedSpeech = true
                armCommitTimer()
            }
            onEvent?(.delta(itemId: itemId, text: delta))
        case .transcriptCompleted(let itemId, let transcript):
            hasUncommittedSpeech = false
            onEvent?(.completed(itemId: itemId, transcript: transcript))
        case .transcriptFailed(_, let message):
            hasUncommittedSpeech = false
            Log.dictation.error("Transcription failed: \(message, privacy: .public)")
        case .error(let code, let message):
            // Config/auth errors are terminal — reconnecting would just replay
            // them three times. Anything else is recoverable in-session.
            if let code, Self.terminalErrorCodes.contains(code) {
                stop()
                onEvent?(.failed(code == "invalid_api_key" ? "Invalid OpenAI API key" : message))
            } else {
                Log.dictation.error("Realtime error [\(code ?? "-", privacy: .public)]: \(message, privacy: .public)")
            }
        case .sessionCreated, .sessionUpdated, .speechStarted, .speechStopped, .other:
            break
        }
    }

    /// Commit after a quiet gap in deltas — poor man's VAD for models that
    /// stream one endless item (delta flow stops when you stop talking).
    private func armCommitTimer() {
        commitTimer?.invalidate()
        commitTimer = Timer.scheduledTimer(withTimeInterval: commitSilence, repeats: false) { [weak self] _ in
            guard let self, !self.stopped, self.hasUncommittedSpeech else { return }
            self.client?.commitUtterance()
            self.hasUncommittedSpeech = false
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
