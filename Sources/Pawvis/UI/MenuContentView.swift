import PawvisCore
import SwiftUI

/// Readable buttons on the translucent menu material: always a solid chip
/// with high-contrast type. The chip colors are appearance-dynamic (see
/// `PawvisTheme.Chip`), so each one keeps its contrast on both menu
/// materials rather than splitting the difference with one fixed fill.
///
/// Hue carries meaning here, so keep it doing that: violet for the primary
/// action, sky for navigation, fuchsia for anything wanting attention, and
/// the quiet chip for what should stay out of the way.
struct PawvisButtonStyle: ButtonStyle {
    var chip: PawvisTheme.Chip = PawvisTheme.chipPurple
    @Environment(\.isEnabled) private var isEnabled

    func makeBody(configuration: Configuration) -> some View {
        let shape = RoundedRectangle(cornerRadius: 6)
        // Disabled swaps to the opaque muted chip rather than fading this
        // one: an alpha wash over the menu's vibrancy looks broken, not off.
        let chip = isEnabled ? chip : PawvisTheme.chipDisabled
        return configuration.label
            .font(.callout.weight(.medium))
            .padding(.horizontal, 10)
            .padding(.vertical, 4)
            .background(shape.fill(chip.fillUI))
            .overlay(chip.borderUI.map { shape.strokeBorder($0, lineWidth: 1) })
            .foregroundStyle(chip.textUI)
            .opacity(configuration.isPressed ? 0.7 : 1)
    }
}

/// The MenuBarExtra dropdown: live status, master toggles, permission
/// warnings, and navigation to settings / gesture guide.
struct MenuContentView: View {
    @ObservedObject var controller: PawvisController
    @ObservedObject var voice: VoiceController
    @ObservedObject var updater: UpdateChecker
    /// Same store `SettingsView`'s General tab reads and writes — passed
    /// directly (not through `controller.settingsStore`) so the picker below
    /// actually redraws when it writes to it. `PawvisController` doesn't
    /// forward `SettingsStore`'s `objectWillChange` (see `AppDelegate`'s
    /// comment on the same problem for `voice`), so observing it only through
    /// `controller` would leave the checkmark stale until the menu closed and
    /// reopened.
    @ObservedObject var settingsStore: SettingsStore
    @Environment(\.openSettings) private var openSettings
    @Environment(\.openWindow) private var openWindow
    @Environment(\.dismiss) private var dismiss

    var body: some View {
        VStack(alignment: .leading, spacing: 10) {
            header
            Divider()
            statusRows
            if !warnings.isEmpty {
                Divider()
                ForEach(warnings, id: \.text) { warning in
                    warningRow(warning)
                }
            }
            Divider()
            footer
        }
        .padding(12)
        .frame(width: 300)
        .tint(PawvisTheme.accentUI)
        .onAppear { controller.refreshPermissions() }
    }

    /// The same claw the status item shows, so the dropdown reads as an
    /// extension of the menu bar icon rather than a different animal.
    private static let clawGlyph = PawvisGlyph.claw(size: 17)

    private var header: some View {
        HStack {
            Group {
                if let claw = Self.clawGlyph {
                    Image(nsImage: claw).renderingMode(.template)
                } else {
                    Image(systemName: "pawprint.fill").font(.title3)
                }
            }
            .foregroundStyle(.tint)
            Text("Pawvis").font(.headline)
            Spacer()
            Toggle("", isOn: Binding(
                get: { controller.trackingActive },
                set: { _ in controller.toggleTracking() }))
                .toggleStyle(.switch)
                .labelsHidden()
                .help("Enable hand tracking")
        }
    }

    private var statusRows: some View {
        VStack(alignment: .leading, spacing: 6) {
            statusRow(
                icon: controller.cameraFailure == nil ? "hand.raised.fill" : "video.slash.fill",
                tint: trackingTint,
                text: trackingStatusText)

            if showCameraRow {
                cameraRow
            }

            HStack(spacing: 8) {
                Image(systemName: voiceIcon)
                    .foregroundStyle(voiceTint)
                    .frame(width: 18)
                Text(voiceStatusText)
                    .font(.callout)
                    .lineLimit(2)
                Spacer()
                Button(voice.state.isActive ? "Stop" : "Start") {
                    voice.toggle()
                }
                // Fuchsia while live: the mic being on is the one thing in
                // here worth catching an eye, and it earns the attention
                // color without the alarm-red reading of a stop button.
                .buttonStyle(PawvisButtonStyle(
                    chip: voice.state.isActive
                        ? PawvisTheme.chipFuchsia : PawvisTheme.chipPurple))
                .disabled(!controller.settingsStore.settings.voiceControl.enabled
                          && !voice.state.isActive)
            }

        }
    }

