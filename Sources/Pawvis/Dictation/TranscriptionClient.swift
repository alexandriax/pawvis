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
    private let apiKey: String
    private let config: RealtimeProtocol.TranscriptionSessionConfig

    init(apiKey: String, config: RealtimeProtocol.TranscriptionSessionConfig) {
        self.apiKey = apiKey
        self.config = config
    }

    func connect() {
        intentionalClose = false
        var request = URLRequest(url: RealtimeProtocol.websocketURL)
        request.setValue("Bearer \(apiKey)", forHTTPHeaderField: "Authorization")
        request.timeoutInterval = 15

        let session = URLSession(configuration: .default, delegate: self, delegateQueue: nil)
        self.session = session
        let task = session.webSocketTask(with: request)
        self.task = task
        task.resume()
        receiveLoop()

        // Configure the transcription session immediately after connecting.
        do {
            let update = try RealtimeProtocol.sessionUpdateEvent(config: config)
            send(text: String(decoding: update, as: UTF8.self))
        } catch {
            emit(.closed(reason: "failed to encode session config"))
        }

        startPings()
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
                self.handleFailure(reason: error.localizedDescription)
            case .success(let message):
                let data: Data
                switch message {
                case .string(let text): data = Data(text.utf8)
                case .data(let d): data = d
                @unknown default: data = Data()
                }
                if let event = RealtimeProtocol.ServerEvent.decode(data) {
                    if case .sessionUpdated = event {
                        self.emit(.ready)
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

    private func handleFailure(reason: String) {
        guard !intentionalClose else { return }
        intentionalClose = true // one closed event per connection
        emit(.closed(reason: reason))
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
        handleFailure(reason: text)
    }
}
