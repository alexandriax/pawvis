import Foundation
import PawvisCore

/// Orchestrates voice dictation: a transcription engine (Apple on-device or
/// OpenAI realtime) feeds the wake-word parser, which drives synthetic typing.
/// Toggled by gesture or from the menu bar.
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
    private var provider: TranscriptionProvider?
    private var config = DictationConfig()

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
                    self.launchProvider()
                } else {
                    self.state = .error("Microphone access denied")
                }
            }
            return
        case .granted:
            state = .connecting
            launchProvider()
        }
    }

    func stop() {
        provider?.stop()
        provider = nil
        state = .off
        lastTranscript = ""
    }

    private func launchProvider() {
        guard let provider = makeProvider() else { return }
        self.provider = provider
        parser.beginListening()
        provider.onEvent = { [weak self] event in
            self?.handle(event)
        }
        provider.start()
    }

    private func makeProvider() -> TranscriptionProvider? {
        switch config.engine {
        case "openai":
            guard let apiKey = APIKeyResolver.resolve() else {
                state = .error("No OpenAI API key — add one in Settings")
                return nil
            }
            return OpenAITranscriptionProvider(apiKey: apiKey, config: config)
        default:
            return AppleTranscriptionProvider(config: config)
        }
    }

    private func handle(_ event: TranscriptionEvent) {
        switch event {
        case .ready:
            syncStateFromParser()

        case .delta(let itemId, let text):
            let actions = parser.handleDelta(itemId: itemId, delta: text)
            typer.perform(actions)
            if parser.state == .dictating {
                lastTranscript += text
            }

        case .completed(let itemId, let transcript):
            let actions = parser.handleCompleted(itemId: itemId, transcript: transcript)
            typer.perform(actions)
            lastTranscript = parser.state == .dictating ? transcript : ""
            syncStateFromParser()

        case .failed(let message):
            provider?.stop()
            provider = nil
            state = .error(message)
        }
    }

    private func syncStateFromParser() {
        guard state.isActive else { return }
        state = parser.state == .dictating ? .dictating : .listening
    }
}
