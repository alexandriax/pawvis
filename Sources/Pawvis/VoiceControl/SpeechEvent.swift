import Foundation

/// Events the speech engine emits (all delivered on the main queue).
enum SpeechEvent {
    /// The engine is live and consuming microphone audio.
    case ready
    /// Partial hypothesis for an in-progress utterance (may revise).
    case delta(itemId: String, text: String)
    /// Final transcript for one utterance.
    case completed(itemId: String, transcript: String)
    /// Terminal failure — the engine has stopped and won't recover on its own.
    case failed(String)
}
