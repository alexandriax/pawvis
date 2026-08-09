import AppKit
import Foundation
import PawvisCore

/// Headless voice-interpretation eval (`Pawvis --voice-eval [utterance …]`):
/// prints where each utterance lands in the ladder — grammar, translation,
/// or the visual loop — so interpretation quality is measured from a
/// terminal, not by talking at the mic and watching the pointer. With no
/// arguments it runs a built-in corpus of the commands the ladder must get
/// right.
///
/// The translation stage runs LIVE against Apple Intelligence when the OS
/// and model allow (this is the one place the model's own judgment can be
/// inspected off-mic); otherwise those rows say so and everything
/// deterministic still prints. Nothing is executed — this evaluates
/// interpretation, never side effects.
func runVoiceEval(_ utterances: [String]) -> Int32 {
    let corpus = utterances.isEmpty ? defaultEvalCorpus : utterances

    print("Voice interpretation eval — \(corpus.count) utterance(s)")
    print("Stage 1 grammar / stage 2 translation / stage 3 visual loop\n")

    // The translation legs run on the main actor, so the wait must pump the
    // main run loop — a blocking semaphore here deadlocks the whole eval.
    var finished = false
    Task { @MainActor in
        await evalRows(corpus)
        finished = true
    }
    let deadline = Date().addingTimeInterval(180)
    while !finished, Date() < deadline {
        RunLoop.main.run(mode: .default, before: Date().addingTimeInterval(0.05))
    }
    if !finished {
        print("TIMED OUT waiting for the on-device model")
        return 1
    }
    return 0
}

@MainActor
private func evalRows(_ corpus: [String]) async {
    let parser = VoiceControlParser()
    // One engine for the whole run: rows after the first ride a warm
    // session, the same shape as real use.
    var engineStorage: Any?
    if #available(macOS 26.0, *), AutopilotEngine.isSupported {
        let engine = AutopilotEngine()
        engine.prewarm()
        engineStorage = engine
    }

    for utterance in corpus {
        let result = parser.parseRemainder(utterance)
        if !result.typing.isEmpty {
            print("[grammar]    “\(utterance)” → type \(result.typing)")
            continue
        }
        guard let command = result.command else {
            print("[none]       “\(utterance)” → no action")
            continue
        }
        guard case .resolve(let goal) = command else {
            print("[grammar]    “\(utterance)” → \(command)")
            continue
        }
        if AutopilotPolicy.goesStraightToLoop(goal: goal) {
            let scope = AutopilotPolicy.initialScope(goal: goal) == .nearPointer
                ? "near pointer" : "full screen"
            print("[loop]       “\(utterance)” → visual loop (\(scope) first)")
            continue
        }
        guard #available(macOS 26.0, *),
              let engine = engineStorage as? AutopilotEngine else {
            print("[translate?] “\(utterance)” → needs Apple Intelligence to evaluate")
            continue
        }
        if let translation = await engine.translate(goal: goal) {
            if let compiled = TranslationPolicy.command(from: translation) {
                print("[translate]  “\(utterance)” → \(compiled)")
            } else {
                print("[loop]       “\(utterance)” → \(translation.intent) → visual loop")
            }
        } else {
            print("[loop]       “\(utterance)” → translation failed → visual loop")
        }
    }
}

/// The commands this architecture exists to get right — the simple-operations
/// class first (must all be [grammar]), then free-form ones that exercise the
/// translation stage, then genuinely visual ones that belong to the loop.
private let defaultEvalCorpus = [
    // Simple operations: deterministic, zero model.
    "open discord dot com in Chrome",
    "open discord dot com",
    "go to github dot com slash anthropics",
    "go to linked in dot com",
    "open discord in chrome",
    "search for sloth videos in firefox",
    "open safari",
    "switch to notes",
    "close the window",
    "press command shift t",
    // Free-form: one translation round, then deterministic execution.
    "take me to wikipedia",
    "pull up the apple store page",
    "get rid of this app",
    // Visual: the loop's legitimate work.
    "click sign in",
    "open notes and start a new note",
    "make the text bigger",
]
