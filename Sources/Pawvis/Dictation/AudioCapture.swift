import AVFoundation
import Foundation

/// Captures microphone audio and converts it to the Realtime API's required
/// format: 24 kHz, 16-bit signed little-endian PCM, mono.
final class AudioCapture {
    private let engine = AVAudioEngine()
    private var converter: AVAudioConverter?
    private(set) var isRunning = false

    /// ~100 ms chunks: small enough for responsive VAD, large enough to keep
    /// websocket message overhead negligible.
    var onChunk: ((Data) -> Void)?

    private static let outputFormat = AVAudioFormat(
        commonFormat: .pcmFormatInt16,
        sampleRate: 24_000,
        channels: 1,
        interleaved: true)!

    func start() throws {
        guard !isRunning else { return }
        let input = engine.inputNode
        let inputFormat = input.outputFormat(forBus: 0)
        guard inputFormat.sampleRate > 0 else {
            throw NSError(
                domain: "Pawvis", code: 1,
                userInfo: [NSLocalizedDescriptionKey: "No microphone input available"])
        }
        converter = AVAudioConverter(from: inputFormat, to: Self.outputFormat)

        input.installTap(onBus: 0, bufferSize: 4096, format: inputFormat) { [weak self] buffer, _ in
            self?.convertAndDeliver(buffer)
        }
        engine.prepare()
        try engine.start()
        isRunning = true
        Log.dictation.info("Audio capture started (\(inputFormat.sampleRate, privacy: .public) Hz in)")
    }

    func stop() {
        guard isRunning else { return }
        engine.inputNode.removeTap(onBus: 0)
        engine.stop()
        isRunning = false
        Log.dictation.info("Audio capture stopped")
    }

    private func convertAndDeliver(_ buffer: AVAudioPCMBuffer) {
        guard let converter else { return }
        let ratio = Self.outputFormat.sampleRate / buffer.format.sampleRate
        let capacity = AVAudioFrameCount(Double(buffer.frameLength) * ratio + 32)
        guard let out = AVAudioPCMBuffer(pcmFormat: Self.outputFormat, frameCapacity: capacity) else {
            return
        }

        var fed = false
        var error: NSError?
        converter.convert(to: out, error: &error) { _, status in
            if fed {
                status.pointee = .noDataNow
                return nil
            }
            fed = true
            status.pointee = .haveData
            return buffer
        }
        if let error {
            Log.dictation.error("Audio conversion error: \(error.localizedDescription)")
            return
        }
        guard out.frameLength > 0, let channel = out.int16ChannelData?[0] else { return }
        let data = Data(bytes: channel, count: Int(out.frameLength) * MemoryLayout<Int16>.size)
        onChunk?(data)
    }
}
