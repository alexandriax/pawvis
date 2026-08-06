import AVFoundation
import CoreMedia
import Foundation
import Speech

/// Streaming AVAudioPCMBuffer format converter for the speech model's input
/// format (16 kHz Int16 mono — the mic's native 48 kHz Float32 never matches).
/// Sample-rate conversion requires AVAudioConverter's block-based API.
final class SpeechBufferConverter {
    private var converter: AVAudioConverter?

    func convert(_ buffer: AVAudioPCMBuffer, to format: AVAudioFormat) throws -> AVAudioPCMBuffer {
        let inputFormat = buffer.format
        guard inputFormat != format else { return buffer }

        if converter == nil || converter?.outputFormat != format {
            converter = AVAudioConverter(from: inputFormat, to: format)
            converter?.primeMethod = .none
        }
        guard let converter else {
            throw NSError(domain: "Pawvis", code: 3,
                          userInfo: [NSLocalizedDescriptionKey: "Cannot convert microphone audio"])
        }

        let ratio = converter.outputFormat.sampleRate / converter.inputFormat.sampleRate
        let capacity = AVAudioFrameCount((Double(buffer.frameLength) * ratio).rounded(.up))
        guard let out = AVAudioPCMBuffer(pcmFormat: converter.outputFormat, frameCapacity: capacity) else {
            throw NSError(domain: "Pawvis", code: 4,
                          userInfo: [NSLocalizedDescriptionKey: "Cannot allocate conversion buffer"])
        }

        var nsError: NSError?
        // The input block runs synchronously on this thread; the Sendable
        // annotation on the block type is bridging boilerplate.
        nonisolated(unsafe) var fed = false
        let status = converter.convert(to: out, error: &nsError) { _, inputStatus in
            defer { fed = true }
            inputStatus.pointee = fed ? .noDataNow : .haveData
            return fed ? nil : buffer
        }
        guard status != .error else {
            throw nsError ?? NSError(domain: "Pawvis", code: 5,
                                     userInfo: [NSLocalizedDescriptionKey: "Audio conversion failed"])
        }
        return out
    }
}

/// macOS 26+ on-device transcription via SpeechAnalyzer/SpeechTranscriber.
/// Unlike SFSpeechRecognizer this needs no speech-recognition authorization
/// (nothing leaves the device — only the mic permission applies), and it
/// produces properly segmented results: volatile hypotheses that revise in
/// place, and per-segment finalized transcripts.
@available(macOS 26.0, *)
final class ModernAppleSpeechBackend: @unchecked Sendable {
    /// Delivered on the main queue.
    var onEvent: ((TranscriptionEvent) -> Void)?

    private let engine = AVAudioEngine()
    private let converter = SpeechBufferConverter()
    private var analyzer: SpeechAnalyzer?
    private var transcriber: SpeechTranscriber?
    private var inputContinuation: AsyncStream<AnalyzerInput>.Continuation?
    private var analyzerFormat: AVAudioFormat?
    private var resultsTask: Task<Void, Never>?
    private var stopped = false

    // Segment bookkeeping (touched only from the results task + setup).
    private var segmentCounter = 0
    private var emittedForSegment = ""

    private let preferredLanguage: String

    init(language: String) {
        self.preferredLanguage = language
    }

    func start() {
        stopped = false
        Task { [weak self] in
            await self?.run()
        }
    }

    func stop() {
        stopped = true
        if engine.isRunning {
            engine.inputNode.removeTap(onBus: 0)
            engine.stop()
        }
        inputContinuation?.finish()
        inputContinuation = nil
        resultsTask?.cancel()
        resultsTask = nil
        let analyzer = self.analyzer
        self.analyzer = nil
        Task {
            await analyzer?.cancelAndFinishNow()
        }
    }

