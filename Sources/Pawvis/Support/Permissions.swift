import AVFoundation
import AppKit
import ApplicationServices

/// Snapshot + helpers for the three permissions Pawvis needs:
/// camera (hand tracking), accessibility (posting mouse/keyboard events),
/// microphone (dictation only).
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
}
