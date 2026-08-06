import Foundation
import PawvisCore

/// WebSocket client for the OpenAI Realtime API in transcription mode.
/// Connect → send session.update → stream audio → receive transcript events.
final class TranscriptionClient: NSObject, URLSessionWebSocketDelegate {
    enum ClientEvent {
        case ready                      // session.updated received; start streaming
        case serverEvent(RealtimeProtocol.ServerEvent)
        case closed(reason: String)
    }

    /// Delivered on the main queue.
    var onEvent: ((ClientEvent) -> Void)?

    private var task: URLSessionWebSocketTask?
    private var session: URLSession?
    private var pingTimer: Timer?
    private var intentionalClose = false
    private var closeEmitted = false
    /// The most informative failure reason seen (server `error` event payload
    /// or close-frame reason). A bare POSIX receive error ("Socket is not
    /// connected") arrives *before* the close frame, so failures are emitted
    /// after a short deferral with whatever richer reason has landed by then.
    private var bestFailureReason: String?
    private let apiKey: String
    private let config: RealtimeProtocol.TranscriptionSessionConfig

    init(apiKey: String, config: RealtimeProtocol.TranscriptionSessionConfig) {
        self.apiKey = apiKey
        self.config = config
    }

    func connect() {
        intentionalClose = false
        closeEmitted = false
        bestFailureReason = nil
        var request = URLRequest(url: RealtimeProtocol.websocketURL)
        request.setValue("Bearer \(apiKey)", forHTTPHeaderField: "Authorization")
        request.timeoutInterval = 15

        let session = URLSession(configuration: .default, delegate: self, delegateQueue: nil)
        self.session = session
        let task = session.webSocketTask(with: request)
        self.task = task
        task.resume()
        receiveLoop()
        startPings()
        // session.update is sent once session.created arrives (see receiveLoop).
    }

    func disconnect() {
        intentionalClose = true
        pingTimer?.invalidate()
        pingTimer = nil
        task?.cancel(with: .goingAway, reason: nil)
        task = nil
        session?.finishTasksAndInvalidate()
        session = nil
    }

    /// Called from the audio queue with raw PCM16 chunks.
    func sendAudio(_ pcm: Data) {
        guard let task, task.state == .running else { return }
        guard let event = try? RealtimeProtocol.audioAppendEvent(base64Audio: pcm.base64EncodedString()) else {
            return
        }
        task.send(.string(String(decoding: event, as: UTF8.self))) { error in
            if let error {
                Log.dictation.error("Audio send failed: \(error.localizedDescription)")
            }
        }
    }

    /// Finalize the current utterance. Needed for models without server VAD
    /// (they never emit `.completed` on their own).
    func commitUtterance() {
        guard let event = try? RealtimeProtocol.commitEvent() else { return }
        send(text: String(decoding: event, as: UTF8.self))
    }

    private func send(text: String) {
        task?.send(.string(text)) { [weak self] error in
            if let error {
                Log.dictation.error("WebSocket send failed: \(error.localizedDescription)")
                self?.handleFailure(reason: error.localizedDescription)
            }
        }
    }

    private func receiveLoop() {
        task?.receive { [weak self] result in
            guard let self else { return }
            switch result {
            case .failure(let error):
                self.handleFailure(reason: error.localizedDescription, isTransportNoise: true)
            case .success(let message):
                let data: Data
                switch message {
                case .string(let text): data = Data(text.utf8)
                case .data(let d): data = d
                @unknown default: data = Data()
                }
                if let event = RealtimeProtocol.ServerEvent.decode(data) {
                    switch event {
                    case .sessionCreated:
                        // Now that the session exists, configure it.
                        if let update = try? RealtimeProtocol.sessionUpdateEvent(config: self.config) {
                            self.send(text: String(decoding: update, as: UTF8.self))
                        }
                    case .sessionUpdated:
                        self.emit(.ready)
                    case .error(let code, let message):
                        // Remember it: if the server closes on us next, this —
                        // not the POSIX receive error — is the real reason.
                        self.bestFailureReason = "\(message)\(code.map { " (\($0))" } ?? "")"
                    default:
                        break
                    }
                    self.emit(.serverEvent(event))
                }
                self.receiveLoop()
            }
        }
    }

    private func startPings() {
        // The API documents no app-level keepalive; WebSocket-protocol pings
        // keep NATs and proxies from idling the connection out.
        DispatchQueue.main.async { [weak self] in
            guard let self else { return }
            self.pingTimer = Timer.scheduledTimer(withTimeInterval: 20, repeats: true) { [weak self] _ in
                self?.task?.sendPing { error in
                    if let error {
                        Log.dictation.debug("Ping failed: \(error.localizedDescription)")
                    }
                }
            }
        }
    }

    private func handleFailure(reason: String, isTransportNoise: Bool = false) {
        guard !intentionalClose, !closeEmitted else { return }
        if !isTransportNoise, bestFailureReason == nil {
            bestFailureReason = reason
        }
        closeEmitted = true
        // Defer briefly: the close frame (with the real reason) often lands
        // just after the receive failure. Emit the best reason we have then.
        DispatchQueue.main.asyncAfter(deadline: .now() + 0.25) { [weak self] in
            guard let self, !self.intentionalClose else { return }
            self.onEvent?(.closed(reason: self.bestFailureReason ?? reason))
        }
    }

    private func emit(_ event: ClientEvent) {
        DispatchQueue.main.async { [weak self] in
            self?.onEvent?(event)
        }
    }

    // MARK: - URLSessionWebSocketDelegate

    func urlSession(
        _ session: URLSession, webSocketTask: URLSessionWebSocketTask,
        didCloseWith closeCode: URLSessionWebSocketTask.CloseCode, reason: Data?
    ) {
        let text = reason.flatMap { String(data: $0, encoding: .utf8) } ?? "code \(closeCode.rawValue)"
        // The close-frame reason beats transport noise but not a decoded
        // server error event.
        if bestFailureReason == nil {
            bestFailureReason = text
        }
        handleFailure(reason: text)
    }
}
