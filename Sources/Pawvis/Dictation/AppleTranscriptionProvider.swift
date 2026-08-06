import AVFoundation
import Foundation
import PawvisCore
import Speech

/// On-device transcription via Apple's Speech framework — no network, no API
/// key. This baseline implementation uses SFSpeechRecognizer with on-device
/// recognition and silence-based utterance segmentation: SFSpeech reports one
/// continuously-growing transcript, so when it stops growing for a quiet
/// interval we finalize the utterance and restart the recognition task (which
/// also sidesteps the framework's ~1-minute task limit).
final class AppleTranscriptionProvider: NSObject, TranscriptionProvider {
    var onEvent: ((TranscriptionEvent) -> Void)?

    private let engine = AVAudioEngine()
    private var recognizer: SFSpeechRecognizer?
    private var request: SFSpeechAudioBufferRecognitionRequest?
    private var task: SFSpeechRecognitionTask?

    private let config: DictationConfig
    private var stopped = true
    private var itemCounter = 0
    private var currentItemId = "apple-0"
    private var currentPartial = ""
    private var emittedForItem = ""
    private var silenceTimer: Timer?
    /// Quiet time after the last transcript growth before we finalize.
    private var utteranceSilence: TimeInterval {
        max(0.6, Double(config.vadSilenceMs) / 1000 + 0.2)
    }

    init(config: DictationConfig) {
        self.config = config
        super.init()
    }

    func start() {
        stopped = false
        let locale = config.language.isEmpty
            ? Locale.current
            : Locale(identifier: config.language)

        SFSpeechRecognizer.requestAuthorization { [weak self] status in
            DispatchQueue.main.async {
                guard let self, !self.stopped else { return }
                guard status == .authorized else {
                    self.fail("Speech recognition not authorized — enable in System Settings → Privacy")
                    return
                }
                self.beginRecognition(locale: locale)
            }
        }
    }

    func stop() {
        stopped = true
        silenceTimer?.invalidate()
        silenceTimer = nil
        task?.cancel()
        task = nil
        request?.endAudio()
        request = nil
        if engine.isRunning {
            engine.inputNode.removeTap(onBus: 0)
            engine.stop()
        }
        recognizer = nil
    }

    private func beginRecognition(locale: Locale) {
        guard let recognizer = SFSpeechRecognizer(locale: locale) ?? SFSpeechRecognizer() else {
            fail("Speech recognition unavailable for this language")
            return
        }
        guard recognizer.isAvailable else {
            fail("Speech recognition is currently unavailable")
            return
        }
        self.recognizer = recognizer

        do {
            try startAudioIfNeeded()
        } catch {
            fail("Microphone error: \(error.localizedDescription)")
            return
        }

        startRecognitionTask()
        onEvent?(.ready)
        Log.dictation.info("Apple on-device dictation started (locale \(locale.identifier, privacy: .public), onDevice: \(recognizer.supportsOnDeviceRecognition))")
    }

    private func startAudioIfNeeded() throws {
        guard !engine.isRunning else { return }
        let input = engine.inputNode
        let format = input.outputFormat(forBus: 0)
        guard format.sampleRate > 0 else {
            throw NSError(domain: "Pawvis", code: 2,
                          userInfo: [NSLocalizedDescriptionKey: "No microphone input available"])
        }
        input.installTap(onBus: 0, bufferSize: 2048, format: format) { [weak self] buffer, _ in
            self?.request?.append(buffer)
        }
        engine.prepare()
        try engine.start()
    }

    /// One recognition task per utterance; restarted after each finalization.
    private func startRecognitionTask() {
        guard let recognizer, !stopped else { return }

        let request = SFSpeechAudioBufferRecognitionRequest()
        request.shouldReportPartialResults = true
        if recognizer.supportsOnDeviceRecognition {
            request.requiresOnDeviceRecognition = true
        }
        request.taskHint = .dictation
        self.request = request

        itemCounter += 1
        currentItemId = "apple-\(itemCounter)"
        currentPartial = ""
        emittedForItem = ""

        var newTask: SFSpeechRecognitionTask?
        newTask = recognizer.recognitionTask(with: request) { [weak self] result, error in
            DispatchQueue.main.async {
                guard let self, self.task === newTask else { return } // drop stale callbacks
                self.handleResult(result, error: error)
            }
        }
        task = newTask
    }

    private func handleResult(_ result: SFSpeechRecognitionResult?, error: Error?) {
        guard !stopped else { return }

        if let result {
            let text = result.bestTranscription.formattedString
            if text != currentPartial {
                currentPartial = text
                emitDeltaIfGrown()
                armSilenceTimer()
            }
            if result.isFinal {
                finalizeUtterance(restart: true)
                return
            }
        }

        if let error = error as NSError? {
            // "No speech detected" and cancellation churn are routine; restart
            // quietly. kAFAssistantErrorDomain 216 = task was cancelled.
            let benign = error.domain == "kAFAssistantErrorDomain" || error.code == 216
                || error.domain == "SFSpeechErrorDomain"
            if !currentPartial.isEmpty {
                finalizeUtterance(restart: true)
            } else if benign {
                restartSoon()
            } else {
                fail("Speech recognition error: \(error.localizedDescription)")
            }
        }
    }

    private func emitDeltaIfGrown() {
        guard currentPartial.hasPrefix(emittedForItem) else {
            // The hypothesis was revised backwards; hold deltas and let the
            // final transcript reconcile (the parser handles revisions).
            return
        }
        let delta = String(currentPartial.dropFirst(emittedForItem.count))
        guard !delta.isEmpty else { return }
        emittedForItem = currentPartial
        onEvent?(.delta(itemId: currentItemId, text: delta))
    }

    private func armSilenceTimer() {
        silenceTimer?.invalidate()
        silenceTimer = Timer.scheduledTimer(
            withTimeInterval: utteranceSilence, repeats: false
        ) { [weak self] _ in
            Task { @MainActor in
                self?.finalizeUtterance(restart: true)
            }
        }
    }

    private func finalizeUtterance(restart: Bool) {
        silenceTimer?.invalidate()
        silenceTimer = nil
        let transcript = currentPartial.trimmingCharacters(in: .whitespacesAndNewlines)
        let itemId = currentItemId

        task?.cancel()
        task = nil
        request?.endAudio()
        request = nil

        if !transcript.isEmpty {
            onEvent?(.completed(itemId: itemId, transcript: transcript))
        }
        currentPartial = ""
        emittedForItem = ""

        if restart, !stopped {
            startRecognitionTask()
        }
    }

    private func restartSoon() {
        guard !stopped else { return }
        task?.cancel()
        task = nil
        request = nil
        DispatchQueue.main.asyncAfter(deadline: .now() + 0.25) { [weak self] in
            guard let self, !self.stopped, self.task == nil else { return }
            self.startRecognitionTask()
        }
    }

    private func fail(_ message: String) {
        stop()
        onEvent?(.failed(message))
    }
}
