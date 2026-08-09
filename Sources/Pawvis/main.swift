import AppKit
import Foundation

// Entry point. `--selftest` runs a headless smoke test and exits;
// `--voice-eval [utterance …]` prints where each utterance lands in the
// voice interpretation ladder (live Apple Intelligence when available);
// anything else boots the menu bar app.
if CommandLine.arguments.contains("--selftest") {
    exit(runSelfTest())
}
if let evalIndex = CommandLine.arguments.firstIndex(of: "--voice-eval") {
    exit(runVoiceEval(Array(CommandLine.arguments[(evalIndex + 1)...])))
}

PawvisApp.main()
