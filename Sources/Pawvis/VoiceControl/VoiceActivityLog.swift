import Foundation
import PawvisCore

/// A rolling record of the voice pipeline's decisions — wake verdicts, parsed
/// commands, routing, steps and outcomes — for the "Recent activity" pane in
/// Settings → Voice.
///
/// Two properties are load-bearing:
///
/// - **In memory only.** Voice transcripts are sensitive, so nothing here is
///   ever written to disk; the log is capped at `cap` entries and vanishes
///   when Pawvis quits. Copy puts it on the clipboard deliberately.
/// - **Speech that failed the wake gate is counted, never quoted.** Ambient
///   conversation the recognizer happened to transcribe must not end up in a
///   log pane; utterances without the wake word only ever increment
///   `ignoredCount`. Entries may quote speech only once it has passed the
///   wake gate (including an AI-confirmed near-miss rescue, which is a pass).
///
/// The formatting/cap logic stays deliberately trivial: this is app-layer
/// observable state with no app-target test suite, so it is verified by the
/// build and by eyes on the pane, not by unit tests.
@MainActor
final class VoiceActivityLog: ObservableObject {
    struct Entry: Identifiable {
        enum Kind {
            /// Wake-word verdicts: accepted (with tier), capture window,
            /// near-miss rescued or refused.
            case wake
            /// A parsed or translated command (deterministic verb).
            case command
            /// Routing: translation round, autopilot loop, agent hand-off,
            /// deterministic sequence.
            case route
            /// One step of a sequence or autopilot run.
            case step
            /// A finished command: success, or "Stopped".
            case outcome
            /// A finished command that failed, or a pipeline error.
            case failure
            /// Bookends and context (listening started/stopped).
            case info

            /// Fixed-width column tag for the monospaced list.
            var tag: String {
                switch self {
                case .wake: return "wake "
                case .command: return "cmd  "
                case .route: return "route"
                case .step: return "step "
                case .outcome: return "ok   "
                case .failure: return "fail "
                case .info: return "info "
                }
            }
        }

        let id = UUID()
        let time: Date
        let kind: Kind
        let text: String
    }

    static let shared = VoiceActivityLog()

    /// Oldest first, capped at `cap`.
    @Published private(set) var entries: [Entry] = []
    /// Utterances that never passed the wake gate. The aggregate count is all
    /// the log keeps of them — their words are never stored.
    @Published private(set) var ignoredCount = 0

    static let cap = 200

    func append(_ kind: Entry.Kind, _ text: String) {
        entries.append(Entry(time: Date(), kind: kind, text: text))
        if entries.count > Self.cap {
            entries.removeFirst(entries.count - Self.cap)
        }
    }

    /// One more utterance ignored for lacking the wake word.
    func countIgnored() {
        ignoredCount += 1
    }

    func clear() {
        entries.removeAll()
        ignoredCount = 0
    }

    var ignoredSummary: String {
        "\(ignoredCount) utterance\(ignoredCount == 1 ? "" : "s") ignored without the wake word (words never recorded)"
    }

    /// The whole log as plain text, oldest first, for pasting into a bug
    /// report.
    var plainText: String {
        var lines = entries.map {
            "\(Self.timestamp.string(from: $0.time))  \($0.kind.tag) \($0.text)"
        }
        if ignoredCount > 0 { lines.append(ignoredSummary) }
        return lines.joined(separator: "\n")
    }

    static let timestamp: DateFormatter = {
        let f = DateFormatter()
        f.dateFormat = "HH:mm:ss"
        return f
    }()

    /// Short deterministic-verb description of a parsed command for the log.
    static func describe(_ command: VoiceCommand) -> String {
        switch command {
        case .mediaKey:
            return "media play-pause"
        case .sequence(let steps):
            return "sequence of \(steps.count) steps"
        case .goTo(let url, let app):
            return "go to \(url)" + (app.map { " in \($0)" } ?? "")
        case .webSearch(let query, let app):
            return "web search “\(query)”" + (app.map { " in \($0)" } ?? "")
        case .press(let chord):
            let modifiers = chord.modifiers.map(\.rawValue).sorted().joined(separator: " ")
            return "press " + (modifiers.isEmpty ? chord.key : "\(modifiers) \(chord.key)")
        case .open(let app):
            return "open \(app)"
        case .switchTo(let app):
            return "switch to \(app)"
        case .click(let kind):
            return "\(kind.rawValue) click"
        case .scroll(let direction, let amount):
            return "scroll \(direction.rawValue) (\(amount.rawValue))"
        case .quit(let app):
            return "quit \(app ?? "the frontmost app")"
        case .stopVoiceControl:
            return "stop listening"
        case .cancelActivity:
            return "stop"
        case .resolve(let transcript):
            return "free-form: “\(transcript)”"
        }
    }
}