    private func statusRow(icon: String, tint: Color, text: String) -> some View {
        HStack(alignment: .top, spacing: 8) {
            Image(systemName: icon)
                .foregroundStyle(tint)
                .frame(width: 18)
            Text(text)
                .font(.callout)
                .fixedSize(horizontal: false, vertical: true) // wrap, never truncate
            Spacer()
        }
    }

    // MARK: - Camera picker

    /// Same enumeration `SettingsView`'s General tab uses — recomputed on
    /// every body evaluation, so a replug shows up the next time the menu
    /// opens without any extra observation plumbing.
    private var cameras: [(id: String, name: String)] { CameraManager.availableCameras() }

    /// Hidden in the common case (one camera, left on Automatic) where a
    /// picker would only ever offer the choice already in effect. Shown the
    /// moment there is an actual choice to make, or the moment the stored
    /// pick stops being the automatic default — including when that pick
    /// just disconnected, so it's never more than one click back to
    /// Automatic from here.
    private var showCameraRow: Bool {
        cameras.count >= 2 || settingsStore.settings.general.cameraDeviceID != nil
    }

    /// The picker plus, on Automatic while tracking, the camera it resolved
    /// to: the one line in the menu that says "this is your iPhone now"
    /// after macOS hands the session over, and "back on the built-in
    /// camera" once the phone walks away. A pinned camera needs no such
    /// line — the picker already names it.
    private var cameraRow: some View {
        VStack(alignment: .leading, spacing: 3) {
            cameraPickerRow
            if settingsStore.settings.general.cameraDeviceID == nil,
               controller.trackingActive,
               let name = controller.activeCameraName {
                Text("Using \(name)")
                    .font(.caption)
                    .foregroundStyle(.secondary)
                    .fixedSize(horizontal: false, vertical: true)
                    .padding(.leading, 26)
            }
        }
    }

    /// Quick camera switch. A picker row, not a chip (AGENTS.md: hue is
    /// meaning, and this row means nothing by color), so it keeps the
    /// menu's plain icon/text/control shape instead of `PawvisButtonStyle`.
    /// Reads and writes `settings.general.cameraDeviceID` directly, the
    /// exact setting Settings → General's picker uses, so the two views can
    /// never disagree about which camera is selected.
    private var cameraPickerRow: some View {
        HStack(spacing: 8) {
            Image(systemName: "camera.fill")
                .foregroundStyle(.secondary)
                .frame(width: 18)
            Text("Camera")
                .font(.callout)
            Spacer()
            Picker("", selection: Binding(
                get: { settingsStore.settings.general.cameraDeviceID ?? "" },
                set: { settingsStore.settings.general.cameraDeviceID = $0.isEmpty ? nil : $0 })
            ) {
                Text("Automatic").tag("")
                ForEach(cameras, id: \.id) { camera in
                    Text(camera.name).tag(camera.id)
                }
                // The selected device vanished (unplugged, or a Continuity
                // Camera that walked away). Rather than quietly relabeling
                // the row "Automatic" while the stored ID still points at
                // the missing camera, give that ID its own checkmarked
                // entry — the honest state of the setting, not a guess.
                if let selected = settingsStore.settings.general.cameraDeviceID,
                   !cameras.contains(where: { $0.id == selected }) {
                    Text("Unavailable — \(selected)").tag(selected)
                }
            }
            .labelsHidden()
            .pickerStyle(.menu)
            .frame(maxWidth: 160)
        }
    }

    private struct Warning {
        let text: String
        let action: String
        let handler: () -> Void
    }

    private var warnings: [Warning] {
        var result: [Warning] = []
        if controller.cameraPermission == .denied {
            result.append(Warning(
                text: "Camera access is denied — hand tracking can't run.",
                action: "Open Settings",
                handler: { Permissions.openCameraSettings() }))
        }
        if controller.trackingActive, !controller.accessibilityGranted {
            result.append(Warning(
                text: "Clicks are blocked: grant Pawvis Accessibility in System Settings → Privacy & Security. If it already shows as enabled there, remove it and add it again.",
                action: "Open…",
                handler: {
                    Permissions.promptAccessibility()
                    Permissions.openAccessibilitySettings()
                }))
        }
        if updater.updateAvailable, case .available(let release) = updater.state {
            result.append(Warning(
                text: "Pawvis \(release.version.description) is available.",
                action: "Update…",
                handler: { openSettingsInFront(tab: .about) }))
        }
        if voice.state.isActive,
           controller.settingsStore.settings.voiceControl.visualContextEnabled,
           Permissions.screenRecording() != .granted {
            result.append(Warning(
                text: "Grant Screen Recording so visual commands (“Pawvis click sign in”) can see the screen. Everything else works without it.",
                action: "Open…",
                handler: { Permissions.openScreenRecordingSettings() }))
        }
        return result
    }

