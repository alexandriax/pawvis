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
                dictation: appDelegate.controller.dictation)
        } label: {
            Image(systemName: menuBarSymbol)
        }
        .menuBarExtraStyle(.window)

        Settings {
            SettingsView(store: appDelegate.controller.settingsStore)
        }

        Window("Pawvis Gesture Guide", id: "gesture-guide") {
            GestureGuideView(store: appDelegate.controller.settingsStore)
        }
        .windowResizability(.contentSize)
        .defaultPosition(.center)
    }

    private var menuBarSymbol: String {
        appDelegate.controller.dictation.state.isActive
            ? "pawprint.circle.fill" : "pawprint.fill"
    }
}

final class AppDelegate: NSObject, NSApplicationDelegate, ObservableObject {
    let controller: PawvisController
    private var dictationObservation: AnyCancellable?

    override init() {
        // AppDelegate is constructed on the main thread before the run loop starts.
        controller = MainActor.assumeIsolated {
            PawvisController(settingsStore: SettingsStore())
        }
        super.init()
        // Forward nested state changes so the MenuBarExtra label (which only
        // observes the delegate) updates when dictation starts/stops.
        dictationObservation = controller.dictation.objectWillChange
            .sink { [weak self] _ in self?.objectWillChange.send() }
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
        // triggering the camera permission flow.
        if controller.settingsStore.settings.general.startTrackingOnLaunch,
           ProcessInfo.processInfo.environment["PAWVIS_NO_AUTOSTART"] == nil {
            controller.startTracking()
        }
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
