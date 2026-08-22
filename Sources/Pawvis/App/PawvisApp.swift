import AppKit
import Combine
import PawvisCore
import SwiftUI

struct PawvisApp: App {
    @NSApplicationDelegateAdaptor(AppDelegate.self) private var appDelegate

    var body: some Scene {
        MenuBarExtra {
            MenuContentView(
                controller: appDelegate.controller,
                voice: appDelegate.controller.voice,
                updater: appDelegate.updater,
                settingsStore: appDelegate.controller.settingsStore)
        } label: {
            MenuBarIcon(voiceActive: appDelegate.controller.voice.state.isActive)
        }
        .menuBarExtraStyle(.window)

        Settings {
            SettingsView(store: appDelegate.controller.settingsStore,
                         updater: appDelegate.updater,
                         loginItem: appDelegate.loginItem,
                         controller: appDelegate.controller)
        }

        Window("Pawvis Gesture Guide", id: GuideWindow.id) {
            GestureGuideView(store: appDelegate.controller.settingsStore)
        }
        .windowResizability(.contentSize)
        .defaultPosition(.center)

        Window("Train a Gesture", id: TrainerWindow.id) {
            GestureTrainerView(controller: appDelegate.controller)
        }
        .windowResizability(.contentSize)
        .defaultPosition(.center)

        Window("Welcome to Pawvis", id: WelcomeWindow.id) {
            WelcomeView(controller: appDelegate.controller)
        }
        .windowResizability(.contentSize)
        .defaultPosition(.center)
    }

}

/// The status item: the sloth-claw template glyph (adapts to menu bar
/// light/dark), with a small dot while voice control is live. Falls back to
/// an SF Symbol if the glyph asset is missing (e.g. running the bare binary).
///
/// Also the place `SettingsWindow` gets its `OpenSettingsAction`: this label
/// is the one view a menu-bar app is guaranteed to instantiate at launch, so
/// capturing here means the update notification can open Settings even when
/// no other view of ours has ever existed. (The `showSettingsWindow:`
/// selector is not an alternative — on macOS 26 it returns true and does
/// nothing.)
private struct MenuBarIcon: View {
    let voiceActive: Bool
    @Environment(\.openSettings) private var openSettings
    @Environment(\.openWindow) private var openWindow

    private static let clawImage: NSImage? = PawvisGlyph.claw(size: 18)

    var body: some View {
        Group {
            if let claw = Self.clawImage {
                ZStack(alignment: .topTrailing) {
                    Image(nsImage: claw)
                    if voiceActive {
                        Circle()
                            .fill(PawvisTheme.accentUI)
                            .frame(width: 5, height: 5)
                            .offset(x: 2, y: -1)
                    }
                }
            } else {
                Image(systemName: voiceActive ? "pawprint.circle.fill" : "pawprint.fill")
            }
        }
        .onAppear {
            SettingsWindow.opener = openSettings
            GuideWindow.opener = openWindow
            TrainerWindow.opener = openWindow
            WelcomeWindow.opener = openWindow
        }
    }
}

final class AppDelegate: NSObject, NSApplicationDelegate, ObservableObject {
    let controller: PawvisController
    let updater: UpdateChecker
    let loginItem: LoginItemController
    private let updateNotifier: UpdateNotifier
    private var voiceObservation: AnyCancellable?
    private var updaterObservation: AnyCancellable?
    /// Re-checks while resident (below): `checkIfDue()` self-gates to once
    /// per 24h (`UpdatePolicy`), so this only needs to be frequent enough
    /// that a machine which never sleeps still gets checked daily.
    private static let updateCheckInterval: TimeInterval = 6 * 60 * 60
    private var updateCheckTimer: Timer?
    private var wakeObserver: NSObjectProtocol?

