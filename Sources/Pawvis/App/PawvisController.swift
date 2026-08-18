import AppKit
import AVFoundation
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
    private let actionRunner = GestureActionRunner()
    /// A fired custom gesture's confirmation, shown in the status pill until
    /// its frame-time deadline (the pill is otherwise voice control's).
    private var gestureNotice: (text: String, until: TimeInterval)?
    private var projector: ScreenProjector
    private var cancellables: Set<AnyCancellable> = []

    init(settingsStore: SettingsStore) {
        self.settingsStore = settingsStore
        let settings = settingsStore.settings
        engine = GestureEngine(config: settings.gestures)
        projector = ScreenProjector(controlAllDisplays: settings.general.controlAllDisplays)
        mouse = MouseController(projector: projector)
        actionRunner.stopTracking = { [weak self] in self?.stopTracking() }
        actionRunner.toggleVoiceControl = { [weak self] in self?.voice.toggle() }
        actionRunner.onFollowUp = { [weak self] outcome in
            guard let self else { return }
            self.gestureNotice = (text: "🐾 \(outcome)",
                                  until: CACurrentMediaTime() + Self.gestureNoticeSeconds)
        }

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

    // MARK: - Gesture training

    /// While the trainer window is open, camera frames bypass the engine
    /// entirely — no cursor, no clicks, no gesture fires. Training must not
    /// fight the very motions it is recording.
    @Published private(set) var trainingActive = false
    /// The trainer's frame feed, called on the main actor with camera-space
    /// hands and the frame timestamp.
    var trainingFrameTap: (([Hand], TimeInterval) -> Void)?
    private var trainingHadTracking = false

    func beginTraining() {
        guard !trainingActive else { return }
        trainingHadTracking = trackingActive
        trainingActive = true
        if trackingActive {
            // Let go of anything in flight and hide the overlay; the camera
            // keeps running, now feeding only the trainer.
            mouse.apply(engine.forceRelease(at: CACurrentMediaTime()))
            mouse.releaseAllButtons()
            engine.reset()
            overlay.hide()
        } else {
            // Camera only — same permission flow as tracking, no overlay,
            // no engine.
            switch Permissions.camera() {
            case .granted:
                camera.start(deviceID: settingsStore.settings.general.cameraDeviceID)
            case .notDetermined:
                Task { [weak self] in
                    let granted = await Permissions.requestCamera()
                    guard let self else { return }
                    self.cameraPermission = Permissions.camera()
                    if granted, self.trainingActive {
                        self.camera.start(deviceID: self.settingsStore.settings.general.cameraDeviceID)
                    }
                }
            case .denied:
                cameraPermission = .denied
                lastError = "Camera access denied — enable it in System Settings → Privacy"
            }
        }
        Log.app.info("Gesture training started (tracking was \(self.trainingHadTracking))")
    }

    func endTraining() {
        guard trainingActive else { return }
        trainingActive = false
        trainingFrameTap = nil
        if trainingHadTracking {
            engine.reset() // a fresh start, not the pre-training leftovers
            overlay.show()
        } else {
            camera.stop()
        }
        Log.app.info("Gesture training ended")
    }

    /// The trainer window's camera view attaches here.
    func makeTrainingPreviewLayer() -> AVCaptureVideoPreviewLayer {
        camera.makePreviewLayer()
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
        if trainingActive {
            // The trainer owns the stream; nothing reaches the engine or
            // the mouse while its window is open.
            trainingFrameTap?(hands, time)
            return
        }
        guard trackingActive else { return }
        var (events, overlayState) = engine.process(HandFrame(time: time, hands: hands))

        // Fired custom gestures are commands for this controller, not mouse
        // events: peel them off and run their bound actions.
        for event in events {
            if case .customGesture(let gesture) = event {
                performCustomGesture(gesture, at: time)
            }
            if case .trainedGesture(let id) = event {
                performTrainedGesture(id, at: time)
            }
        }
        events.removeAll {
            switch $0 {
            case .customGesture, .trainedGesture: return true
            default: return false
            }
        }

        // A hold pose mid-dwell paints a live countdown into the pill: a
        // pose you must hold for a beat is invisible until it fires, and
        // invisible reads as broken. Re-set every frame; the short TTL
        // clears it the moment the pose is dropped. (A fire this same
        // frame already cleared the dwell, so its notice stands.)
        if let holding = engine.customHoldProgress {
            gestureNotice = (
                text: String(format: "🐾 %@ · hold… %.1f s",
                             holding.gesture.displayName, holding.remaining),
                until: time + 0.4)
        }
        // Trained gestures with a hold-to-confirm get the same countdown:
        // "recognized, keep going" is the difference between a gesture that
        // feels alive and one that seems ignored.
        if let holding = engine.trainedHoldProgress,
           let gesture = settingsStore.settings.trainedGestures.gesture(withID: holding.id) {
            gestureNotice = (
                text: String(format: "🐾 %@ · hold… %.1f s", gesture.name, holding.remaining),
                until: time + 0.4)
        }

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
            voice: hudLine(at: time),
            projector: projector,
            accessibilityBlocked: !accessibilityGranted,
            diagnostics: diagnosticsLine(hands: hands, at: time))

        let count = overlayState.hands.count
        if count != handsDetected { handsDetected = count }
        let anyGrab = overlayState.grabbed || overlayState.rightGrabbed
        if anyGrab != grabbing { grabbing = anyGrab }
        if overlayState.armed != controlArmed { controlArmed = overlayState.armed }
    }

    // MARK: - Custom gestures

    /// How long a fired gesture's confirmation stays in the pill.
    private static let gestureNoticeSeconds: TimeInterval = 2.5

    private func performCustomGesture(_ gesture: CustomGesture, at time: TimeInterval) {
        guard let action = settingsStore.settings.customGestures.action(for: gesture) else { return }
        let feedback = actionRunner.perform(action)
        Log.app.info("Custom gesture \(gesture.rawValue): \(feedback)")
        gestureNotice = (text: "🐾 \(feedback)", until: time + Self.gestureNoticeSeconds)
    }

    private func performTrainedGesture(_ id: UUID, at time: TimeInterval) {
        guard settingsStore.settings.customGestures.enabled,
              let gesture = settingsStore.settings.trainedGestures.gesture(withID: id),
              let action = gesture.action else { return }
        let feedback = actionRunner.perform(action)
        Log.app.info("Trained gesture \(gesture.name, privacy: .public): \(feedback)")
        gestureNotice = (text: "🐾 \(gesture.name): \(feedback)",
                         until: time + Self.gestureNoticeSeconds)
    }

    /// Voice control owns the pill; a fired gesture borrows it only while
    /// voice has nothing to say.
    private func hudLine(at time: TimeInterval) -> VoiceHUD {
        let voiceHUD = voice.hud
        if case .hidden = voiceHUD, let notice = gestureNotice {
            if time < notice.until { return .notice(notice.text) }
            gestureNotice = nil
        }
        return voiceHUD
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
        engine.customConfig = settings.customGestures.detectorConfig()
        // Trained gestures share the custom library's master switch.
        engine.trainedConfig = settings.trainedGestures.detectorConfig(
            enabled: settings.customGestures.enabled)
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
