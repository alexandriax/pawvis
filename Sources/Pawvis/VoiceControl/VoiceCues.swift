import AppKit

/// Subtle audible feedback for voice control, off by default
/// (`voiceControl.audibleCues`); the caller checks the toggle so it applies
/// live. Two system sounds from /System/Library/Sounds, chosen by convention
/// rather than by ear (a headless build can't listen to itself): Tink is the
/// acknowledgement — a command was heard, and again when it finishes well —
/// and Bottle is the distinct failure note.
@MainActor
enum VoiceCues {
    /// The wake word landed and a command is being dispatched.
    static func commandHeard() { play("Tink") }
    /// The command finished successfully.
    static func succeeded() { play("Tink") }
    /// The command failed.
    static func failed() { play("Bottle") }

    /// NSSound playback is asynchronous — `play()` returns immediately — so
    /// cues never block the main thread. A fresh instance per play lets a
    /// quick success cue overlap the heard cue instead of being swallowed.
    private static func play(_ name: String) {
        NSSound(named: name)?.play()
    }
}
