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
                dictation: appDelegate.controller.dictation,
                updater: appDelegate.updater)
        } label: {
            MenuBarIcon(dictationActive: appDelegate.controller.dictation.state.isActive)
        }
        .menuBarExtraStyle(.window)

        Settings {
            SettingsView(store: appDelegate.controller.settingsStore,
                         updater: appDelegate.updater)
        }

        Window("Pawvis Gesture Guide", id: "gesture-guide") {
            GestureGuideView(store: appDelegate.controller.settingsStore)
        }
        .windowResizability(.contentSize)
        .defaultPosition(.center)
    }

}

/// The status item: the sloth-claw template glyph (adapts to menu bar
/// light/dark), with a small dot while dictation is live. Falls back to an
/// SF Symbol if the glyph asset is missing (e.g. running the bare binary).
private struct MenuBarIcon: View {
    let dictationActive: Bool

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
                if dictationActive {
                    Circle()
                        .fill(PawvisTheme.purpleUI)
                        .frame(width: 5, height: 5)
                        .offset(x: 2, y: -1)
                }
            }
        } else {
            Image(systemName: dictationActive ? "pawprint.circle.fill" : "pawprint.fill")
        }
    }
}

final class AppDelegate: NSObject, NSApplicationDelegate, ObservableObject {
    let controller: PawvisController
    let updater: UpdateChecker
    private var dictationObservation: AnyCancellable?
    private var updaterObservation: AnyCancellable?

    override init() {
        // AppDelegate is constructed on the main thread before the run loop starts.
        controller = MainActor.assumeIsolated {
            PawvisController(settingsStore: SettingsStore())
        }
        updater = MainActor.assumeIsolated { UpdateChecker() }
        super.init()
        // Forward nested state changes so the MenuBarExtra label (which only
        // observes the delegate) updates when dictation starts/stops.
        dictationObservation = controller.dictation.objectWillChange
            .sink { [weak self] _ in self?.objectWillChange.send() }
        updaterObservation = updater.objectWillChange
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

        // At most one automatic check per day (see UpdatePolicy).
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
