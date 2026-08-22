import AVFoundation
import CoreVideo
import Foundation
import PawvisCore

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
    /// Called on the main queue when a *running* session is about to be
    /// reconfigured in place — a settings device switch, the disconnect
    /// fallback, the chosen camera returning. Frames pause for the swap and
    /// the new device warms up, but `isRunning` never flips, so
    /// `onRunningChanged` stays silent: any frame-stall clock must re-arm
    /// from this hook instead.
    var onWillReconfigure: (() -> Void)?
    /// Called on the main queue when capture dies underneath us — a session
    /// runtime error, or the active device unplugged — with a human-readable
    /// reason. Frames may never arrive again; the caller owns saying so.
    var onFailure: ((String) -> Void)?
    /// Called on the main queue when the system interrupts capture (another
    /// app claimed the device, …) with a reason, and again with nil when the
    /// interruption ends.
    var onInterruption: ((String?) -> Void)?

    private(set) var isRunning = false
    /// The persisted pick (`general.cameraDeviceID`); nil is Automatic. What
    /// actually feeds the session is `activeInputDeviceID()`.
    private var currentDeviceID: String?
    private var observers: [NSObjectProtocol] = []

    override init() {
        super.init()
        observeCaptureLifecycle()
    }

    deinit {
        observers.forEach { NotificationCenter.default.removeObserver($0) }
    }

    // MARK: - Discovery and selection

    /// Every camera macOS will let us capture from, in discovery order.
    /// Continuity Cameras (an iPhone offered as a webcam, over a cable or
    /// not) are typed `.continuityCamera` only because the bundle opts in
    /// with `NSCameraUseContinuityCameraDeviceType`: without that key macOS
    /// still lists the phone, but as `.external` (measured on macOS 26; the
    /// header says `.builtInWideAngleCamera` for 14), which is what made
    /// "prefer the built-in camera" a coin toss between the Mac and the
    /// phone. Desk View is left out on purpose: it points at the desk.
    static func discover() -> [AVCaptureDevice] {
        AVCaptureDevice.DiscoverySession(
            deviceTypes: [.builtInWideAngleCamera, .external, .continuityCamera],
            mediaType: .video,
            position: .unspecified).devices
    }

    static func kind(of device: AVCaptureDevice) -> CameraSelectionPolicy.Kind {
        switch device.deviceType {
        case .builtInWideAngleCamera: return .builtIn
        case .continuityCamera: return .continuity
        default: return .other
        }
    }

    private static func candidates(_ devices: [AVCaptureDevice]) -> [CameraSelectionPolicy.Candidate] {
        devices.map { CameraSelectionPolicy.Candidate(id: $0.uniqueID, kind: kind(of: $0)) }
    }

    static func availableCameras() -> [(id: String, name: String)] {
        discover().map { ($0.uniqueID, $0.localizedName) }
    }

    /// The camera `CameraSelectionPolicy` lands on for `pick` right now: the
    /// pick itself while present, else the built-in camera, else the first
    /// camera at all. Never an iPhone or a webcam unasked — Pawvis does not
    /// switch cameras on its own. Every configure path asks this, so the
    /// rule lives in one tested place.
    static func chosenDevice(forPick pick: String?) -> AVCaptureDevice? {
        let devices = discover()
        let choice = CameraSelectionPolicy.choose(pick: pick, available: candidates(devices))
        return devices.first { $0.uniqueID == choice }
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
            DispatchQueue.main.async { self.onWillReconfigure?() }
            configureIfNeeded(deviceID: deviceID, force: true)
        }
    }

    // MARK: - Failure, interruption, disconnect

    /// The session dying is not an event AVFoundation surfaces through the
    /// frame path: frames just stop, silently. These observers are the only
    /// honest signal that the camera was unplugged, claimed by another app,
    /// or hit a runtime error — without them a drag in progress stays held
    /// system-wide with nobody left to release it.
    private func observeCaptureLifecycle() {
        let center = NotificationCenter.default
        observers.append(center.addObserver(
            forName: AVCaptureSession.runtimeErrorNotification,
            object: session, queue: nil
        ) { [weak self] note in self?.handleRuntimeError(note) })
        observers.append(center.addObserver(
            forName: AVCaptureSession.wasInterruptedNotification,
            object: session, queue: nil
        ) { [weak self] note in self?.handleInterruption(began: true, note: note) })
        observers.append(center.addObserver(
            forName: AVCaptureSession.interruptionEndedNotification,
            object: session, queue: nil
        ) { [weak self] note in self?.handleInterruption(began: false, note: note) })
        // Device notifications carry the device as the object and are not
        // session-scoped: filter to our active input in the handler.
        observers.append(center.addObserver(
            forName: AVCaptureDevice.wasDisconnectedNotification,
            object: nil, queue: nil
        ) { [weak self] note in self?.handleDeviceDisconnected(note) })
        observers.append(center.addObserver(
            forName: AVCaptureDevice.wasConnectedNotification,
            object: nil, queue: nil
        ) { [weak self] note in self?.handleDeviceConnected(note) })
    }

    private func handleRuntimeError(_ note: Notification) {
        let error = note.userInfo?[AVCaptureSessionErrorKey] as? AVError
        let description = error?.localizedDescription ?? "unknown error"
        Log.camera.error("Capture session runtime error: \(description, privacy: .public)")
        // No blind restart here: on macOS a runtime error is not one of the
        // documented-recoverable kinds, and a failed startRunning can post
        // another runtime error — a loop. Recovery comes from the device
        // reconnect handler, wake, interruption end, or the user's toggle.
        frameQueue.async { [self] in
            guard isRunning else { return }
            isRunning = session.isRunning
            let running = isRunning
            DispatchQueue.main.async {
                self.onRunningChanged?(running)
                self.onFailure?("Camera error: \(description)")
            }
        }
    }

    private func handleInterruption(began: Bool, note: Notification) {
        guard began else {
            Log.camera.info("Capture interruption ended")
            DispatchQueue.main.async { self.onInterruption?(nil) }
            return
        }
        // macOS doesn't expose the interruption reason (the key is iOS-only),
        // so say what is knowable: capture paused and it wasn't us.
        let reason = "Camera interrupted — another app may have taken it"
        Log.camera.error("Capture interrupted")
        DispatchQueue.main.async { self.onInterruption?(reason) }
    }

    /// The active camera vanished (unplugged, Continuity Camera walked away).
    /// Reconfigure around it: the selection rule already falls back to the
    /// built-in camera, then anything — and the report says honestly which
    /// of those happened.
    private func handleDeviceDisconnected(_ note: Notification) {
        guard let device = note.object as? AVCaptureDevice else { return }
        let goneID = device.uniqueID
        let goneName = device.localizedName
        frameQueue.async { [self] in
            guard activeInputDeviceID() == goneID else { return }
            Log.camera.error("Camera disconnected: \(goneName, privacy: .public)")
            if isRunning {
                DispatchQueue.main.async { self.onWillReconfigure?() }
            }
            // Reconfigure even while stopped: AVFoundation leaves the dead
            // device's input attached, and a later start would ride it into
            // a session that can never produce a frame.
            configureIfNeeded(deviceID: currentDeviceID, force: true)
            guard isRunning else { return }
            let fallback = session.inputs
                .compactMap { ($0 as? AVCaptureDeviceInput)?.device.localizedName }
                .first
            DispatchQueue.main.async {
                if let fallback {
                    self.onFailure?("\(goneName) disconnected — switching to \(fallback)")
                } else {
                    self.onFailure?("\(goneName) disconnected — no other camera found")
                }
            }
        }
    }

    /// A camera appeared: the one we lost came back, or the user's pick
    /// returned while we ride a fallback. The selection rule decides; a
    /// device that leaves the verdict unchanged (a virtual camera
    /// registering itself, an iPhone coming into range) must not touch the
    /// session — Pawvis never switches cameras on its own.
    private func handleDeviceConnected(_ note: Notification) {
        guard let device = note.object as? AVCaptureDevice,
              device.hasMediaType(.video) else { return }
        reconcileDevice(reason: "\(device.localizedName) connected")
    }

    /// Re-run the selection rule against what is present now, and
    /// reconfigure only if it lands somewhere other than the camera feeding
    /// the session, which is what keeps the session from thrashing on
    /// events that leave the verdict alone. While stopped (the lock screen,
    /// tracking off) the stale input is dropped instead, so the next `start`
    /// configures onto the new verdict rather than resuming the old camera:
    /// a pick that reconnected behind the lock screen must be the camera
    /// after unlock.
    private func reconcileDevice(reason: String) {
        frameQueue.async { [self] in
            let wanted = Self.chosenDevice(forPick: currentDeviceID)?.uniqueID
            guard wanted != activeInputDeviceID() else { return }
            guard isRunning else {
                session.beginConfiguration()
                for input in session.inputs { session.removeInput(input) }
                session.commitConfiguration()
                return
            }
            Log.camera.info("Camera reconfiguring: \(reason, privacy: .public)")
            DispatchQueue.main.async { self.onWillReconfigure?() }
            configureIfNeeded(deviceID: currentDeviceID, force: true)
        }
    }

    /// Unique ID of the device currently feeding the session (frameQueue only).
    private func activeInputDeviceID() -> String? {
        session.inputs
            .compactMap { ($0 as? AVCaptureDeviceInput)?.device.uniqueID }
            .first
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

        guard let device = Self.chosenDevice(forPick: deviceID) else {
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
