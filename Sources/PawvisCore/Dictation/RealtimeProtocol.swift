import Foundation

/// Encoding/decoding for the OpenAI Realtime API used in transcription-only
/// mode (GA interface, August 2026: connect to wss://api.openai.com/v1/realtime
/// with just an Authorization header — the beta `OpenAI-Beta: realtime=v1`
/// header and `?intent=transcription` query param are gone — then immediately
/// send `session.update` with `session.type: "transcription"`).
public enum RealtimeProtocol {

    public static let websocketURL = URL(string: "wss://api.openai.com/v1/realtime")!

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
            "turn_detection": [
                "type": "server_vad",
                "threshold": 0.5,
                "prefix_padding_ms": 300,
                "silence_duration_ms": config.vadSilenceMs,
            ],
        ]
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
