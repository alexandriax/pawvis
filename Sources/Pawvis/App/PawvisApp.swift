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
                updater: appDelegate.updater)
        } label: {
            MenuBarIcon(voiceActive: appDelegate.controller.voice.state.isActive)
        }
        .menuBarExtraStyle(.window)

        Settings {
            SettingsView(store: appDelegate.controller.settingsStore,
                         updater: appDelegate.updater,
                         loginItem: appDelegate.loginItem)
        }

        Window("Pawvis Gesture Guide", id: "gesture-guide") {
            GestureGuideView(store: appDelegate.controller.settingsStore)
        }
        .windowResizability(.contentSize)
        .defaultPosition(.center)
    }

}

/// The status item: the sloth-claw template glyph (adapts to menu bar
/// light/dark), with a small dot while voice control is live. Falls back to
/// an SF Symbol if the glyph asset is missing (e.g. running the bare binary).
private struct MenuBarIcon: View {
    let voiceActive: Bool

    private static let clawImage: NSImage? = {
        guard let url = Bundle.main.url(forResource: "menubar-claw", withExtension: "png"),
              let image = NSImage(contentsOf: url) else { return nil }
        image.isTemplate = true
        image.size = NSSize(width: 18, height: 18)
        return image
    }()

    var body: some View {
        if let claw = Self.clawImage {
            ZStack(alignment: .topTrailing) {
                Image(nsImage: claw)
                if voiceActive {
                    Circle()
                        .fill(PawvisTheme.purpleUI)
                        .frame(width: 5, height: 5)
                        .offset(x: 2, y: -1)
                }
            }
        } else {
            Image(systemName: voiceActive ? "pawprint.circle.fill" : "pawprint.fill")
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

        if controller.settingsStore.settings.general.startTrackingOnLaunch, !automated {
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

        // At most one automatic check per day (see UpdatePolicy). A release
        // worth offering posts the system notification via `onUpdateFound`.
        updater.checkIfDue()

    }

    func applicationShouldTerminate(_ sender: NSApplication) -> NSApplication.TerminateReply {
        // Release camera/mic/buttons before the process starts tearing down —
        // applicationWillTerminate alone can run too late for AVFoundation to
        // wind down cleanly, which left ghost state across relaunch cycles.
        controller.shutdown()
        return .terminateNow
    }

    func applicationWillTerminate(_ notification: Notification) {
        controller.shutdown()
    }
}
