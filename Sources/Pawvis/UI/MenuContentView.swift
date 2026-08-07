import PawvisCore
import SwiftUI

/// Readable buttons on the translucent menu material: white text on a solid
/// purple chip in dark mode, purple text on a faint purple chip in light mode.
/// (Plain purple text was illegible against the dark vibrancy background.)
struct PawvisButtonStyle: ButtonStyle {
    @Environment(\.colorScheme) private var scheme

    func makeBody(configuration: Configuration) -> some View {
        configuration.label
            .font(.callout.weight(.medium))
            .padding(.horizontal, 10)
            .padding(.vertical, 4)
            .background(
                RoundedRectangle(cornerRadius: 6)
                    .fill(scheme == .dark
                          ? PawvisTheme.purpleUI
                          : PawvisTheme.purpleUI.opacity(0.14)))
            .foregroundStyle(scheme == .dark ? Color.white : PawvisTheme.purpleUI)
            .opacity(configuration.isPressed ? 0.7 : 1)
    }
}

/// The MenuBarExtra dropdown: live status, master toggles, permission
/// warnings, and navigation to settings / gesture guide.
struct MenuContentView: View {
    @ObservedObject var controller: PawvisController
    @ObservedObject var dictation: DictationController
    @ObservedObject var updater: UpdateChecker
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
        .tint(PawvisTheme.purpleUI)
        .onAppear { controller.refreshPermissions() }
    }

    private var header: some View {
        HStack {
            Image(systemName: "pawprint.fill")
                .font(.title3)
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
                icon: "hand.raised.fill",
                tint: controller.handsDetected > 0 ? .green : .secondary,
                text: trackingStatusText)

            HStack(spacing: 8) {
                Image(systemName: dictationIcon)
                    .foregroundStyle(dictationTint)
                    .frame(width: 18)
                Text(dictationStatusText)
                    .font(.callout)
                    .lineLimit(2)
                Spacer()
                Button(dictation.state.isActive ? "Stop" : "Start") {
                    dictation.toggle()
                }
                .buttonStyle(PawvisButtonStyle())
                .disabled(!controller.settingsStore.settings.dictation.enabled
                          && !dictation.state.isActive)
            }

        }
    }

    private func statusRow(icon: String, tint: Color, text: String) -> some View {
        HStack(spacing: 8) {
            Image(systemName: icon)
                .foregroundStyle(tint)
                .frame(width: 18)
            Text(text).font(.callout)
            Spacer()
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
                text: "Clicks are blocked: grant Accessibility. If Pawvis already shows as enabled there, remove it and re-add it (rebuilds invalidate the old grant).",
                action: "Open…",
                handler: {
                    Permissions.promptAccessibility()
                    Permissions.openAccessibilitySettings()
                }))
        }
        // Only meaningful once the (lazy, prompt-causing) keychain status has
        // been loaded — opening the menu must never trigger a keychain prompt.
        if updater.updateAvailable, case .available(let release) = updater.state {
            result.append(Warning(
                text: "Pawvis \(release.version.description) is available.",
                action: "Update…",
                handler: { openSettingsInFront() }))
        }
        if controller.settingsStore.keyStatusLoaded,
           !controller.settingsStore.apiKeyAvailable,
           controller.settingsStore.settings.dictation.enabled,
           controller.settingsStore.settings.dictation.engine == "openai" {
            result.append(Warning(
                text: "Add an OpenAI API key to enable cloud dictation.",
                action: "Settings…",
                handler: { openSettings() }))
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
                .buttonStyle(PawvisButtonStyle())
        }
    }

    private var footer: some View {
        HStack {
            Button("Settings…") { openSettingsInFront() }
            Button("Gesture Guide") {
                dismiss() // close the menu bar popover — it floats above windows
                openWindow(id: "gesture-guide")
                NSApp.activate(ignoringOtherApps: true)
            }
            Spacer()
            Button("Quit") {
                NSApplication.shared.terminate(nil)
            }
        }
        .buttonStyle(PawvisButtonStyle())
    }

    /// LSUIElement apps don't activate when a window opens, so the Settings
    /// window appeared behind whatever the user was working in. Activate on
    /// both sides of the open and front the window explicitly. Also dismiss
    /// the menu bar popover first — it floats above regular windows and would
    /// otherwise hover over Settings.
    private func openSettingsInFront() {
        dismiss()
        NSApp.activate(ignoringOtherApps: true)
        openSettings()
        DispatchQueue.main.asyncAfter(deadline: .now() + 0.08) {
            NSApp.activate(ignoringOtherApps: true)
            NSApp.windows
                .first { $0.title.hasSuffix("Settings") && $0.isVisible }?
                .makeKeyAndOrderFront(nil)
        }
    }

    // MARK: - Status text

    private var trackingStatusText: String {
        guard controller.trackingActive else { return "Tracking off" }
        switch controller.handsDetected {
        case 0: return "No hands in view"
        case 1: return modeText
        default: return "\(controller.handsDetected) hands · \(modeText)"
        }
    }

    private var modeText: String {
        if controller.grabbing { return "Clicking (pinched)" }
        return controller.controlArmed ? "Pointing" : "Show an open hand to control"
    }

    private var dictationStatusText: String {
        switch dictation.state {
        case .off: return "Dictation off"
        case .connecting: return "Dictation connecting…"
        case .listening: return "Listening for wake word"
        case .dictating: return "Dictating — typing your words"
        case .error(let message): return message
        }
    }

    private var dictationIcon: String {
        switch dictation.state {
        case .dictating: return "keyboard.fill"
        case .error: return "mic.slash.fill"
        default: return "mic.fill"
        }
    }

    private var dictationTint: Color {
        switch dictation.state {
        case .off: return .secondary
        case .connecting: return .orange
        case .listening: return .orange
        case .dictating: return .red
        case .error: return .red
        }
    }

}
