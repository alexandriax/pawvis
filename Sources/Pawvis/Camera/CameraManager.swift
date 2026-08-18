import AVFoundation
import CoreVideo
import Foundation

/// Owns the AVCaptureSession and delivers frames to the hand tracker on a
/// dedicated queue. 720p to match the tracking quality sporecaster targets;
/// Vision is comfortable at this size on Apple Silicon.
final class CameraManager: NSObject, AVCaptureVideoDataOutputSampleBufferDelegate {
    private let session = AVCaptureSession()
    private let output = AVCaptureVideoDataOutput()
    let frameQueue = DispatchQueue(label: "com.pawvis.camera.frames", qos: .userInteractive)

    /// Called on `frameQueue` for every captured frame.
    var onFrame: ((CMSampleBuffer) -> Void)?
    /// Called on the main queue when the running state changes.
    var onRunningChanged: ((Bool) -> Void)?

    private(set) var isRunning = false
    private var currentDeviceID: String?

    static func availableCameras() -> [(id: String, name: String)] {
        let discovery = AVCaptureDevice.DiscoverySession(
            deviceTypes: [.builtInWideAngleCamera, .external, .continuityCamera],
            mediaType: .video,
            position: .unspecified)
        return discovery.devices.map { ($0.uniqueID, $0.localizedName) }
    }

    private static func device(withID id: String?) -> AVCaptureDevice? {
        let discovery = AVCaptureDevice.DiscoverySession(
            deviceTypes: [.builtInWideAngleCamera, .external, .continuityCamera],
            mediaType: .video,
            position: .unspecified)
        if let id, let match = discovery.devices.first(where: { $0.uniqueID == id }) {
            return match
        }
        // Prefer the built-in camera (it faces the user), then anything.
        return discovery.devices.first(where: { $0.deviceType == .builtInWideAngleCamera })
            ?? discovery.devices.first
    }

    func start(deviceID: String?) {
        frameQueue.async { [self] in
            configureIfNeeded(deviceID: deviceID)
            guard !session.isRunning else { return }
            session.startRunning()
            isRunning = session.isRunning
            let running = isRunning
            DispatchQueue.main.async { self.onRunningChanged?(running) }
            Log.camera.info("Camera started: \(running)")
        }
    }

    func stop() {
        frameQueue.async { [self] in
            guard session.isRunning else { return }
            session.stopRunning()
            isRunning = false
            DispatchQueue.main.async { self.onRunningChanged?(false) }
            Log.camera.info("Camera stopped")
        }
    }

    /// Switch camera without tearing down the pipeline (no-op if unchanged).
    func setDevice(deviceID: String?) {
        frameQueue.async { [self] in
            guard deviceID != currentDeviceID else { return }
            currentDeviceID = deviceID
            guard session.isRunning else {
                // Stopped: configureIfNeeded's early-return only skips work
                // when session.inputs is non-empty, so a bare currentDeviceID
                // update isn't enough — it'd leave the old camera's input in
                // place and the next start(deviceID:) would resume on it.
                // Drop the stale input now so start reconfigures onto the
                // newly recorded device instead.
                session.beginConfiguration()
                for input in session.inputs { session.removeInput(input) }
                session.commitConfiguration()
                return
            }
            configureIfNeeded(deviceID: deviceID, force: true)
        }
    }

    private func configureIfNeeded(deviceID: String?, force: Bool = false) {
        if !force, !session.inputs.isEmpty, deviceID == currentDeviceID { return }
        currentDeviceID = deviceID

        // Center Stage pans/zooms the field of view as people move and can
        // override frame-duration locks — both poison gesture mapping. Opt out.
        if AVCaptureDevice.centerStageControlMode != .app {
            AVCaptureDevice.centerStageControlMode = .app
            AVCaptureDevice.isCenterStageEnabled = false
        }

        session.beginConfiguration()
        defer { session.commitConfiguration() }

        for input in session.inputs { session.removeInput(input) }

        guard let device = Self.device(withID: deviceID) else {
            Log.camera.error("No camera device available")
            return
        }
        do {
            let input = try AVCaptureDeviceInput(device: device)
            guard session.canAddInput(input) else {
                Log.camera.error("Cannot add camera input")
                return
            }
            session.addInput(input)
        } catch {
            Log.camera.error("Camera input error: \(error.localizedDescription)")
            return
        }

        if session.canSetSessionPreset(.hd1280x720) {
            session.sessionPreset = .hd1280x720
        }

        lockFrameRate(device)

        if !session.outputs.contains(output) {
            // Prefer the sensor's native biplanar YUV: requesting BGRA forces
            // AVFoundation to color-convert every frame before Vision sees it,
            // and nothing else in the app consumes these buffers.
            let native = kCVPixelFormatType_420YpCbCr8BiPlanarFullRange
            let format = output.availableVideoPixelFormatTypes.contains(native)
                ? native : kCVPixelFormatType_32BGRA
            output.videoSettings = [
                kCVPixelBufferPixelFormatTypeKey as String: format,
            ]
            output.alwaysDiscardsLateVideoFrames = true
            output.setSampleBufferDelegate(self, queue: frameQueue)
            if session.canAddOutput(output) {
                session.addOutput(output)
            }
        }
        Log.camera.info("Camera configured: \(device.localizedName, privacy: .public)")
    }

    /// Pin capture to a steady 30 fps. Left free-running, auto-exposure
    /// silently lengthens frame durations in dim light — motion blur on a
    /// moving hand, plus an irregular cadence that feeds phantom velocity
    /// into the One Euro filters downstream.
    private func lockFrameRate(_ device: AVCaptureDevice) {
        let target = CMTime(value: 1, timescale: 30)
        guard device.activeFormat.videoSupportedFrameRateRanges.contains(where: {
            $0.minFrameDuration <= target && target <= $0.maxFrameDuration
        }) else { return }
        do {
            try device.lockForConfiguration()
            device.activeVideoMinFrameDuration = target
            device.activeVideoMaxFrameDuration = target
            device.unlockForConfiguration()
        } catch {
            Log.camera.error("Frame-rate lock failed: \(error.localizedDescription)")
        }
    }

    func captureOutput(
        _ output: AVCaptureOutput,
        didOutput sampleBuffer: CMSampleBuffer,
        from connection: AVCaptureConnection
    ) {
        onFrame?(sampleBuffer)
    }

    /// A live preview layer on the running session, for the trainer window.
    /// Unmirrored and aspect-fit — the trainer flips its whole preview
    /// stack (video and landmark dots together) into mirror view, so the
    /// two can never disagree about handedness.
    func makePreviewLayer() -> AVCaptureVideoPreviewLayer {
        let layer = AVCaptureVideoPreviewLayer(session: session)
        layer.videoGravity = .resizeAspect
        if let connection = layer.connection {
            connection.automaticallyAdjustsVideoMirroring = false
            connection.isVideoMirrored = false
        }
        return layer
    }
}
