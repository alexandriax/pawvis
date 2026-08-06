import Foundation

/// Encoding/decoding for the OpenAI Realtime API used in transcription-only
/// mode. Live-verified against the GA API (August 2026):
/// - the `?intent=transcription` query param is REQUIRED (without it the
///   server errors `missing_model` and closes with code 4000)
/// - the beta `OpenAI-Beta: realtime=v1` header must NOT be sent (fatal:
///   `beta_api_shape_disabled`)
/// - auth is `Authorization: Bearer sk-...` with the full key
/// - send `session.update` (session.type "transcription") after
///   `session.created` arrives.
public enum RealtimeProtocol {

    public static let websocketURL = URL(string: "wss://api.openai.com/v1/realtime?intent=transcription")!

    // MARK: - Session configuration (client → server)

    public struct TranscriptionSessionConfig: Equatable, Sendable {
        public var model: String
        /// ISO-639-1 code, empty = auto-detect.
        public var language: String
        public var prompt: String
        /// server_vad silence duration before an utterance is considered done.
        public var vadSilenceMs: Int
        /// "near_field", "far_field", or "" to disable.
        public var noiseReduction: String

        public init(
            model: String = "gpt-live-transcribe",
            language: String = "",
            prompt: String = "",
            vadSilenceMs: Int = 500,
            noiseReduction: String = "near_field"
        ) {
            self.model = model
            self.language = language
            self.prompt = prompt
            self.vadSilenceMs = vadSilenceMs
            self.noiseReduction = noiseReduction
        }

        /// Newer transcribe models take a `languages` array; older ones take a
        /// singular `language`. Sending both is rejected.
        var usesLanguagesArray: Bool {
            model.hasPrefix("gpt-live-transcribe") || model.hasPrefix("gpt-transcribe")
        }

        /// Live-verified: gpt-live-transcribe and gpt-realtime-whisper REJECT
        /// `turn_detection` (session.update fails). Without server VAD the
        /// client must delimit utterances with input_audio_buffer.commit.
        /// (Distinct from `usesLanguagesArray`: gpt-transcribe accepts VAD.)
        public var supportsServerVAD: Bool {
            !(model.hasPrefix("gpt-live-transcribe") || model.hasPrefix("gpt-realtime-whisper"))
        }
    }

    /// Full `session.update` client event JSON.
    public static func sessionUpdateEvent(config: TranscriptionSessionConfig) throws -> Data {
        var transcription: [String: Any] = ["model": config.model]
        if !config.language.isEmpty {
            if config.usesLanguagesArray {
                transcription["languages"] = [config.language]
            } else {
                transcription["language"] = config.language
            }
        }
        if !config.prompt.isEmpty {
            transcription["prompt"] = config.prompt
        }

        var input: [String: Any] = [
            "format": ["type": "audio/pcm", "rate": 24000],
            "transcription": transcription,
        ]
        if config.supportsServerVAD {
            input["turn_detection"] = [
                "type": "server_vad",
                "threshold": 0.5,
                "prefix_padding_ms": 300,
                "silence_duration_ms": config.vadSilenceMs,
            ]
        }
        if !config.noiseReduction.isEmpty {
            input["noise_reduction"] = ["type": config.noiseReduction]
        }

        let event: [String: Any] = [
            "type": "session.update",
            "session": [
                "type": "transcription",
                "audio": ["input": input],
            ],
        ]
        return try JSONSerialization.data(withJSONObject: event, options: [.sortedKeys])
    }

    /// `input_audio_buffer.append` event carrying base64 PCM16 (24 kHz mono LE).
    public static func audioAppendEvent(base64Audio: String) throws -> Data {
        try JSONSerialization.data(
            withJSONObject: ["type": "input_audio_buffer.append", "audio": base64Audio],
            options: [.sortedKeys])
    }

    /// `input_audio_buffer.commit` — finalizes the current utterance. Required
    /// to get `.completed` events from models without server VAD.
    public static func commitEvent() throws -> Data {
        try JSONSerialization.data(
            withJSONObject: ["type": "input_audio_buffer.commit"],
            options: [.sortedKeys])
    }

    // MARK: - Server events (server → client)

    public enum ServerEvent: Equatable, Sendable {
        case sessionCreated
        case sessionUpdated
        case speechStarted
        case speechStopped
        /// Incremental transcript text for an in-progress utterance. Deltas may
        /// revise earlier partials — reconcile by itemId.
        case transcriptDelta(itemId: String, delta: String)
        /// Final transcript for one utterance.
        case transcriptCompleted(itemId: String, transcript: String)
        case transcriptFailed(itemId: String?, message: String)
        case error(code: String?, message: String)
        /// Any event type we don't act on (item.added, committed, rate limits…).
        case other(type: String)

        /// Decode one server event. Returns nil only for non-JSON payloads.
        public static func decode(_ data: Data) -> ServerEvent? {
            guard let obj = try? JSONSerialization.jsonObject(with: data) as? [String: Any],
                  let type = obj["type"] as? String else { return nil }

            switch type {
            case "session.created":
                return .sessionCreated
            case "session.updated":
                return .sessionUpdated
            case "input_audio_buffer.speech_started":
                return .speechStarted
            case "input_audio_buffer.speech_stopped":
                return .speechStopped
            case "conversation.item.input_audio_transcription.delta":
                return .transcriptDelta(
                    itemId: obj["item_id"] as? String ?? "",
                    delta: obj["delta"] as? String ?? "")
            case "conversation.item.input_audio_transcription.completed":
                return .transcriptCompleted(
                    itemId: obj["item_id"] as? String ?? "",
                    transcript: obj["transcript"] as? String ?? "")
            case "conversation.item.input_audio_transcription.failed":
                let err = obj["error"] as? [String: Any]
                return .transcriptFailed(
                    itemId: obj["item_id"] as? String,
                    message: err?["message"] as? String ?? "transcription failed")
            case "error":
                let err = obj["error"] as? [String: Any]
                return .error(
                    code: err?["code"] as? String,
                    message: err?["message"] as? String ?? "unknown realtime error")
            default:
                return .other(type: type)
            }
        }
    }
}