    private func run() async {
        let requested = preferredLanguage.isEmpty
            ? Locale.current
            : Locale(identifier: preferredLanguage)
        guard let locale = await SpeechTranscriber.supportedLocale(equivalentTo: requested) else {
            fail("On-device speech doesn't support “\(requested.identifier)”")
            return
        }

        // Volatile hypotheses + fast results ≈ the progressive-transcription preset.
        let transcriber = SpeechTranscriber(
            locale: locale,
            transcriptionOptions: [],
            reportingOptions: [.volatileResults, .fastResults],
            attributeOptions: [])
        self.transcriber = transcriber

        // supportedLocale(equivalentTo:) can resolve locales the module can't
        // actually run; the module-level status is authoritative. Assets are
        // shared system-wide and may be evicted, so check every session.
        let status = await AssetInventory.status(forModules: [transcriber])
        if status == .unsupported {
            fail("On-device speech doesn't support “\(locale.identifier)”")
            return
        }
        do {
            if let request = try await AssetInventory.assetInstallationRequest(supporting: [transcriber]) {
                Log.dictation.info("Downloading on-device speech model for \(locale.identifier, privacy: .public)…")
                try await request.downloadAndInstall()
            }
        } catch {
            fail("Speech model download failed: \(error.localizedDescription)")
            return
        }
        guard !stopped else { return }

        let analyzer = SpeechAnalyzer(modules: [transcriber])
        self.analyzer = analyzer
        let format = await SpeechAnalyzer.bestAvailableAudioFormat(compatibleWith: [transcriber])
        self.analyzerFormat = format

        do {
            try await analyzer.prepareToAnalyze(in: format)
        } catch {
            fail("Speech engine failed to prepare: \(error.localizedDescription)")
            return
        }
        guard !stopped else { return }

        let (stream, continuation) = AsyncStream<AnalyzerInput>.makeStream()
        inputContinuation = continuation

        resultsTask = Task { [weak self] in
            guard let transcriber = self?.transcriber else { return }
            do {
                for try await result in transcriber.results {
                    self?.handleResult(text: String(result.text.characters), isFinal: result.isFinal)
                }
            } catch {
                guard let self, !self.stopped else { return }
                self.fail("Speech engine stopped: \(error.localizedDescription)")
            }
        }

        do {
            try startMicTap()
            try await analyzer.start(inputSequence: stream)
        } catch {
            fail("Speech engine failed to start: \(error.localizedDescription)")
            return
        }
        guard !stopped else { return }

        emit(.ready)
        Log.dictation.info("Apple SpeechAnalyzer dictation started (locale \(locale.identifier, privacy: .public))")
    }

    private func startMicTap() throws {
        let input = engine.inputNode
        let native = input.outputFormat(forBus: 0)
        guard native.sampleRate > 0 else {
            throw NSError(domain: "Pawvis", code: 2,
                          userInfo: [NSLocalizedDescriptionKey: "No microphone input available"])
        }
        input.installTap(onBus: 0, bufferSize: 4096, format: native) { [weak self] buffer, _ in
            guard let self, !self.stopped,
                  let format = self.analyzerFormat,
                  let continuation = self.inputContinuation else { return }
            if let converted = try? self.converter.convert(buffer, to: format) {
                continuation.yield(AnalyzerInput(buffer: converted))
            }
        }
        engine.prepare()
        try engine.start()
    }

    /// Volatile results replace the in-flight hypothesis; finalized results
    /// close out a segment. Map onto the provider's delta/completed events:
    /// emit grown suffixes as deltas, hold on backward revisions (the final
    /// transcript reconciles via the parser), and bump the segment id on final.
    private func handleResult(text: String, isFinal: Bool) {
        let itemId = "apple-seg-\(segmentCounter)"
        if isFinal {
            let transcript = text.trimmingCharacters(in: .whitespacesAndNewlines)
            emittedForSegment = ""
            segmentCounter += 1
            if !transcript.isEmpty {
                emit(.completed(itemId: itemId, transcript: transcript))
            }
        } else {
            if text.hasPrefix(emittedForSegment) {
                let delta = String(text.dropFirst(emittedForSegment.count))
                if !delta.isEmpty {
                    emittedForSegment = text
                    emit(.delta(itemId: itemId, text: delta))
                }
            }
            // else: hypothesis revised backwards — wait for the final.
        }
    }

    private func fail(_ message: String) {
        guard !stopped else { return }
        stop()
        DispatchQueue.main.async { [weak self] in
            self?.onEvent?(.failed(message))
        }
    }

    private func emit(_ event: TranscriptionEvent) {
        DispatchQueue.main.async { [weak self] in
            guard let self, !self.stopped else { return }
            self.onEvent?(event)
        }
    }
}
