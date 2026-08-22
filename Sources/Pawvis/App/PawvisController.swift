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
    /// Why the camera pipeline is broken right now, or nil while healthy:
    /// access denied, device unplugged, claimed by another app, or simply no
    /// frames arriving. The menu status line and the overlay pill read it;
    /// frames resuming clears it.
    @Published private(set) var cameraFailure: String?
    /// Why tracking is resting while `trackingActive` stays true (the lock
    /// screen), for the menu's status line. nil whenever tracking is live —
    /// a pause is not a stop, so the toggle stays on.
    @Published private(set) var pauseReason: String?
    /// Whether look-to-control is holding actions closed because the user
    /// faces away from the screen. A pause like the lock screen's — the
    /// toggle stays on — except the camera keeps running: its frames carry
    /// the face that will reopen the gate.
    @Published private(set) var attentionPaused = false
    /// True when the camera is delivering frames but they carry no image (a
    /// near-black picture) — most often an iPhone Continuity Camera whose
    /// rear lens faces the desk, or a covered or shuttered webcam. The menu
    /// and the status pill say so, because "no hands" and "facing away" are
    /// both true and both useless when the real problem is that the camera
    /// sees nothing.
    @Published private(set) var cameraSignalDark = false

    private let camera = CameraManager()
    private let tracking = HandTrackingService()
    private let faceTracking = FaceAttentionService()
    /// The look-to-control policy's thread-safe face, consulted at the
    /// camera tap (see `AttentionGateBox`).
    private let attention = AttentionGateBox()
    /// The idle frame-skip policy's thread-safe face, consulted at the
    /// camera tap (see `FrameThrottleBox`).
    private let throttle = FrameThrottleBox()
    /// The black-feed policy's thread-safe face, consulted at the camera tap
    /// (see `CameraSignalBox`).
    private let signal = CameraSignalBox()
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
        attention.setConfig(settings.attention.gateConfig())
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
            // Black-feed check first, before the throttle and gate can skip
            // this frame: a camera pointed at nothing (an iPhone rear lens
            // facing the desk, a covered webcam) has no hands and no face,
            // so both of those would drop the frame — yet a black feed is
            // exactly the state the user needs named. The box samples on its
            // own sparse cadence, so running it every frame is cheap.
            if let (dark, changed) = self.signal.assess(sampleBuffer, at: CACurrentMediaTime()), changed {
                DispatchQueue.main.async {
                    MainActor.assumeIsolated { self.cameraSignalDidChange(dark) }
                }
            }
            // Idle throttle, decided here at the tap: with no hands around
            // for a while, most frames skip Vision entirely — the cheap,
            // glitch-free lever (the AVCaptureSession itself is never
            // touched). A skipped frame never reaches the engine, whose only
            // clock is the timestamps of the frames it is given, so the gap
            // reads as nothing at all. The call also stamps the stall
            // watchdog's liveness clock, before its own verdict: the
            // watchdog asks whether the camera is delivering, and a frame
            // the throttle skips is still proof that it is.
            guard self.throttle.shouldRunInference(at: CACurrentMediaTime()) else { return }
            // Look-to-control, decided here at the tap like the idle
            // throttle: while the user faces away, hand-pose inference is
            // skipped wholesale and the (far cheaper, sampled) face
            // detector is the only Vision work left, watching for them to
            // look back. A skipped frame never reaches the gesture engine;
            // the main actor hears about verdict changes only.
            let (attentive, attentionChanged) = self.attention.assess(
                at: CACurrentMediaTime()) { self.faceTracking.observe(in: sampleBuffer) }
            if attentionChanged {
                DispatchQueue.main.async {
                    MainActor.assumeIsolated { self.attentionDidChange(attentive) }
                }
            }
            guard attentive else { return }
            // Camera queue: run Vision synchronously, then hop to main.
            // DispatchQueue.main (not Task) — the main queue is FIFO, so
            // down/drag/up frame batches can never arrive reordered.
            let hands = self.tracking.detectHands(in: sampleBuffer)
            let time = CACurrentMediaTime()
            // The first frame containing a hand exits the throttle at once:
            // every following frame processes again, full rate.
            self.throttle.sawHands(!hands.isEmpty, at: time)
            DispatchQueue.main.async {
                MainActor.assumeIsolated {
                    self.processFrame(hands: hands, at: time)
                }
            }
        }

        // Camera lifecycle (all delivered on the main queue). A session that
        // just came up gets a fresh warm-up leash on the stall clock; a
        // session that died or was interrupted goes through the one failure
        // path, because frames have stopped and nothing else will run.
        camera.onRunningChanged = { [weak self] running in
            MainActor.assumeIsolated {
                guard let self, running else { return }
                self.armStallClock(grace: Self.startupGraceSeconds)
            }
        }
        // A device swap on a running session (settings switch, disconnect
        // fallback, the chosen camera returning) reconfigures in place:
        // frames pause and the new device warms up, but `isRunning` never
        // flips, so the re-arm above stays silent. Give the swap the same
        // warm-up leash a fresh session gets.
        camera.onWillReconfigure = { [weak self] in
            MainActor.assumeIsolated {
                guard let self else { return }
                self.armStallClock(grace: Self.startupGraceSeconds)
                // A different camera is warming up: forget the old feed's
                // brightness history so the new one is judged from scratch,
                // and drop any stale dark warning until it has looked.
                self.signal.reset()
                self.cameraSignalDark = false
            }
        }
        camera.onFailure = { [weak self] reason in
            MainActor.assumeIsolated {
                self?.enterCameraFailure(reason)
            }
        }
        camera.onInterruption = { [weak self] reason in
            MainActor.assumeIsolated {
                guard let self else { return }
                if let reason {
                    self.enterCameraFailure(reason)
                } else {
                    // The system says capture is back. Clear the failure and
                    // re-arm the stall clock: if frames don't actually
                    // return, the watchdog re-trips honestly.
                    self.clearCameraFailure()
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

        // The lock screen: synthetic mouse events land on it like any other
        // window, so a hand in front of the camera could click around the
        // password field. Tracking pauses on lock and resumes on unlock —
        // these are the distributed notifications loginwindow posts.
        let distributed = DistributedNotificationCenter.default()
        distributed.addObserver(
            forName: Notification.Name("com.apple.screenIsLocked"),
            object: nil, queue: .main
        ) { [weak self] _ in
            Task { @MainActor in self?.screenDidLock() }
        }
        distributed.addObserver(
            forName: Notification.Name("com.apple.screenIsUnlocked"),
            object: nil, queue: .main
        ) { [weak self] _ in
            Task { @MainActor in self?.screenDidUnlock() }
        }

        // Low Power Mode tightens the idle throttle (a shorter no-hands
        // delay, a sparser probe rate). Seed the current state, then track it.
        throttle.setLowPower(ProcessInfo.processInfo.isLowPowerModeEnabled)
        NotificationCenter.default.addObserver(
            forName: .NSProcessInfoPowerStateDidChange,
            object: nil, queue: .main
        ) { [weak self] _ in
            Task { @MainActor in
                self?.throttle.setLowPower(ProcessInfo.processInfo.isLowPowerModeEnabled)
            }
        }

        // Sleep is a camera interruption by another name: frames stop, but
        // no AVFoundation notification says so. Let go of anything held
        // before the machine goes down, and quiet the watchdog until wake.
        let workspace = NSWorkspace.shared.notificationCenter
        workspace.addObserver(
            forName: NSWorkspace.willSleepNotification, object: nil, queue: .main
        ) { [weak self] _ in
            Task { @MainActor in self?.systemWillSleep() }
        }
        workspace.addObserver(
            forName: NSWorkspace.didWakeNotification, object: nil, queue: .main
        ) { [weak self] _ in
            Task { @MainActor in self?.systemDidWake() }
        }
    }

    // MARK: - Lifecycle

    func startTracking() {
        guard !trackingActive else { return }
        cameraFailure = nil

        switch Permissions.camera() {
        case .denied:
            cameraPermission = .denied
            cameraFailure = "Camera access denied — enable it in System Settings → Privacy"
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

        trackingActive = true

        guard !trainingActive else {
            // The trainer window already owns the camera and deliberately
            // hides the overlay (`beginTraining`); starting it here would
            // pop an unrendered overlay over the trainer and fight it for
            // the capture session. Flipping `trackingActive` is enough for
            // the menu switch and status row to update right away —
            // `endTraining` reconciles camera/overlay/engine against
            // whatever `trackingActive` ends up being once the window
            // closes, so the two callers can never leave the app disagreeing
            // with its own menu about whether tracking is on.
            Log.app.info("Tracking armed mid-training; camera/overlay follow once the trainer closes")
            return
        }
        activateTrackingEffects()
        Log.app.info("Tracking started")
    }

    /// Starts everything `trackingActive` implies for the engine, overlay,
    /// camera and permission polling. Split out of `startTracking` so
    /// `endTraining`'s post-training reconcile can apply exactly the same
    /// effects instead of a hand-maintained duplicate that could drift.
    private func activateTrackingEffects() {
        engine.reset()
        throttle.reset()
        attention.reset()
        attentionPaused = false
        signal.reset()
        cameraSignalDark = false
        refreshProjector()
        overlay.show()
        camera.start(deviceID: settingsStore.settings.general.cameraDeviceID)
        startPermissionPolling()
        armStallClock(grace: Self.startupGraceSeconds)
        startWatchdog()

        // Started while the screen is locked (a voice command can): tracking
        // comes up already paused, and unlock resumes it. The pause quiets
        // the watchdog too — a camera resting on purpose is not a failure.
        if screenLocked { pauseForScreenLock() }
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
        trackingActive = false
        handsDetected = 0
        grabbing = false
        controlArmed = true
        // A stop while paused on the lock screen (a voice command can) is a
        // real stop: unlock must not resurrect the camera.
        pausedForLock = false
        pauseReason = nil
        attentionPaused = false
        throttle.setInteracting(false)
        attention.setInteracting(false)

        guard !trainingActive else {
            // Stopping the capture session here would cut the trainer's own
            // feed out from under it — the camera is shared while the
            // window is open. Flip the flag now (the menu switch and status
            // row read it directly) and let `endTraining` tear the camera/
            // overlay down for real once the window closes.
            Log.app.info("Tracking disarmed mid-training; camera/overlay follow once the trainer closes")
            return
        }
        deactivateTrackingEffects()
        Log.app.info("Tracking stopped")
    }

    /// Stops everything `trackingActive` implies, the mirror of
    /// `activateTrackingEffects`. Always releases any held button first —
    /// tracking must never leave one stuck down, no matter what state
    /// training left the camera/overlay in.
    private func deactivateTrackingEffects() {
        camera.stop()
        releaseEverything()
        overlay.hide()
        cameraFailure = nil // leaving tracking on purpose: nothing is failing
        signal.reset()
        cameraSignalDark = false
        permissionPollTimer?.invalidate()
        permissionPollTimer = nil
        watchdogTimer?.invalidate()
        watchdogTimer = nil
    }

    /// The one force-release path: the engine's held press unwinds through
    /// the same paced posting queue as every other event, then the mouse's
    /// own bookkeeping lets go of anything left. stopTracking, the training
    /// hand-off, camera failure, and system sleep all funnel through here so
    /// a stuck synthetic button is impossible.
    private func releaseEverything() {
        mouse.apply(engine.forceRelease(at: CACurrentMediaTime()))
        mouse.releaseAllButtons()
    }

    func toggleTracking() {
        trackingActive ? stopTracking() : startTracking()
    }

    // MARK: - Screen lock

    /// Whether the screen is currently locked, per loginwindow's distributed
    /// notifications. Consulted by `startTracking` so a session started from
    /// the lock screen (voice) comes up paused.
    private var screenLocked = false
    /// True while tracking is paused because of the lock screen: the camera
    /// is stopped but `trackingActive` stays true — a pause, not a stop.
    private var pausedForLock = false

    private func screenDidLock() {
        screenLocked = true
        pauseForScreenLock()
    }

    private func screenDidUnlock() {
        screenLocked = false
        resumeFromScreenLock()
    }

    /// On lock: let go of anything held (the same release path `stopTracking`
    /// uses — a button must never stay logically down behind the lock
    /// screen), then stop the camera. Without this, a hand in front of the
    /// camera kept posting synthetic events onto the lock screen itself.
    /// The trainer is left alone: it posts no events, and freezing its
    /// preview mid-recording would corrupt the take.
    private func pauseForScreenLock() {
        guard trackingActive, !pausedForLock, !trainingActive else { return }
        pausedForLock = true
        pauseReason = "Paused on the lock screen"
        mouse.apply(engine.forceRelease(at: CACurrentMediaTime()))
        mouse.releaseAllButtons()
        engine.reset() // stale press/arm state must not survive into resume
        camera.stop()
        overlay.hide()
        handsDetected = 0
        grabbing = false
        controlArmed = true
        throttle.setInteracting(false)
        attention.setInteracting(false)
        // The lock outranks the gate, and unlock starts attentive: whoever
        // just typed the password is at the machine, facing it.
        attention.reset()
        attentionPaused = false
        // The camera is stopped now, so any "shows no image" verdict is
        // stale: clear it rather than warn about a feed that isn't running.
        signal.reset()
        cameraSignalDark = false
        Log.app.info("Tracking paused: screen locked")
    }

    /// On unlock: pick up where lock left off — camera back on, overlay
    /// back, the engine and throttle starting fresh (the open-hand trigger
    /// re-arms from scratch, exactly like a new session).
    private func resumeFromScreenLock() {
        guard pausedForLock else { return }
        pausedForLock = false
        pauseReason = nil
        guard trackingActive else { return }
        engine.reset()
        throttle.reset()
        attention.reset()
        signal.reset()
        cameraSignalDark = false
        overlay.show()
        // Arm the stall clock HERE, not only from `onRunningChanged`: that
        // callback hops the camera queue and a slow `startRunning`, and the
        // 0.5 s watchdog tick — live again the moment `pausedForLock`
        // flipped — would otherwise convict on the last frame before the
        // lock, minutes old. One false failure per unlock, cleared by the
        // first frame: the flap this comment is the tombstone of.
        armStallClock(grace: Self.startupGraceSeconds)
        camera.start(deviceID: settingsStore.settings.general.cameraDeviceID)
        Log.app.info("Tracking resumed: screen unlocked")
    }

    // MARK: - Look-to-control

    /// The attention gate's verdict crossed over, reported from the camera
    /// tap (or forced by wake/settings reconciles). Away mirrors the
    /// lock-screen pause — release, reset, overlay hidden — except the
    /// camera stays up: its frames carry the face that reopens the gate.
    private func attentionDidChange(_ attentive: Bool) {
        if attentive {
            guard attentionPaused else { return }
            attentionPaused = false
            guard trackingActive, !trainingActive else { return }
            engine.reset()
            overlay.show()
            Log.app.info("Control resumed: facing the screen again")
        } else {
            guard !attentionPaused, trackingActive, !trainingActive,
                  !pausedForLock else { return }
            attentionPaused = true
            // The gate holds open while a press or scroll is in flight, but
            // its interacting mirror lags the engine by a frame: release
            // through the same paced path every other pause uses, so a stuck
            // synthetic button stays impossible even across that race.
            releaseEverything()
            engine.reset()
            handsDetected = 0
            grabbing = false
            controlArmed = true
            throttle.setInteracting(false)
            attention.setInteracting(false)
            overlay.hide()
            Log.app.info("Control paused: facing away from the screen")
        }
    }

    /// The black-feed verdict crossed over, reported from the camera tap.
    /// Nothing to release or reset — a dark feed produces no hands and no
    /// face, so control is already parked by the ordinary paths; this only
    /// publishes the reason so the menu and pill can say "the camera sees
    /// nothing" instead of the true-but-useless "no hands" / "facing away".
    private func cameraSignalDidChange(_ dark: Bool) {
        guard trackingActive, cameraSignalDark != dark else { return }
        cameraSignalDark = dark
        Log.camera.info("Camera feed \(dark ? "went dark (no image)" : "has an image again", privacy: .public)")
    }

    // MARK: - Gesture training

    /// While the trainer window is open, camera frames bypass the engine
    /// entirely — no cursor, no clicks, no gesture fires. Training must not
    /// fight the very motions it is recording.
    @Published private(set) var trainingActive = false
    /// The trainer's frame feed, called on the main actor with camera-space
    /// hands and the frame timestamp.
    var trainingFrameTap: (([Hand], TimeInterval) -> Void)?

    func beginTraining() {
        guard !trainingActive else { return }
        trainingActive = true
        // The trainer wants every frame: a throttled preview would record
        // throttled templates.
        throttle.setTraining(true)
        attention.setTraining(true)
        if trackingActive {
            // Let go of anything in flight and hide the overlay; the camera
            // keeps running, now feeding only the trainer.
            releaseEverything()
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
                cameraFailure = "Camera access denied — enable it in System Settings → Privacy"
            }
        }
        Log.app.info("Gesture training started (tracking was \(self.trackingActive))")
    }

    func endTraining() {
        guard trainingActive else { return }
        trainingActive = false
        trainingFrameTap = nil
        throttle.setTraining(false)
        attention.setTraining(false)
        // `trackingActive` may have changed while the trainer had the
        // camera — `startTracking`/`stopTracking` deliberately keep the menu
        // switch (and any other caller) live during training instead of
        // blocking it, only deferring the camera/overlay/engine side
        // effects. Reconcile against trackingActive's CURRENT value here,
        // never a snapshot taken back at `beginTraining`, or camera/overlay
        // can end up disagreeing with what the menu says. The reconcile
        // re-arms the stall clock with the startup grace, so the watchdog
        // (which sat out training) never convicts on frames that were the
        // trainer's to consume.
        if trackingActive {
            activateTrackingEffects()
        } else {
            deactivateTrackingEffects()
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

    // MARK: - Camera failure watchdog

    /// The engine only runs when a frame arrives, and its tracking-loss grace
    /// needs an *empty* frame — a dead camera sends none at all. So when the
    /// webcam is unplugged, claimed by another app, or wedged, a drag in
    /// progress would stay held system-wide forever, under an overlay frozen
    /// at screen-saver level, with the menu still claiming all is well. This
    /// watchdog is the clock that keeps ticking when frames don't: past the
    /// stall window it force-releases every button, parks the overlay, and
    /// says why — and the moment frames return, everything comes back.

    /// Cold cameras (and cameras waking from sleep) take a while to deliver
    /// the first frame; the stall verdict waits this long after a (re)start.
    private static let startupGraceSeconds: TimeInterval = 5

    private var watchdogTimer: Timer?
    /// Between willSleep and didWake the watchdog stays quiet: the whole
    /// machine has stopped, which is nobody's failure.
    private var asleep = false

    /// Restart the no-frames countdown with a warm-up grace. The clock
    /// itself lives in the throttle box (`CameraStallClock`), stamped at the
    /// camera tap for every captured frame — including the ones the idle
    /// throttle skips, which are evidence of a live camera all the same.
    /// Call this synchronously from every path that starts, restarts, or
    /// resumes the camera: the asynchronous `onRunningChanged` re-arm is the
    /// second belt, not the first, because a watchdog tick can beat it.
    private func armStallClock(grace: TimeInterval) {
        throttle.armStallClock(at: CACurrentMediaTime(), grace: grace)
    }

    private func startWatchdog() {
        watchdogTimer?.invalidate()
        watchdogTimer = Timer.scheduledTimer(withTimeInterval: 0.5, repeats: true) { [weak self] _ in
            Task { @MainActor in self?.watchdogTick() }
        }
        watchdogTimer?.tolerance = 0.1
    }

    private func watchdogTick() {
        guard trackingActive, !trainingActive, !asleep, !pausedForLock else { return }
        let now = CACurrentMediaTime()
        if let failure = cameraFailure {
            // Keep the pill's copy of the reason alive. StatusPillPolicy
            // still times it out and honors the ✕, exactly like the
            // Accessibility warning; the menu line is the copy that stays.
            overlay.parkForFailure(failure, now: now)
        } else if throttle.cameraStalled(at: now) {
            enterCameraFailure("Camera stopped sending frames — check it's connected and free")
        }
    }

    /// The one entry into the failed state, whatever the trigger (stall,
    /// runtime error, interruption, disconnect): let go of every held
    /// button — the same force-release path stopTracking uses — park the
    /// overlay with the reason, and publish it for the menu.
    private func enterCameraFailure(_ reason: String) {
        guard trackingActive, !trainingActive, !asleep, !pausedForLock else { return }
        if cameraFailure == nil {
            Log.app.error("Camera failure while tracking: \(reason, privacy: .public)")
            releaseEverything()
            engine.reset()
            handsDetected = 0
            grabbing = false
        }
        cameraFailure = reason
        overlay.parkForFailure(reason, now: CACurrentMediaTime())
    }

    /// Frames are back (or the interruption ended): un-park and say so.
    /// Rendering resumes with the next frame; the engine restarts clean.
    private func clearCameraFailure() {
        armStallClock(grace: Self.startupGraceSeconds)
        guard cameraFailure != nil, trackingActive else { return }
        cameraFailure = nil
        engine.reset()
        overlay.endFailure()
        gestureNotice = (text: "🐾 Camera is back",
                         until: CACurrentMediaTime() + Self.gestureNoticeSeconds)
        Log.app.info("Camera recovered; tracking resumed")
    }

    // MARK: - Sleep / wake

    /// Sleep is an interruption without a notification from AVFoundation:
    /// release anything held before the machine goes down, and quiet the
    /// watchdog — no failure UI for a screen that is off.
    private func systemWillSleep() {
        asleep = true
        guard trackingActive else { return }
        releaseEverything()
        engine.reset()
        Log.app.info("System sleeping; released buttons and paused the watchdog")
    }

    /// Tracking that was on stays on across sleep: nudge the camera (a
    /// no-op if the session survived) and give it the startup grace before
    /// the watchdog may complain.
    private func systemDidWake() {
        asleep = false
        guard trackingActive || trainingActive else { return }
        // Whoever woke the machine is at it: the attention gate starts
        // fresh, and a pause left over from before sleep resumes now (the
        // resume path is what re-shows the overlay it hid).
        attention.reset()
        attentionDidChange(true)
        armStallClock(grace: Self.startupGraceSeconds)
        camera.start(deviceID: settingsStore.settings.general.cameraDeviceID)
        Log.app.info("System woke; resuming camera")
    }

    // MARK: - Frame pipeline

    private func processFrame(hands: [Hand], at time: TimeInterval) {
        // The stall watchdog is fed at the camera tap, not here: while the
        // idle throttle is engaged most captured frames never reach this
        // method, and a watchdog that only counted processed frames once
        // convicted a live camera for the throttle's own skipping.
        if trainingActive {
            // The trainer owns the stream; nothing reaches the engine or
            // the mouse while its window is open.
            trainingFrameTap?(hands, time)
            return
        }
        guard trackingActive else { return }
        if cameraFailure != nil {
            // The camera is delivering again — failure over, overlay back.
            clearCameraFailure()
        }
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

        // While a button is held or a scroll is active, the idle throttle
        // must never engage. Hands are obviously in view then — the no-hands
        // clock isn't even running — but the guard is explicit rather than
        // inferred: dropping frames mid-press is the one failure this
        // feature must not be able to cause.
        let interacting = overlayState.grabbed || overlayState.rightGrabbed
            || overlayState.isScrolling
        throttle.setInteracting(interacting)
        // The attention gate must never close mid-press either: same fact,
        // same mirror, second consumer.
        attention.setInteracting(interacting)

        overlay.render(
            overlay: overlayState,
            voice: hudLine(at: time),
            projector: projector,
            accessibilityBlocked: !accessibilityGranted,
            diagnostics: diagnosticsLine(hands: hands, at: time))

        let count = overlayState.hands.count
        if count != handsDetected { handsDetected = count }
        let anyGrab = overlayState.grabbed || overlayState.rightGrabbed
            || overlayState.middleGrabbed
        if anyGrab != grabbing { grabbing = anyGrab }
        if overlayState.armed != controlArmed { controlArmed = overlayState.armed }
    }

    // MARK: - Custom gestures

    /// How long a fired gesture's confirmation stays in the pill.
    private static let gestureNoticeSeconds: TimeInterval = 2.5

    /// The frontmost app's bundle ID, read once per gesture fire (cheap; no
    /// observer, no polling). The per-app override decision belongs to the
    /// app that's frontmost the moment the gesture lands.
    private func frontmostBundleID() -> String? {
        NSWorkspace.shared.frontmostApplication?.bundleIdentifier
    }

    private func performCustomGesture(_ gesture: CustomGesture, at time: TimeInterval) {
        guard let action = settingsStore.settings.customGestures.action(
            for: gesture, frontmostBundleID: frontmostBundleID()) else { return }
        let feedback = actionRunner.perform(action)
        Log.app.info("Custom gesture \(gesture.rawValue): \(feedback)")
        gestureNotice = (text: "🐾 \(feedback)", until: time + Self.gestureNoticeSeconds)
    }

    private func performTrainedGesture(_ id: UUID, at time: TimeInterval) {
        guard settingsStore.settings.customGestures.enabled,
              let gesture = settingsStore.settings.trainedGestures.gesture(withID: id),
              let action = gesture.resolvedAction(frontmostBundleID: frontmostBundleID())
        else { return }
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
        // The engine emits normalized scroll deltas; the speed dial applies
        // where the wheel pixels are composed.
        mouse.scrollGain = settings.gestures.scrollGain
        engine.customConfig = settings.customGestures.detectorConfig()
        // Trained gestures share the custom library's master switch.
        engine.trainedConfig = settings.trainedGestures.detectorConfig(
            enabled: settings.customGestures.enabled)
        attention.setConfig(settings.attention.gateConfig())
        // Toggling look-to-control off resets the gate to attentive without
        // a frame in flight to say so: reconcile the published pause here
        // rather than waiting on a verdict change the gate will never emit.
        if attentionPaused, attention.attentive { attentionDidChange(true) }
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