    override init() {
        // AppDelegate is constructed on the main thread before the run loop starts.
        controller = MainActor.assumeIsolated {
            PawvisController(settingsStore: SettingsStore())
        }
        updater = MainActor.assumeIsolated { UpdateChecker() }
        loginItem = MainActor.assumeIsolated { LoginItemController() }
        updateNotifier = MainActor.assumeIsolated {
            UpdateNotifier(showUpdateUI: { SettingsRouter.shared.open(.about) })
        }
        super.init()
        // Forward nested state changes so the MenuBarExtra label (which only
        // observes the delegate) updates when voice control starts/stops.
        voiceObservation = controller.voice.objectWillChange
            .sink { [weak self] _ in self?.objectWillChange.send() }
        updaterObservation = updater.objectWillChange
            .sink { [weak self] _ in self?.objectWillChange.send() }
        MainActor.assumeIsolated {
            updater.onUpdateFound = { [weak self] release in
                self?.updateNotifier.announce(release)
            }
        }
    }

    func applicationDidFinishLaunching(_ notification: Notification) {
        Log.app.info("Pawvis launched")

        // Single-instance guard with takeover semantics: the NEWEST launch
        // wins and terminates older instances. (Deferring to the old instance
        // would keep a stale — possibly buggier — build alive; two instances
        // at once post competing cursor moves and the pointer visibly jumps
        // between two positions.)
        if let bundleID = Bundle.main.bundleIdentifier {
            let others = NSRunningApplication.runningApplications(withBundleIdentifier: bundleID)
                .filter { $0.processIdentifier != ProcessInfo.processInfo.processIdentifier }
            for other in others {
                Log.app.warning("Terminating older Pawvis instance (pid \(other.processIdentifier))")
                if !other.terminate() {
                    other.forceTerminate()
                }
            }
        }

        // A previous instance that crashed or was force-killed mid-pinch can
        // leave a synthetic mouse button logically down system-wide. Clear it.
        MouseController.postDefensiveButtonRelease()

        // PAWVIS_NO_AUTOSTART lets automated smoke tests boot the app without
        // triggering the camera permission flow — or, below, leaving a login
        // item registered on the machine that ran them.
        let automated = ProcessInfo.processInfo.environment["PAWVIS_NO_AUTOSTART"] != nil

        // First run: a genuinely new install gets the welcome window (opened
        // below) instead of a cold camera dialog, and auto-start waits for
        // the tour's own Start button. An install that already granted the
        // camera predates onboarding — record completion and launch exactly
        // as every build before the tour did. The rules are pure and tested
        // (FirstRunPolicy); automated runs stay headless and leave the flag
        // untouched, so a smoke test on a fresh machine can't suppress a
        // later real onboarding.
        let firstRun = FirstRunPolicy.verdict(
            completed: FirstRun.completed,
            cameraGranted: Permissions.camera() == .granted,
            automated: automated)
        if firstRun == .adoptCompleted {
            FirstRun.markCompleted()
        }

        if controller.settingsStore.settings.general.startTrackingOnLaunch, !automated,
           firstRun != .showWelcome {
            controller.startTracking()
        }

        // Enable the login item on first run, and afterwards keep the setting
        // and macOS in step — including adopting an "off" the user chose in
        // System Settings rather than re-registering over it.
        if !automated {
            let store = controller.settingsStore
            let resolved = loginItem.reconcileAtLaunch(desired: store.settings.general.launchAtLogin)
            if resolved != store.settings.general.launchAtLogin {
                store.settings.general.launchAtLogin = resolved
            }
        }

        // Claim the notification delegate before this method returns, or a
        // banner the user clicked while Pawvis wasn't running is delivered to
        // nobody and the Install button does nothing.
        updateNotifier.start()

        // PAWVIS_OPEN_SETTINGS=<general|tracking|mouse|gestures|voice|about> opens
        // Settings on that tab right after launch. This exists for eyes-on UI
        // verification (AGENTS.md requires looking at the tabs after settings
        // changes, and SwiftUI offers no headless render of them) and it
        // exercises the exact cold-start path the update notification uses.
        if let name = ProcessInfo.processInfo.environment["PAWVIS_OPEN_SETTINGS"],
           let tab = SettingsTab(rawValue: name) {
            DispatchQueue.main.asyncAfter(deadline: .now() + 0.5) {
                SettingsRouter.shared.open(tab)
            }
        }

        // PAWVIS_OPEN_GUIDE=1 does the same for the Gesture Guide, whose art
        // is bundle-only: the fallback SF Symbols are what a bare `swift run`
        // shows, so looking at the real thing means launching the .app.
        if ProcessInfo.processInfo.environment["PAWVIS_OPEN_GUIDE"] != nil {
            DispatchQueue.main.asyncAfter(deadline: .now() + 0.5) {
                GuideWindow.show()
            }
        }

        // PAWVIS_OPEN_TRAINER=1 opens the gesture trainer — eyes-on UI
        // verification again. It starts the camera (that is the window),
        // so it stays a deliberate, local flag rather than part of any
        // automated flow.
        if ProcessInfo.processInfo.environment["PAWVIS_OPEN_TRAINER"] != nil {
            DispatchQueue.main.asyncAfter(deadline: .now() + 0.5) {
                TrainerWindow.show()
            }
        }

        // The welcome tour: automatic for a genuinely new install (decided
        // above), and on demand via PAWVIS_OPEN_WELCOME=1 — the same eyes-on
        // hook as PAWVIS_OPEN_GUIDE, and the way to look at the tour again
        // without wiping the first-run flag.
        if firstRun == .showWelcome
            || ProcessInfo.processInfo.environment["PAWVIS_OPEN_WELCOME"] != nil {
            DispatchQueue.main.asyncAfter(deadline: .now() + 0.5) {
                WelcomeWindow.show()
            }
        }

        // At most one automatic check per day (see UpdatePolicy). A release
        // worth offering posts the system notification via `onUpdateFound`.
        updater.checkIfDue()

        // That launch-time call is the ONLY automatic trigger unless we add
        // more: Pawvis is a menu-bar app (LSUIElement) that starts at login
        // and then runs indefinitely, so a laptop that's slept through
        // several days instead of logging out never produces a second
        // "launch" to hang a check off — it can silently go weeks without
        // one. `checkIfDue()` already caps itself to once per 24h, so it's
        // safe to call far more often than that: a periodic timer covers a
        // machine that never sleeps, and a wake observer catches the more
        // common case — days asleep — promptly instead of waiting for the
        // next timer tick.
        updateCheckTimer = Timer.scheduledTimer(
            withTimeInterval: Self.updateCheckInterval, repeats: true
        ) { [weak self] _ in
            Task { @MainActor in self?.updater.checkIfDue() }
        }
        wakeObserver = NSWorkspace.shared.notificationCenter.addObserver(
            forName: NSWorkspace.didWakeNotification,
            object: nil, queue: .main
        ) { [weak self] _ in
            Task { @MainActor in self?.updater.checkIfDue() }
        }
    }

    func applicationShouldTerminate(_ sender: NSApplication) -> NSApplication.TerminateReply {
        // Release camera/mic/buttons before the process starts tearing down —
        // applicationWillTerminate alone can run too late for AVFoundation to
        // wind down cleanly, which left ghost state across relaunch cycles.
        controller.shutdown()
        // And take the agent runs with us: they execute with permission
        // prompts bypassed, so none may keep working headless after the app
        // that launched them (and its cancel UI) is gone. Bounded — signals
        // now, ≤0.5s grace, SIGKILL the groups, proceed.
        AgentSessionManager.shared.shutdownOnAppQuit()
        return .terminateNow
    }

    func applicationWillTerminate(_ notification: Notification) {
        controller.shutdown()
        updateCheckTimer?.invalidate()
        if let wakeObserver {
            NSWorkspace.shared.notificationCenter.removeObserver(wakeObserver)
        }
        AgentSessionManager.shared.shutdownOnAppQuit()
    }
}
