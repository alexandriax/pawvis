import AppKit
import Combine
import Foundation
import PawvisCore
import QuartzCore

/// The top-level coordinator: camera frames → Vision hand tracking → gesture
/// engine → mouse/keyboard + overlay, plus voice control and settings propagation.
@MainActor
final class PawvisController: ObservableObject {
    let settingsStore: SettingsStore
    let voice = VoiceController()

    @Published private(set) var trackingActive = false
    @Published private(set) var handsDetected = 0
    @Published private(set) var grabbing = false
    /// False while a tracked hand is waiting on the control trigger (the
    /// open-hand gesture) before it may move the cursor.
    @Published private(set) var controlArmed = true
    @Published private(set) var cameraPermission = Permissions.camera()
    @Published private(set) var accessibilityGranted = Permissions.accessibility() == .granted
    @Published private(set) var lastError: String?

    private let camera = CameraManager()
    private let tracking = HandTrackingService()
    private let engine: GestureEngine
    private let mouse: MouseController
    private let overlay = OverlayController()
    private var projector: ScreenProjector
    private var cancellables: Set<AnyCancellable> = []

    init(settingsStore: SettingsStore) {
        self.settingsStore = settingsStore
        let settings = settingsStore.settings
        engine = GestureEngine(config: settings.gestures)
        projector = ScreenProjector(controlAllDisplays: settings.general.controlAllDisplays)
        mouse = MouseController(projector: projector)

        camera.onFrame = { [weak self] sampleBuffer in
            guard let self else { return }
            // Camera queue: run Vision synchronously, then hop to main.
            // DispatchQueue.main (not Task) — the main queue is FIFO, so
            // down/drag/up frame batches can never arrive reordered.
            let hands = self.tracking.detectHands(in: sampleBuffer)
            let time = CACurrentMediaTime()
            DispatchQueue.main.async {
                MainActor.assumeIsolated {
                    self.processFrame(hands: hands, at: time)
                }
            }
        }

        settingsStore.$settings
            .removeDuplicates()
            .sink { [weak self] newSettings in
                self?.apply(settings: newSettings)
            }
            .store(in: &cancellables)

        apply(settings: settings)

        NotificationCenter.default.addObserver(
            forName: NSApplication.didChangeScreenParametersNotification,
            object: nil, queue: .main
        ) { [weak self] _ in
            Task { @MainActor in self?.refreshProjector() }
        }
    }

    // MARK: - Lifecycle

    func startTracking() {
        guard !trackingActive else { return }
        lastError = nil

        switch Permissions.camera() {
        case .denied:
            cameraPermission = .denied
            lastError = "Camera access denied — enable it in System Settings → Privacy"
            return
        case .notDetermined:
            Task { [weak self] in
                let granted = await Permissions.requestCamera()
                guard let self else { return }
                self.cameraPermission = Permissions.camera()
                if granted { self.startTracking() }
            }
            return
        case .granted:
            cameraPermission = .granted
        }

        if Permissions.accessibility() != .granted {
            // Tracking still runs (overlay works); clicks silently no-op until
            // granted, so surface the prompt and a warning in the menu.
            Permissions.promptAccessibility()
        }
        refreshPermissions()

        engine.reset()
        refreshProjector()
        overlay.show()
        camera.start(deviceID: settingsStore.settings.general.cameraDeviceID)
        trackingActive = true
        startPermissionPolling()
        Log.app.info("Tracking started")
    }

    /// While tracking, re-check Accessibility every couple of seconds so the
    /// overlay warning appears/disappears without reopening the menu (the
    /// grant can silently stop applying after a rebuild).
    private var permissionPollTimer: Timer?

    private func startPermissionPolling() {
        permissionPollTimer?.invalidate()
        permissionPollTimer = Timer.scheduledTimer(withTimeInterval: 2, repeats: true) { [weak self] _ in
            Task { @MainActor in self?.refreshPermissions() }
        }
    }

