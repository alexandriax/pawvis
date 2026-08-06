import PawvisCore
import SwiftUI

/// The MenuBarExtra dropdown: live status, master toggles, permission
/// warnings, and navigation to settings / gesture guide.
struct MenuContentView: View {
    @ObservedObject var controller: PawvisController
    @ObservedObject var dictation: DictationController
    @Environment(\.openSettings) private var openSettings
    @Environment(\.openWindow) private var openWindow

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
                .controlSize(.small)
                .disabled(!controller.settingsStore.settings.dictation.enabled
                          && !dictation.state.isActive)
            }

            if controller.settingsStore.settings.gestures.dictationToggle != .off {
                Text("Tip: \(dictationGestureHint)")
                    .font(.caption2)
                    .foregroundStyle(.secondary)
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
                text: "Accessibility permission needed to move the cursor and click.",
                action: "Grant…",
                handler: {
                    Permissions.promptAccessibility()
                    Permissions.openAccessibilitySettings()
                }))
        }
        if !controller.settingsStore.apiKeyAvailable,
           controller.settingsStore.settings.dictation.enabled {
            result.append(Warning(
                text: "Add an OpenAI API key to enable voice dictation.",
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
                .controlSize(.small)
        }
    }

    private var footer: some View {
        HStack {
            Button("Settings…") { openSettings() }
            Button("Gesture Guide") {
                openWindow(id: "gesture-guide")
                NSApp.activate(ignoringOtherApps: true)
            }
            Spacer()
            Button("Quit") {
                NSApplication.shared.terminate(nil)
            }
        }
        .controlSize(.small)
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
        switch controller.mode {
        case .none: return "Tracking"
        case .pointing: return "Pointing"
        case .scrolling: return "Scrolling"
        case .clutch: return "Clutched (cursor parked)"
        }
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

    private var dictationGestureHint: String {
        switch controller.settingsStore.settings.gestures.dictationToggle {
        case .oneHandSplayHold: return "hold an open, spread hand to toggle dictation"
        case .twoHandSplay: return "show two open hands to toggle dictation"
        case .shakaHold: return "hold a shaka 🤙 to toggle dictation"
        case .off: return ""
        }
    }
}