    private func warningRow(_ warning: Warning) -> some View {
        HStack(alignment: .top, spacing: 8) {
            Image(systemName: "exclamationmark.triangle.fill")
                .foregroundStyle(.yellow)
                .frame(width: 18)
            Text(warning.text)
                .font(.caption)
                .fixedSize(horizontal: false, vertical: true)
            Spacer()
            Button(warning.action, action: warning.handler)
                .buttonStyle(PawvisButtonStyle(chip: PawvisTheme.chipFuchsia))
        }
    }

    /// Sky for Settings, violet for the guide, and Quit on the quiet chip:
    /// leaving is mundane, not dangerous, so it gets the least ink in the
    /// row rather than a red slab. Three chips is what this width holds; the
    /// welcome tour lives in Settings → About instead, because a walkthrough
    /// a new install already gets automatically is something you replay once,
    /// not a daily destination worth a permanent seat in the menu.
    private var footer: some View {
        HStack {
            Button("Settings…") { openSettingsInFront() }
                .buttonStyle(PawvisButtonStyle(chip: PawvisTheme.chipBlue))
            Button("Gesture Guide") {
                dismiss() // close the menu bar popover — it floats above windows
                openWindow(id: GuideWindow.id)
                NSApp.activate(ignoringOtherApps: true)
            }
            Spacer()
            Button("Quit") {
                NSApplication.shared.terminate(nil)
            }
            .buttonStyle(PawvisButtonStyle(chip: PawvisTheme.chipQuiet))
        }
        .buttonStyle(PawvisButtonStyle())
    }

    /// Dismisses the menu bar popover first — it floats above regular windows
    /// and would otherwise hover over Settings — then opens Settings and drags
    /// it in front (see `SettingsWindow`, which owns the LSUIElement fix).
    ///
    /// `openSettings` is used here rather than `SettingsWindow.show()` because
    /// a view has the real environment action available; the selector path is
    /// for callers that don't.
    private func openSettingsInFront(tab: SettingsTab? = nil) {
        dismiss()
        if let tab { SettingsRouter.shared.tab = tab }
        NSApp.activate(ignoringOtherApps: true)
        openSettings()
        SettingsWindow.bringToFront()
    }

    // MARK: - Status text

    /// Red only for genuine errors, where it means what it says — and a dead
    /// camera is one: the menu must not claim tracking while no frames come.
    private var trackingTint: Color {
        if controller.cameraFailure != nil { return .red }
        return controller.handsDetected > 0 ? .green : .secondary
    }

    private var trackingStatusText: String {
        // Camera trouble beats every happier status: this line is the copy
        // that persists after the overlay pill times out.
        if let failure = controller.cameraFailure { return failure }
        guard controller.trackingActive else { return "Tracking off" }
        // Paused (the lock screen), not stopped: the toggle stays on, and
        // the reason takes the status line until tracking resumes.
        if let reason = controller.pauseReason { return reason }
        // Look-to-control: the camera is fine and hands may be in view, but
        // actions wait for the user to face the screen again.
        if controller.attentionPaused { return "Paused until you face the screen" }
        switch controller.handsDetected {
        case 0: return "No hands in view"
        case 1: return modeText
        default: return "\(controller.handsDetected) hands · \(modeText)"
        }
    }

    private var modeText: String {
        if controller.settingsStore.settings.gestures.controlTrigger == .gesturesOnly {
            return "Watching for gestures"
        }
        if controller.grabbing { return "Clicking" }
        return controller.controlArmed ? "Pointing" : "Show an open hand to control"
    }

    private var voiceStatusText: String {
        let wakeWord = controller.settingsStore.settings.voiceControl.wakeWord
        switch voice.state {
        case .off: return "Voice control (beta) off"
        case .connecting: return "Voice control starting…"
        case .listening: return "Listening for “\(wakeWord) …”"
        case .resolving: return "Working on your command…"
        case .working(let line): return line
        case .error(let message): return message
        }
    }

    private var voiceIcon: String {
        switch voice.state {
        case .resolving, .working: return "sparkles"
        case .error: return "mic.slash.fill"
        default: return "mic.fill"
        }
    }

    /// The mic glyph tracks the Start/Stop chip beside it: fuchsia once the
    /// mic is live, accent violet while a command is being worked out. Red
    /// stays for genuine errors, where it means what it says.
    private var voiceTint: Color {
        switch voice.state {
        case .off: return .secondary
        case .connecting, .listening: return PawvisTheme.attentionUI
        case .resolving, .working: return PawvisTheme.accentUI
        case .error: return .red
        }
    }

}
