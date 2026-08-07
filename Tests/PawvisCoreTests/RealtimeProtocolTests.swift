import XCTest
@testable import PawvisCore

final class RealtimeProtocolTests: XCTestCase {

    private func json(_ data: Data) -> [String: Any] {
        (try? JSONSerialization.jsonObject(with: data) as? [String: Any]) ?? [:]
    }

    // MARK: - Client events

    func testSessionUpdateShapeForLiveTranscribe() throws {
        let config = RealtimeProtocol.TranscriptionSessionConfig(
            model: "gpt-live-transcribe", language: "en", prompt: "Pawvis dictation",
            vadSilenceMs: 600, noiseReduction: "far_field")
        let obj = json(try RealtimeProtocol.sessionUpdateEvent(config: config))

        XCTAssertEqual(obj["type"] as? String, "session.update")
        let session = obj["session"] as! [String: Any]
        XCTAssertEqual(session["type"] as? String, "transcription")

        let input = (session["audio"] as! [String: Any])["input"] as! [String: Any]
        let format = input["format"] as! [String: Any]
        XCTAssertEqual(format["type"] as? String, "audio/pcm")
        XCTAssertEqual(format["rate"] as? Int, 24000)

        let transcription = input["transcription"] as! [String: Any]
        XCTAssertEqual(transcription["model"] as? String, "gpt-live-transcribe")
        // gpt-live-transcribe takes `languages` (array), not `language`.
        XCTAssertEqual(transcription["languages"] as? [String], ["en"])
        XCTAssertNil(transcription["language"])
        XCTAssertEqual(transcription["prompt"] as? String, "Pawvis dictation")

        // Live-verified: gpt-live-transcribe REJECTS turn_detection — the
        // session.update must omit it entirely.
        XCTAssertNil(input["turn_detection"])

        let nr = input["noise_reduction"] as! [String: Any]
        XCTAssertEqual(nr["type"] as? String, "far_field")
    }

    func testSessionUpdateIncludesVADForCapableModels() throws {
        let config = RealtimeProtocol.TranscriptionSessionConfig(
            model: "gpt-4o-transcribe", vadSilenceMs: 600)
        let obj = json(try RealtimeProtocol.sessionUpdateEvent(config: config))
        let session = obj["session"] as! [String: Any]
        let input = (session["audio"] as! [String: Any])["input"] as! [String: Any]
        let vad = input["turn_detection"] as! [String: Any]
        XCTAssertEqual(vad["type"] as? String, "server_vad")
        XCTAssertEqual(vad["silence_duration_ms"] as? Int, 600)
    }

    func testServerVADSupportMatrix() {
        func supports(_ model: String) -> Bool {
            RealtimeProtocol.TranscriptionSessionConfig(model: model).supportsServerVAD
        }
        XCTAssertFalse(supports("gpt-live-transcribe"))
        XCTAssertFalse(supports("gpt-realtime-whisper"))
        XCTAssertTrue(supports("gpt-transcribe"), "gpt-transcribe accepts VAD despite using the languages array")
        XCTAssertTrue(supports("gpt-4o-transcribe"))
        XCTAssertTrue(supports("whisper-1"))
    }

    func testCommitEvent() throws {
        let obj = json(try RealtimeProtocol.commitEvent())
        XCTAssertEqual(obj["type"] as? String, "input_audio_buffer.commit")
    }

    func testWebsocketURLCarriesTranscriptionIntent() {
        // Live-verified: without ?intent=transcription the server errors
        // missing_model and closes with code 4000.
        XCTAssertEqual(RealtimeProtocol.websocketURL.query, "intent=transcription")
    }

    func testSessionUpdateUsesSingularLanguageForOlderModels() throws {
        let config = RealtimeProtocol.TranscriptionSessionConfig(
            model: "gpt-4o-transcribe", language: "de")
        let obj = json(try RealtimeProtocol.sessionUpdateEvent(config: config))
        let session = obj["session"] as! [String: Any]
        let input = (session["audio"] as! [String: Any])["input"] as! [String: Any]
        let transcription = input["transcription"] as! [String: Any]
        XCTAssertEqual(transcription["language"] as? String, "de")
        XCTAssertNil(transcription["languages"])
    }

    func testSessionUpdateOmitsEmptyOptionals() throws {
        let config = RealtimeProtocol.TranscriptionSessionConfig(
            model: "whisper-1", language: "", prompt: "", noiseReduction: "")
        let obj = json(try RealtimeProtocol.sessionUpdateEvent(config: config))
        let session = obj["session"] as! [String: Any]
        let input = (session["audio"] as! [String: Any])["input"] as! [String: Any]
        let transcription = input["transcription"] as! [String: Any]
        XCTAssertNil(transcription["language"])
        XCTAssertNil(transcription["languages"])
        XCTAssertNil(transcription["prompt"])
        XCTAssertNil(input["noise_reduction"])
    }

    func testAudioAppendEvent() throws {
        let obj = json(try RealtimeProtocol.audioAppendEvent(base64Audio: "AAAA"))
        XCTAssertEqual(obj["type"] as? String, "input_audio_buffer.append")
        XCTAssertEqual(obj["audio"] as? String, "AAAA")
    }

    // MARK: - Server events (payloads match the documented GA schema)

    private func decode(_ jsonString: String) -> RealtimeProtocol.ServerEvent? {
        RealtimeProtocol.ServerEvent.decode(Data(jsonString.utf8))
    }

