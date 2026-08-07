import Foundation
import FoundationModels

/// Second opinion for utterances the strict wake gate rejected but whose
/// opening chunks *nearly* match the wake word (the parser's near tier,
/// edit distance ≤ 2). The garble boundary and the remainder are found
/// deterministically; the on-device model answers exactly one question —
/// does the remainder read as an instruction to a computer, or as a
/// fragment of ordinary conversation the near tier misfired on?
///
/// Live-probed (20/20 over two runs): "open my email" / "scroll down" /
/// "pressed the enter key" → instruction; "open at nine" / "are my
/// favorite shoes" / "said she'd call back" → fragment. Earlier designs
/// that showed the model the garbled wake word, or asked it to extract
/// the command, flip-flopped between prompts — the 3B model is only
/// reliable on the enum-typed classification, so the code keeps every
/// other job (matches the code-guard pattern in IntentMapper).
@available(macOS 26.0, *)
@MainActor
enum WakeRescuer {
    static var isSupported: Bool {
        SystemLanguageModel.default.availability == .available
    }

    @Generable
    enum Reading: String, CaseIterable {
        case instruction
        case conversationFragment
    }

    @Generable
    struct Verdict {
        @Guide(description: "instruction when the words tell a computer to do something; conversationFragment when they read as a piece of ordinary human speech instead.")
        var reading: Reading
    }

    private static let instructions = """
        You hear a short phrase captured right after a Mac voice \
        assistant's wake word. Usually it is a command for the Mac — but \
        sometimes the wake-word detector misfired on ordinary \
        conversation, and the phrase is just a fragment of whatever was \
        being said.

        - instruction: the phrase tells the computer to do something — \
        "open my email", "type hello there", "scroll down", "go to reddit \
        dot com", "close this window", "make this window bigger", "stop \
        listening". Speech recognition garbles words — a verb may arrive \
        past-tense ("pressed the enter key" is a garbled "press the enter \
        key", an instruction); read charitably.
        - conversationFragment: the phrase reads as a piece of a human \
        sentence, not an order to a machine — "open at nine", "are my \
        favorite shoes", "was late again yesterday".
        """

    // MARK: - Session lifecycle (same pattern as IntentMapper)

    private static var session: LanguageModelSession?
    private static var sessionUses = 0
    private static let maxSessionUses = 20

    static func prewarm() {
        guard isSupported else { return }
        _ = activeSession(forceFresh: false)
    }

    private static func activeSession(forceFresh: Bool) -> LanguageModelSession {
        if !forceFresh, let session, sessionUses < maxSessionUses {
            return session
        }
        let fresh = LanguageModelSession(instructions: instructions)
        fresh.prewarm()
        session = fresh
        sessionUses = 0
        return fresh
    }

    // MARK: - Confirmation

    /// True when the near-wake remainder reads as an instruction — the
    /// caller then hands the *deterministic* remainder to the agent,
    /// verbatim; the model never rewrites the command.
    static func confirmsInstruction(_ phrase: String) async throws -> Bool {
        let prompt = "Phrase: “\(phrase)”"
        do {
            let session = activeSession(forceFresh: false)
            sessionUses += 1
            let verdict = try await session.respond(
                to: prompt, generating: Verdict.self,
                options: GenerationOptions(sampling: .greedy)).content
            return verdict.reading == .instruction
        } catch {
            // One retry on a fresh session (covers a filled-up transcript
            // window mid-session).
            let fresh = activeSession(forceFresh: true)
            sessionUses += 1
            let verdict = try await fresh.respond(
                to: prompt, generating: Verdict.self,
                options: GenerationOptions(sampling: .greedy)).content
            return verdict.reading == .instruction
        }
    }
}