    func stopTracking() {
        guard trackingActive else { return }
        camera.stop()
        mouse.apply(engine.forceRelease(at: CACurrentMediaTime()))
        mouse.releaseAllButtons()
        overlay.hide()
        trackingActive = false
        handsDetected = 0
        grabbing = false
        controlArmed = true
        permissionPollTimer?.invalidate()
        permissionPollTimer = nil
        Log.app.info("Tracking stopped")
    }

    func toggleTracking() {
        trackingActive ? stopTracking() : startTracking()
    }

    /// Called when the app is quitting: never leave a button stuck down.
    func shutdown() {
        stopTracking()
        voice.stop()
    }

    func refreshPermissions() {
        cameraPermission = Permissions.camera()
        accessibilityGranted = Permissions.accessibility() == .granted
    }

    // MARK: - Frame pipeline

    private func processFrame(hands: [Hand], at time: TimeInterval) {
        guard trackingActive else { return }
        let (events, overlayState) = engine.process(HandFrame(time: time, hands: hands))

        // The criss-cross wave completed: deliver everything else this frame
        // produced (a queued release must still land), then stop tracking
        // outright — the same full stop as the menu bar switch.
        if events.contains(.disableTracking) {
            mouse.apply(events.filter { $0 != .disableTracking })
            Log.app.info("Tracking stopped by the criss-cross wave")
            stopTracking()
            return
        }

        mouse.apply(events)
        overlay.render(
            overlay: overlayState,
            voice: voice.hud,
            projector: projector,
            accessibilityBlocked: !accessibilityGranted,
            diagnostics: diagnosticsLine(hands: hands, at: time))

        let count = overlayState.hands.count
        if count != handsDetected { handsDetected = count }
        let anyGrab = overlayState.grabbed || overlayState.rightGrabbed
        if anyGrab != grabbing { grabbing = anyGrab }
        if overlayState.armed != controlArmed { controlArmed = overlayState.armed }
    }

    // MARK: - Tracking diagnostics

    private var frameTimes: [TimeInterval] = []

    /// One compact line of live tracking numbers, for diagnosing flaky
    /// detection: fps · hands · pinch ratio · thumb/index tip confidence.
    private func diagnosticsLine(hands: [Hand], at time: TimeInterval) -> String? {
        guard settingsStore.settings.general.showDiagnostics else { return nil }
        frameTimes.append(time)
        if frameTimes.count > 30 { frameTimes.removeFirst(frameTimes.count - 30) }
        let fps: Double = frameTimes.count >= 2
            ? Double(frameTimes.count - 1) / max(frameTimes.last! - frameTimes.first!, 0.001)
            : 0

        guard let hand = hands.max(by: { $0.confidence < $1.confidence }) else {
            return String(format: "🐾 %.0f fps · no hands", fps)
        }
        let thumbConf = hand.confidence(for: .thumbTip)
        let indexConf = hand.confidence(for: .indexTip)
        let ratio = HandFeatures(hand: hand)?.pinchRatio(to: .index)
        let ratioText = ratio.map { String(format: "%.2f", $0) } ?? "—"
        return String(
            format: "🐾 %.0f fps · %d hand%@ · pinch %@ · conf %.2f/%.2f",
            fps, hands.count, hands.count == 1 ? "" : "s", ratioText, thumbConf, indexConf)
    }

    // MARK: - Settings propagation

    private func apply(settings: PawvisSettings) {
        engine.config = settings.gestures
        overlay.setConfig(settings.overlay)
        voice.setConfig(settings.voiceControl)
        voice.transcriptOverlay.showInScreenCapture = settings.overlay.showInScreenCapture
        voice.autopilotPanel.showInScreenCapture = settings.overlay.showInScreenCapture
        AgentSessionManager.shared.showInScreenCapture = settings.overlay.showInScreenCapture
        refreshProjector()
        camera.setDevice(deviceID: settings.general.cameraDeviceID)
    }

    private func refreshProjector() {
        projector = ScreenProjector(
            controlAllDisplays: settingsStore.settings.general.controlAllDisplays)
        mouse.updateProjector(projector)
    }
}
