import AppKit
import SwiftUI

/// Opening and fronting the SwiftUI `Settings` scene from code that has no
/// SwiftUI environment — the notification-center callback behind the update
/// banner's button runs on the app delegate, not in a view, and in the
/// cold-start case no Settings view has ever been instantiated.
///
/// Two facts, both measured on macOS 26, shape this type:
///
/// - `NSApp.sendAction(Selector(("showSettingsWindow:")))` **returns true and
///   opens nothing**, so there is no responder-chain shortcut and no branching
///   on its return value. The reliable cold-start openers are the real
///   `OpenSettingsAction` — captured at launch from the `MenuBarExtra` label,
///   the one view a menu-bar app always instantiates — and, as a fallback, the
///   "Settings…" item SwiftUI installs in the app menu even for LSUIElement
///   apps.
/// - The Settings window's *title* is the selected tab's name ("About", not
///   "…Settings"), so windows are matched by SwiftUI's stable identifier
///   instead. No `isVisible` in the predicate: after a close the NSWindow
///   sticks around invisible, and that's exactly the window to re-front.
@MainActor
enum SettingsWindow {

    /// Stashed by the `MenuBarExtra` label's `onAppear`, which fires at launch
    /// before anything could want Settings open.
    static var opener: OpenSettingsAction?

    private static let windowID = "com_apple_SwiftUI_Settings_window"

    static func show() {
        // Open first, then activate — activation "sticks" and applies to the
        // window once it exists, but an activate-only pass opens nothing.
        if let opener {
            opener()
        } else if let (menu, index) = settingsMenuItem() {
            menu.performActionForItem(at: index)
        }
        bringToFront()
    }

    /// Pawvis is `LSUIElement`, so opening a window does not activate the app
    /// and Settings would appear *behind* the user's work. Activation happens
    /// on both sides of a delay because the window is created asynchronously:
    /// the first call wins the app the focus, the later ones catch the window
    /// once it's registered (measured: it isn't in `NSApp.windows` at call
    /// time, and a close→reopen can still miss the first deferred hop).
    static func bringToFront() {
        NSApp.activate(ignoringOtherApps: true)
        for delay in [0.08, 0.25] {
            DispatchQueue.main.asyncAfter(deadline: .now() + delay) {
                NSApp.activate(ignoringOtherApps: true)
                NSApp.windows
                    .first { $0.identifier?.rawValue == windowID }?
                    .makeKeyAndOrderFront(nil)
            }
        }
    }

    private static func settingsMenuItem() -> (NSMenu, Int)? {
        guard let appMenu = NSApp.mainMenu?.items.first?.submenu,
              let index = appMenu.items.firstIndex(where: {
                  $0.title.hasPrefix("Settings") || $0.title.hasPrefix("Preferences")
              }) else { return nil }
        return (appMenu, index)
    }
}
