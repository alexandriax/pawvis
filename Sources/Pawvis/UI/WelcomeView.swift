import AppKit
import Combine
import PawvisCore
import SwiftUI

// MARK: - The first-run flag

/// The one-shot "this install has been through (or predates) the welcome
/// tour" flag. Its own UserDefaults key, deliberately *not* a field in the
/// settings JSON — the same pattern as `PawvisLoginItem.defaultApplied`: it
/// records that a launch-time step happened, so it survives a settings reset
/// and never travels with an exported settings blob. The rules for what it
/// means at launch are pure and tested (`FirstRunPolicy` in PawvisCore).
enum FirstRun {
    private static let completedKey = "Pawvis.firstRunCompleted"

    static var completed: Bool {
        UserDefaults.standard.bool(forKey: completedKey)
    }

    static func markCompleted() {
        UserDefaults.standard.set(true, forKey: completedKey)
    }
}

// MARK: - Opening the window from code

/// Opening the welcome window with no SwiftUI environment, same shape (and
/// same reason) as `GuideWindow`: the opener is captured at launch from the
/// `MenuBarExtra` label, the one view a menu-bar app always instantiates.
@MainActor
enum WelcomeWindow {
    static let id = "welcome"

    static var opener: OpenWindowAction?

    static func show() {
        opener?(id: id)
        // LSUIElement, so opening a window doesn't bring the app forward on
        // its own — see SettingsWindow for why activation happens twice.
        NSApp.activate(ignoringOtherApps: true)
        DispatchQueue.main.asyncAfter(deadline: .now() + 0.15) {
            NSApp.activate(ignoringOtherApps: true)
        }
    }
}

// MARK: - The welcome tour

/// The first-run window: what Pawvis is about to do, each permission asked
/// for in context (instead of a cold system dialog before any explanation),
/// and the two gestures that do most of the work — drawn with the same art
/// as the Gesture Guide. One compact page; the Start button at the bottom is
/// what actually starts tracking and marks the first run completed.
struct WelcomeView: View {
    let controller: PawvisController
    @Environment(\.dismiss) private var dismiss
    @Environment(\.openWindow) private var openWindow

    @State private var camera = Permissions.camera()
    @State private var accessibility = Permissions.accessibility()
    /// After the one-per-identity system prompt has been fired once, the
    /// accessibility button's job becomes opening the settings pane.
    @State private var accessibilityPrompted = false

    /// Neither permission posts a notification when granted, so poll while
    /// the window is open — the same trick as the controller's own
    /// permission polling, at the same kind of interval.
    private let refresh = Timer.publish(every: 1, on: .main, in: .common).autoconnect()

    var body: some View {
        VStack(alignment: .leading, spacing: 14) {
            header
            cameraCard
            accessibilityCard
            gesturesCard
            footer
        }
        .padding(22)
        .frame(width: 470)
        .tint(PawvisTheme.accentUI)
        .onReceive(refresh) { _ in
            camera = Permissions.camera()
            accessibility = Permissions.accessibility()
        }
    }

    // MARK: Header

    private static let clawGlyph = PawvisGlyph.claw(size: 26)

    private var header: some View {
        VStack(alignment: .leading, spacing: 6) {
            HStack(spacing: 10) {
                Group {
                    if let claw = Self.clawGlyph {
                        Image(nsImage: claw).renderingMode(.template)
                    } else {
                        Image(systemName: "pawprint.fill").font(.title)
                    }
                }
                .foregroundStyle(.tint)
                Text("Welcome to Pawvis").font(.title.bold())
            }
            Text("Pawvis turns your hand into the mouse. Three short steps and you're pointing.")
                .font(.callout)
                .foregroundStyle(.secondary)
                .fixedSize(horizontal: false, vertical: true)
        }
    }

    // MARK: Step 1 — camera

    private var cameraCard: some View {
        card(icon: "camera.fill", title: "Camera", trailing: { cameraAction }) {
            Text("Pawvis watches for your hand through the camera. Frames are processed in memory and discarded; nothing is recorded and nothing leaves your Mac.")
                .font(.callout)
                .foregroundStyle(.secondary)
                .fixedSize(horizontal: false, vertical: true)
            Text("The same frames show it your face: turn away and pointer, click and gesture actions pause until you look back — brief glances cost nothing, and voice control works with your back turned. It starts on; the switch is in Settings → Tracking.")
                .font(.callout)
                .foregroundStyle(.secondary)
                .fixedSize(horizontal: false, vertical: true)
            if camera == .denied {
                Text("Camera access was denied, so tracking can't run. Enable Pawvis under Privacy & Security → Camera.")
                    .font(.callout)
                    .foregroundStyle(.secondary)
                    .fixedSize(horizontal: false, vertical: true)
            }
        }
    }