    func testDecodeDelta() {
        let event = decode(#"""
        {"type":"conversation.item.input_audio_transcription.delta",
         "event_id":"event_001","item_id":"item_003","content_index":0,"delta":"Hello,"}
        """#)
        XCTAssertEqual(event, .transcriptDelta(itemId: "item_003", delta: "Hello,"))
    }

    func testDecodeCompleted() {
        let event = decode(#"""
        {"type":"conversation.item.input_audio_transcription.completed",
         "event_id":"event_002","item_id":"item_003","content_index":0,
         "transcript":"Hello, how are you?",
         "usage":{"type":"duration","seconds":2}}
        """#)
        XCTAssertEqual(event, .transcriptCompleted(itemId: "item_003", transcript: "Hello, how are you?"))
    }

    func testDecodeFailed() {
        let event = decode(#"""
        {"type":"conversation.item.input_audio_transcription.failed","item_id":"item_9",
         "content_index":0,"error":{"type":"transcription_error","code":"audio_unintelligible",
         "message":"The audio could not be transcribed."}}
        """#)
        XCTAssertEqual(event, .transcriptFailed(itemId: "item_9", message: "The audio could not be transcribed."))
    }

    func testDecodeError() {
        let event = decode(#"""
        {"type":"error","event_id":"event_890",
         "error":{"type":"invalid_request_error","code":"invalid_api_key",
         "message":"Incorrect API key provided.","param":null}}
        """#)
        XCTAssertEqual(event, .error(code: "invalid_api_key", message: "Incorrect API key provided."))
    }

    func testDecodeLifecycleEvents() {
        XCTAssertEqual(decode(#"{"type":"session.created","session":{}}"#), .sessionCreated)
        XCTAssertEqual(decode(#"{"type":"session.updated","session":{}}"#), .sessionUpdated)
        XCTAssertEqual(
            decode(#"{"type":"input_audio_buffer.speech_started","audio_start_ms":120,"item_id":"i"}"#),
            .speechStarted)
        XCTAssertEqual(
            decode(#"{"type":"input_audio_buffer.speech_stopped","audio_end_ms":900,"item_id":"i"}"#),
            .speechStopped)
    }

    func testUnknownEventTypesPassThroughAsOther() {
        XCTAssertEqual(decode(#"{"type":"rate_limits.updated","rate_limits":[]}"#),
                       .other(type: "rate_limits.updated"))
        XCTAssertEqual(decode(#"{"type":"conversation.item.added","item":{}}"#),
                       .other(type: "conversation.item.added"))
    }

    func testGarbageReturnsNil() {
        XCTAssertNil(decode("not json at all"))
        XCTAssertNil(decode(#"{"no_type_field":true}"#))
    }
}

final class SettingsTests: XCTestCase {
    func testRoundTrip() throws {
        var settings = PawvisSettings()
        settings.gestures.pinchEngageRatio = 0.22
        settings.gestures.doubleClickSlop = 0.03
        settings.dictation.wakeWords = ["computer"]
        settings.overlay.showPinchRing = false
        settings.general.controlAllDisplays = true

        let data = try JSONEncoder().encode(settings)
        let decoded = try JSONDecoder().decode(PawvisSettings.self, from: data)
        XCTAssertEqual(decoded, settings)
    }

    func testDecodeFromEmptyObjectYieldsDefaults() throws {
        let decoded = try JSONDecoder().decode(PawvisSettings.self, from: Data("{}".utf8))
        XCTAssertEqual(decoded, PawvisSettings.default)
    }

    func testPartialSectionKeepsOtherDefaults() throws {
        let jsonData = Data(#"{"gestures":{"pinchEngageRatio":0.25}}"#.utf8)
        let decoded = try JSONDecoder().decode(PawvisSettings.self, from: jsonData)
        XCTAssertEqual(decoded.gestures.pinchEngageRatio, 0.25)
        XCTAssertEqual(decoded.gestures.pinchReleaseRatio, 0.68, "unspecified fields keep defaults")
        XCTAssertEqual(decoded.dictation, DictationConfig())
    }

    func testMistypedFieldFallsBackToDefault() throws {
        let jsonData = Data(#"{"dictation":{"wakeWords":"not-an-array","model":"whisper-1"}}"#.utf8)
        let decoded = try JSONDecoder().decode(PawvisSettings.self, from: jsonData)
        XCTAssertEqual(decoded.dictation.model, "whisper-1")
        XCTAssertEqual(decoded.dictation.wakeWords, DictationConfig().wakeWords)
    }

    func testRetiredGestureKeysAreIgnored() throws {
        // Settings written by earlier gesture models (fist-grab/scroll/dictation
        // gestures) must decode cleanly, with unknown keys simply dropped.
        let jsonData = Data(#"""
        {"gestures":{"grabCloseThreshold":0.18,"grabOpenThreshold":0.38,"rightClickFinger":"ring",
         "dictationToggle":"shakaHold","scrollGainPixels":900,
         "pointerSource":"palmCenter","pinchEngageRatio":0.2}}
        """#.utf8)
        let decoded = try JSONDecoder().decode(PawvisSettings.self, from: jsonData)
        XCTAssertEqual(decoded.gestures.pinchEngageRatio, 0.2)
        XCTAssertEqual(decoded.gestures.pinchReleaseRatio, 0.68)
    }
}
