import Foundation

/// Events a transcription engine emits (all delivered on the main queue).
enum TranscriptionEvent {
    /// The engine is live and consuming microphone audio.
    case ready
    /// Partial hypothesis for an in-progress utterance (may revise).
    case delta(itemId: String, text: String)
    /// Final transcript for one utterance.
    case completed(itemId: String, transcript: String)
    /// Terminal failure — the engine has stopped and won't recover on its own.
    case failed(String)
}

/// A speech-to-text engine. Each provider owns its audio capture internally
/// (different engines want different formats); the caller guarantees the
/// microphone permission is granted before `start()`.
protocol TranscriptionProvider: AnyObject {
    var onEvent: ((TranscriptionEvent) -> Void)? { get set }
    func start()
    func stop()
}
