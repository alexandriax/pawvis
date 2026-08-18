import AppKit
import Foundation
import PawvisCore

/// Performs a `GestureAction` when its bound custom gesture fires, and
/// reports a short line for the status pill. Key chords go through the same
/// `TextTyper` voice control uses, window actions through `WindowPlacer`,
/// app launches through the same `AppCatalog` fuzzy resolution as "Pawvis,
/// open Safari" — one behavior per capability, however it was invoked.
@MainActor
final class GestureActionRunner {
    /// Wired by `PawvisController`: the two actions that reach back into
    /// Pawvis itself rather than out into the system.
    var stopTracking: (() -> Void)?
    var toggleVoiceControl: (() -> Void)?
    /// A long-running action finished after `perform` returned: the outcome
    /// line replaces the provisional one in the pill.
    var onFollowUp: ((String) -> Void)?

    private let typer = TextTyper()
    private let placer = WindowPlacer()
    private let spaces = SpaceSwitcher()

    /// Perform the action; the return value is what the status pill flashes.
    func perform(_ action: GestureAction) -> String {
        switch action.kind {
        case .playPause:
            typer.press(MediaKey.playPause)
            return action.feedback

        case .volumeUp:
            typer.press(MediaKey.volumeUp)
            return action.feedback

        case .volumeDown:
            typer.press(MediaKey.volumeDown)
            return action.feedback

        case .volumeMute:
            typer.press(MediaKey.volumeMute)
            return action.feedback

        case .brightnessUp:
            typer.press(MediaKey.brightnessUp)
            return action.feedback

        case .brightnessDown:
            typer.press(MediaKey.brightnessDown)
            return action.feedback

        case .desktopLeft, .desktopRight:
            // Not a key press: macOS ignores synthetic ⌃←/⌃→ for Spaces
            // (see SpaceSwitcher for the measured story and the mechanism).
            let direction: SpaceSwitcher.Direction =
                action.kind == .desktopLeft ? .left : .right
            Task { [weak self] in
                guard let self else { return }
                self.onFollowUp?(await self.spaces.switchDesktop(direction))
            }
            return action.kind == .desktopLeft ? "Desktop left…" : "Desktop right…"

        case .windowLeftHalf, .windowRightHalf, .windowTopHalf, .windowBottomHalf,
             .windowLeftTwoThirds, .windowRightTwoThirds, .windowLeftThird, .windowRightThird,
             .windowTopLeftQuarter, .windowTopRightQuarter,
             .windowBottomLeftQuarter, .windowBottomRightQuarter,
             .windowMaximize, .windowCenter, .windowMinimize, .windowNextDisplay:
            return placer.perform(action.kind) ? action.feedback : "No window to move"

        case .stopTracking:
            stopTracking?()
            return action.feedback

        case .toggleVoiceControl:
            toggleVoiceControl?()
            return action.feedback

        case .openApp:
            return openApp(named: action.argument)

        case .runShellCommand:
            return runShellCommand(action.argument)

        case .keyboardShortcut:
            guard let chord = action.keyChord, TextTyper.canPress(chord) else {
                return "Shortcut “\(action.argument)” not understood"
            }
            typer.press(chord)
            return action.feedback

        default:
            // Everything else is a plain key chord (desktops, navigation).
            guard let chord = action.keyChord else { return action.feedback }
            typer.press(chord)
            return action.feedback
        }
    }

    private func openApp(named name: String) -> String {
        let trimmed = name.trimmingCharacters(in: .whitespaces)
        guard !trimmed.isEmpty else { return "No app configured" }
        guard let url = AppCatalog.resolve(spokenName: trimmed) else {
            return "Couldn't find “\(trimmed)”"
        }
        let configuration = NSWorkspace.OpenConfiguration()
        configuration.activates = true
        NSWorkspace.shared.openApplication(at: url, configuration: configuration) { _, error in
            if let error {
                Log.app.error("Gesture openApp \(trimmed) failed: \(error.localizedDescription)")
            }
        }
        return "Opening \(url.deletingPathExtension().lastPathComponent)"
    }

    /// Fire-and-forget through a login shell, so the user's PATH (brew and
    /// friends) applies — this is the "assign a gesture to anything" escape
    /// hatch, and it runs exactly what was typed into Settings, as the user.
    private func runShellCommand(_ command: String) -> String {
        let trimmed = command.trimmingCharacters(in: .whitespacesAndNewlines)
        guard !trimmed.isEmpty else { return "No command configured" }
        let process = Process()
        process.executableURL = URL(fileURLWithPath: "/bin/zsh")
        process.arguments = ["-lc", trimmed]
        process.standardOutput = FileHandle.nullDevice
        process.standardError = FileHandle.nullDevice
        process.terminationHandler = { p in
            if p.terminationStatus != 0 {
                Log.app.error("Gesture command exited \(p.terminationStatus): \(trimmed)")
            }
        }
        do {
            try process.run()
        } catch {
            Log.app.error("Gesture command failed to launch: \(error.localizedDescription)")
            return "Command failed to launch"
        }
        let summary = trimmed.count > 32 ? String(trimmed.prefix(32)) + "…" : trimmed
        return "Ran: \(summary)"
    }
}