    @ViewBuilder
    private var cameraAction: some View {
        switch camera {
        case .granted:
            grantedBadge
        case .notDetermined:
            Button("Continue") {
                Task {
                    _ = await Permissions.requestCamera()
                    camera = Permissions.camera()
                }
            }
        case .denied:
            Button("Open System Settings…") { Permissions.openCameraSettings() }
        }
    }

    // MARK: Step 2 — accessibility

    private var accessibilityCard: some View {
        card(icon: "cursorarrow.click", title: "Accessibility", trailing: { accessibilityAction }) {
            Text("Clicks need Accessibility. Tracking works without it, but clicks won't land until it's granted.")
                .font(.callout)
                .foregroundStyle(.secondary)
                .fixedSize(horizontal: false, vertical: true)
        }
    }

    @ViewBuilder
    private var accessibilityAction: some View {
        if accessibility == .granted {
            grantedBadge
        } else {
            // The system prompt only appears once per app identity; after
            // that, the useful action is the settings pane itself.
            Button(accessibilityPrompted ? "Open System Settings…" : "Grant Access") {
                if accessibilityPrompted {
                    Permissions.openAccessibilitySettings()
                } else {
                    Permissions.promptAccessibility()
                    accessibilityPrompted = true
                }
                accessibility = Permissions.accessibility()
            }
        }
    }

    // MARK: Step 3 — the two core gestures

    /// The same drawn panels as the Gesture Guide (bundle-only; the bare
    /// binary falls back to SF Symbols, exactly like the guide rows).
    private static let takeControlArt = PawvisGlyph.guidePanel("full-take-control", width: 96)
    private static let clickArt = PawvisGlyph.guidePanel("full-click", width: 96)

    private var gesturesCard: some View {
        card(icon: "hand.raised.fill", title: "Two gestures do most of it") {
            gestureRow(
                art: Self.takeControlArt,
                symbol: "hand.raised.fill",
                title: "Open hand takes control",
                caption: "All four fingers up, and the cursor rides your palm. A brief fist parks it.")
            gestureRow(
                art: Self.clickArt,
                symbol: "hand.point.up.left.fill",
                title: "Dip your index finger to click",
                caption: "Like tapping a mouse button. Keep the other fingers up; hold the dip to drag.")
            Text("Everything else is in the Gesture Guide: right-click, scroll, drags, custom gestures.")
                .font(.callout)
                .foregroundStyle(.secondary)
                .fixedSize(horizontal: false, vertical: true)
        }
    }

    private func gestureRow(art: NSImage?, symbol: String, title: String, caption: String) -> some View {
        HStack(alignment: .center, spacing: 12) {
            Group {
                if let art {
                    Image(nsImage: art).renderingMode(.template)
                } else {
                    Image(systemName: symbol).font(.title2)
                }
            }
            .foregroundStyle(.tint)
            .frame(width: 96, alignment: .leading)
            VStack(alignment: .leading, spacing: 2) {
                Text(title).font(.callout.weight(.semibold))
                Text(caption)
                    .font(.callout)
                    .foregroundStyle(.secondary)
                    .fixedSize(horizontal: false, vertical: true)
            }
        }
    }

    // MARK: Footer

    private var footer: some View {
        VStack(alignment: .leading, spacing: 10) {
            HStack {
                Button("Open the Gesture Guide") {
                    openWindow(id: GuideWindow.id)
                }
                Spacer()
                Button("Start tracking") {
                    FirstRun.markCompleted()
                    controller.startTracking()
                    dismiss()
                }
                .buttonStyle(.borderedProminent)
                .keyboardShortcut(.defaultAction)
                // With the camera denied outright, starting would do nothing
                // at all; the camera card explains and routes to System
                // Settings. (Not-determined is fine: Start asks in context.)
                .disabled(camera == .denied)
            }
            Text("Pawvis lives in the menu bar: click the claw to stop or start tracking, open Settings, or see this tour again.")
                .font(.caption)
                .foregroundStyle(.secondary)
                .fixedSize(horizontal: false, vertical: true)
        }
    }

    // MARK: Shared pieces

    private var grantedBadge: some View {
        Label("Granted", systemImage: "checkmark.circle.fill")
            .font(.callout.weight(.medium))
            .foregroundStyle(.green)
    }

    /// A step card in the Gesture Guide's row style: icon and title up top,
    /// the step's action on the trailing edge, full-width copy below (so
    /// text wraps instead of squeezing against a control column).
    private func card(
        icon: String,
        title: String,
        @ViewBuilder trailing: () -> some View = { EmptyView() },
        @ViewBuilder content: () -> some View
    ) -> some View {
        VStack(alignment: .leading, spacing: 6) {
            HStack(spacing: 8) {
                Image(systemName: icon)
                    .foregroundStyle(.tint)
                    .frame(width: 20)
                Text(title).font(.headline)
                Spacer()
                trailing()
            }
            content()
        }
        .padding(12)
        .frame(maxWidth: .infinity, alignment: .leading)
        .background(RoundedRectangle(cornerRadius: 10).fill(.quaternary.opacity(0.5)))
    }
}
