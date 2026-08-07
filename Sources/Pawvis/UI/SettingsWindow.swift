import AppKit

/// Opening and fronting the SwiftUI `Settings` scene.
///
/// Pawvis is `LSUIElement`, so opening a window does not activate the app and
/// Settings appeared *behind* whatever the user was working in. Every path that
/// opens Settings goes through here so that fix stays in one place.
@MainActor
enum SettingsWindow {

    /// Opens Settings from code with no SwiftUI environment to reach
    /// `openSettings` through — the notification-center callback behind the
    /// update banner's button runs on the app delegate, not in a view, and in
    /// the cold-start case no view of ours has ever been instantiated.
    ///
    /// SwiftUI installs `showSettingsWindow:` in the responder chain for a
    /// `Settings` scene; `showPreferencesWindow:` is its pre-Ventura name, kept
    /// as a fallback rather than a version check.
    static func show() {
        if !NSApp.sendAction(Selector(("showSettingsWindow:")), to: nil, from: nil) {
            _ = NSApp.sendAction(Selector(("showPreferencesWindow:")), to: nil, from: nil)
        }
        bringToFront()
    }

    /// Activates the app and fronts the Settings window. Activation happens on
    /// both sides of the delay because the window is created asynchronously:
    /// the first call wins the app the focus, the second catches the window
    /// once it exists.
    static func bringToFront() {
        NSApp.activate(ignoringOtherApps: true)
        DispatchQueue.main.asyncAfter(deadline: .now() + 0.08) {
            NSApp.activate(ignoringOtherApps: true)
            NSApp.windows
                .first { $0.title.hasSuffix("Settings") && $0.isVisible }?
                .makeKeyAndOrderFront(nil)
        }
    }
}
