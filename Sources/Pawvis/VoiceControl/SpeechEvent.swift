import Foundation

/// Events the speech engine emits (all delivered on the main queue).
enum SpeechEvent {
    /// The engine is live and consuming microphone audio.
    case ready
    /// The full current hypothesis for an in-progress utterance. Replaces
    /// the previous hypothesis for the same item wholesale: recognizers
    /// revise earlier words mid-utterance ("pause" → "Pawvis"), and a
    /// corrected hypothesis must repaint the live view, not append to it.
    case hypothesis(itemId: String, text: String)
    /// Final transcript for one utterance.
    case completed(itemId: String, transcript: String)
    /// Terminal failure — the engine has stopped and won't recover on its own.
    case failed(String)
}
