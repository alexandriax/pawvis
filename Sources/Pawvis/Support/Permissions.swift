import AVFoundation
import AppKit
import ApplicationServices

/// Snapshot + helpers for the permissions Pawvis needs:
/// camera (hand tracking), accessibility (posting mouse/keyboard events),
/// microphone (voice control), and screen recording (visual voice commands
/// only — everything else works without it).
enum Permissions {
    enum Status: Equatable {
        case granted, denied, notDetermined
    }

    static func camera() -> Status {
        switch AVCaptureDevice.authorizationStatus(for: .video) {
        case .authorized: return .granted
        case .notDetermined: return .notDetermined
        default: return .denied
        }
    }

    static func microphone() -> Status {
        switch AVCaptureDevice.authorizationStatus(for: .audio) {
        case .authorized: return .granted
        case .notDetermined: return .notDetermined
        default: return .denied
        }
    }

    static func accessibility() -> Status {
        AXIsProcessTrusted() ? .granted : .denied
    }

    static func screenRecording() -> Status {
        CGPreflightScreenCaptureAccess() ? .granted : .denied
    }

    /// Shows the system screen-recording prompt (once per app identity).
    static func requestScreenRecording() {
        _ = CGRequestScreenCaptureAccess()
    }

    static func requestCamera() async -> Bool {
        await AVCaptureDevice.requestAccess(for: .video)
    }

    static func requestMicrophone() async -> Bool {
        await AVCaptureDevice.requestAccess(for: .audio)
    }

    /// Shows the system accessibility prompt (once per app identity).
    static func promptAccessibility() {
        let options = [kAXTrustedCheckOptionPrompt.takeUnretainedValue() as String: true] as CFDictionary
        AXIsProcessTrustedWithOptions(options)
    }

    static func openAccessibilitySettings() {
        if let url = URL(string: "x-apple.systempreferences:com.apple.preference.security?Privacy_Accessibility") {
            NSWorkspace.shared.open(url)
        }
    }

    static func openCameraSettings() {
        if let url = URL(string: "x-apple.systempreferences:com.apple.preference.security?Privacy_Camera") {
            NSWorkspace.shared.open(url)
        }
    }

    static func openMicrophoneSettings() {
        if let url = URL(string: "x-apple.systempreferences:com.apple.preference.security?Privacy_Microphone") {
            NSWorkspace.shared.open(url)
        }
    }

    static func openScreenRecordingSettings() {
        if let url = URL(string: "x-apple.systempreferences:com.apple.preference.security?Privacy_ScreenCapture") {
            NSWorkspace.shared.open(url)
        }
    }

    /// System Settings → Notifications, where the update banner is switched on
    /// and off. Not a Privacy & Security pane like the others, hence its own
    /// extension identifier.
    static func openNotificationSettings() {
        if let url = URL(string: "x-apple.systempreferences:com.apple.Notifications-Settings.extension") {
            NSWorkspace.shared.open(url)
        }
    }
}
