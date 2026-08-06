import AppKit
import Combine
import Foundation
import PawvisCore
import QuartzCore

/// The top-level coordinator: camera frames → Vision hand tracking → gesture
/// engine → mouse/keyboard + overlay, plus dictation and settings propagation.
@MainActor
final class PawvisController: ObservableObject {
    let settingsStore: SettingsStore
    let dictation = DictationController()

    @Published private(set) var trackingActive = false
    @Published private(set) var handsDetected = 0
    @Published private(set) var mode: InteractionMode = .none
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
            let hands = self.tracking.detectHands(in: sampleBuffer)
            let time = CACurrentMediaTime()
            Task { @MainActor in
                self.processFrame(hands: hands, at: time)
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
        Log.app.info("Tracking started")
    }

    func stopTracking() {
        guard trackingActive else { return }
        camera.stop()
        mouse.apply(engine.forceRelease(at: CACurrentMediaTime()))
        mouse.releaseAllButtons()
        overlay.hide()
        trackingActive = false
        handsDetected = 0
        mode = .none
        Log.app.info("Tracking stopped")
    }

    func toggleTracking() {
        trackingActive ? stopTracking() : startTracking()
    }

    /// Called when the app is quitting: never leave a button stuck down.
    func shutdown() {
        stopTracking()
        dictation.stop()
    }

    func refreshPermissions() {
        cameraPermission = Permissions.camera()
        accessibilityGranted = Permissions.accessibility() == .granted
    }

    // MARK: - Frame pipeline

    private func processFrame(hands: [Hand], at time: TimeInterval) {
        guard trackingActive else { return }
        let (events, overlayState) = engine.process(HandFrame(time: time, hands: hands))

        for event in events {
            if case .dictationToggle = event {
                dictation.toggle()
            }
        }
        mouse.apply(events)
        overlay.render(overlay: overlayState, dictation: dictation.hud, projector: projector)

        let count = overlayState.hands.count
        if count != handsDetected { handsDetected = count }
        if overlayState.mode != mode { mode = overlayState.mode }
    }

    // MARK: - Settings propagation

    private func apply(settings: PawvisSettings) {
        engine.config = settings.gestures
        overlay.setConfig(settings.overlay)
        dictation.setConfig(settings.dictation)
        refreshProjector()
        camera.setDevice(deviceID: settings.general.cameraDeviceID)
    }

    private func refreshProjector() {
        projector = ScreenProjector(
            controlAllDisplays: settingsStore.settings.general.controlAllDisplays)
        mouse.updateProjector(projector)
    }
}
