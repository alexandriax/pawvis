import Foundation

/// The agent's self-reported outcome: the last `DONE:`/`FAILED:` line of its
/// output, which becomes the user-facing flash message.
public enum AgentVerdict: Equatable, Sendable {
    case done(String)
    case failed(String)
    case none

    public static func extract(from text: String) -> AgentVerdict {
        let lines = text
            .split(separator: "\n", omittingEmptySubsequences: true)
            .map { $0.trimmingCharacters(in: .whitespaces) }
        guard let verdict = lines.last(where: {
            $0.hasPrefix("DONE:") || $0.hasPrefix("FAILED:")
        }) else { return .none }
        if verdict.hasPrefix("DONE:") {
            return .done(verdict.dropFirst("DONE:".count)
                .trimmingCharacters(in: .whitespaces))
        }
        return .failed(verdict.dropFirst("FAILED:".count)
            .trimmingCharacters(in: .whitespaces))
    }
}

/// Turns one line of agent CLI output into lines fit for the live activity
/// panel, plus the final result payload when the line carries one.
///
/// Claude Code runs with `--output-format stream-json --verbose` (probe-
/// verified against v2.1.216): one JSON object per line — `assistant`
/// messages as turns complete, then a `result` object whose `result` string
/// is the reply the DONE:/FAILED: verdict lives in. Codex streams plain
/// progress lines, which pass through untouched.
public enum AgentStreamParser {
    public struct LineOutput: Equatable, Sendable {
        /// Human-readable lines to append to the live output tail.
        public var display: [String] = []
        /// The run's final reply, when this line is the `result` object.
        public var resultText: String?
        /// `is_error` from the result object.
        public var resultIsError: Bool?

        public init(display: [String] = [], resultText: String? = nil,
                    resultIsError: Bool? = nil) {
            self.display = display
            self.resultText = resultText
            self.resultIsError = resultIsError
        }
    }

    /// Parse one line of `claude --output-format stream-json` output.
    /// Lines that aren't JSON (startup warnings and the like) pass through.
    public static func claudeLine(_ line: String) -> LineOutput {
        let trimmed = line.trimmingCharacters(in: .whitespaces)
        guard !trimmed.isEmpty else { return LineOutput() }
        guard trimmed.hasPrefix("{"),
              let data = trimmed.data(using: .utf8),
              let object = (try? JSONSerialization.jsonObject(with: data)) as? [String: Any]
        else {
            return LineOutput(display: [trimmed])
        }

        switch object["type"] as? String {
        case "assistant":
            guard let message = object["message"] as? [String: Any],
                  let content = message["content"] as? [[String: Any]] else {
                return LineOutput()
            }
            var display: [String] = []
            for block in content {
                switch block["type"] as? String {
                case "text":
                    let text = (block["text"] as? String ?? "")
                    display.append(contentsOf: text
                        .split(separator: "\n", omittingEmptySubsequences: true)
                        .map(String.init))
                case "tool_use":
                    if let name = block["name"] as? String {
                        display.append("▸ \(name)")
                    }
                default:
                    break
                }
            }
            return LineOutput(display: display)

        case "result":
            return LineOutput(
                display: [],
                resultText: object["result"] as? String,
                resultIsError: object["is_error"] as? Bool)

        default:
            // init/system/rate-limit chatter — not worth panel space.
            return LineOutput()
        }
    }
}
