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

/// Execution eval (`Pawvis --voice-exec "<utterance>" …`): parses each
/// utterance and EXECUTES it for real — the same CommandExecutor the voice
/// path uses, posting real keystrokes and activations, with each step's
/// outcome printed. This is the layer the other evals can't reach: parsing
/// can be right while keystroke delivery is wrong, and only a real
/// execution shows it. Deterministic commands only (grammar output); the
/// model paths are excluded on purpose. Requires explicit utterances —
/// there is no default corpus for a tool that controls the machine.
func runVoiceExec(_ utterances: [String]) -> Int32 {
    guard !utterances.isEmpty else {
        print("Usage: Pawvis --voice-exec \"open chrome and go to youtube dot com\" …")
        print("Executes the parsed commands FOR REAL (keystrokes, activations).")
        return 2
    }
    var finished = false
    var failures = 0
    Task { @MainActor in
        let parser = VoiceControlParser()
        let executor = CommandExecutor()
        let typer = TextTyper()
        for utterance in utterances {
            let result = parser.parseRemainder(utterance)
            if !result.typing.isEmpty {
                print("[exec] “\(utterance)” → typing \(result.typing)")
                typer.perform(result.typing)
                continue
            }
            guard let command = result.command else {
                print("[skip] “\(utterance)” → no action")
                continue
            }
            if case .resolve = command {
                print("[skip] “\(utterance)” → needs the model ladder; not executed here")
                continue
            }
            let steps: [VoiceCommand]
            if case .sequence(let members) = command {
                steps = members
            } else {
                steps = [command]
            }
            print("[plan] “\(utterance)” → \(steps.count) step(s)")
            for (index, step) in steps.enumerated() {
                let outcome = await executor.execute(step)
                switch outcome {
                case .done(let notice):
                    print("  step \(index + 1): ✓ \(notice ?? String(describing: step))")
                    if let unmet = await executor.sequenceSettle(after: step) {
                        print("  step \(index + 1): ✗ didn't take — \(unmet)")
                        failures += 1
                        break
                    }
                case .failed(let message):
                    print("  step \(index + 1): ✗ \(message)")
                    failures += 1
                }
                if case .failed = outcome { break }
            }
        }
        finished = true
    }
    let deadline = Date().addingTimeInterval(120)
    while !finished, Date() < deadline {
        RunLoop.main.run(mode: .default, before: Date().addingTimeInterval(0.05))
    }
    if !finished {
        print("TIMED OUT")
        return 1
    }
    return failures == 0 ? 0 : 1
}

/// Wake-word eval (`Pawvis --wake-eval "<full transcript>" …`): shows, tier
/// by tier, what the wake matcher does with a transcript AS THE RECOGNIZER
/// WROTE IT — paste mis-hearings from the log or from the capsule to see
/// why an utterance was accepted or dropped, and to test new aliases.
/// Pure string matching, instant, no model.
func runWakeEval(_ transcripts: [String]) -> Int32 {
    let corpus = transcripts.isEmpty ? defaultWakeCorpus : transcripts
    let parser = VoiceControlParser()
    print("Wake-word eval — wake “\(parser.config.wakeWord)”, aliases \(parser.config.wakeWordAliases)\n")
    for transcript in corpus {
        if let remainder = parser.wakeRemainder(transcript) {
            let how = parser.wakeMatch(in: transcript, tolerance: 1)?.trusted == true
                ? "strict" : "glued+deterministic"
            print("[wake:\(how)]  “\(transcript)” → command “\(remainder)”")
        } else if let near = parser.nearWakeRemainder(transcript) {
            print("[near]        “\(transcript)” → “\(near)” (needs AI confirmation, or a live-delta match)")
        } else {
            print("[ambient]     “\(transcript)” → ignored")
        }
    }
    print("\nTiers: strict = acted on directly; near = acted on after on-device AI")
    print("confirms it reads as an instruction (or when the live hypothesis had")
    print("already matched the wake word); ambient = never acted on.")
    return 0
}

private let defaultWakeCorpus = [
    "Pawvis open Safari",
    "Um, Pawvis, open Safari",
    "Paw vis go to github.com",
    "Paw this open Safari",
    "Pavis type hello",
    "anyway whatever Pawvis open Safari",
    "she said Pawvis was busy",
    "Pause the video",
    "open safari",
]

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
    // Composites: every clause parses on its own → a verified sequence.
    "open chrome and go to youtube dot com",
    "pause this, open up a new tab, and go to youtube dot com",
    "select all and copy",
    // Free-form: one translation round, then deterministic execution.
    "take me to wikipedia",
    "pull up the apple store page",
    "get rid of this app",
    // Visual: the loop's legitimate work.
    "click sign in",
    "open notes and start a new note",
    "make the text bigger",
]
