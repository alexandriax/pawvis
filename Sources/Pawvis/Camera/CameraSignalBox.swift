import AVFoundation
import CoreVideo
import Foundation
import PawvisCore

/// The camera-queue face of the pure `CameraSignalMonitor`, in the same
/// shape as `FrameThrottleBox` and `AttentionGateBox`: the state machine
/// under one lock, fed at the camera tap.
///
/// It answers one question — is the feed black? — which the monitor decides
/// from mean luminance. Reading luminance is cheap but not free, so it is
/// sampled one frame in `stride` (the darkness it detects lasts seconds, so
/// a few Hz is ample), and the reading itself walks a coarse grid of the
/// luma plane rather than every pixel.
///
/// This runs *before* the idle throttle and the attention gate at the tap:
/// a black feed has no hands (so the throttle would skip it) and no face (so
/// the gate would skip it), which is exactly when the user most needs to be
/// told the camera sees nothing. Its cost is bounded by the stride
/// regardless.
final class CameraSignalBox: @unchecked Sendable {
    /// Sample luminance one frame in this many (~6 Hz of the locked 30 fps).
    static let stride = 5

    private let lock = NSLock()
    private var monitor = CameraSignalMonitor()
    private var sinceSample = 0

    /// Feed one frame. Returns the current dark verdict and whether it just
    /// changed, or nil on the frames between samples (nothing to report).
    /// The caller reads the pixel buffer's luminance only when due.
    func assess(_ sampleBuffer: CMSampleBuffer, at time: TimeInterval) -> (dark: Bool, changed: Bool)? {
        lock.lock()
        sinceSample += 1
        guard sinceSample >= Self.stride else { lock.unlock(); return nil }
        sinceSample = 0
        lock.unlock()

        let luma = Self.meanLuma(of: sampleBuffer)

        lock.lock()
        defer { lock.unlock() }
        let before = monitor.isDark
        let dark = monitor.sample(luma: luma, at: time)
        return (dark, dark != before)
    }

    /// A new session or a device switch: forget the dark history so the next
    /// dark run is timed from scratch and nothing stale is reported.
    func reset() {
        lock.lock(); defer { lock.unlock() }
        monitor.reset()
        sinceSample = 0
    }

    var isDark: Bool {
        lock.lock(); defer { lock.unlock() }
        return monitor.isDark
    }

    /// Mean luminance (0…255) over a coarse grid, or -1 when the buffer can't
    /// be read (the monitor treats that as "hold the verdict"). Handles the
    /// biplanar YUV the app requests (luma is plane 0, one byte per pixel)
    /// and the BGRA fallback (sample one channel — brightness, not color, is
    /// all that matters here).
    static func meanLuma(of sampleBuffer: CMSampleBuffer) -> Double {
        guard let pixel = CMSampleBufferGetImageBuffer(sampleBuffer) else { return -1 }
        CVPixelBufferLockBaseAddress(pixel, .readOnly)
        defer { CVPixelBufferUnlockBaseAddress(pixel, .readOnly) }

        let planar = CVPixelBufferIsPlanar(pixel)
        guard let base = planar
            ? CVPixelBufferGetBaseAddressOfPlane(pixel, 0)
            : CVPixelBufferGetBaseAddress(pixel) else { return -1 }
        let bytesPerRow = planar
            ? CVPixelBufferGetBytesPerRowOfPlane(pixel, 0)
            : CVPixelBufferGetBytesPerRow(pixel)
        let width = planar ? CVPixelBufferGetWidthOfPlane(pixel, 0) : CVPixelBufferGetWidth(pixel)
        let height = planar ? CVPixelBufferGetHeightOfPlane(pixel, 0) : CVPixelBufferGetHeight(pixel)
        guard width > 0, height > 0 else { return -1 }
        // Biplanar/2vuy luma is one byte per pixel; BGRA is four, so step by
        // the pixel size and read the first channel of each sampled pixel.
        let pixelStride = planar ? 1 : 4
        let ptr = base.assumingMemoryBound(to: UInt8.self)

        var sum = 0.0, count = 0.0
        for y in Swift.stride(from: 0, to: height, by: 16) {
            let row = y * bytesPerRow
            for x in Swift.stride(from: 0, to: width, by: 16) {
                sum += Double(ptr[row + x * pixelStride])
                count += 1
            }
        }
        return count > 0 ? sum / count : -1
    }
}
