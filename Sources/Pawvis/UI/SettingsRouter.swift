import AppKit
import Combine
import SwiftUI

/// The Settings window's tabs, named so that code outside SwiftUI can ask for
/// one by name.
enum SettingsTab: String, Hashable {
    case general, tracking, gestures, custom, voice, about
}

/// Opens the Settings window on a chosen tab from places that have no SwiftUI
/// environment to reach `openSettings` through — the app delegate, and the
/// notification-center callback behind the update banner's button.
///
/// The selected tab is state rather than an argument because the window may
/// already be open on another tab: setting `tab` first means both the cold
/// open and the "it's already up" case land on the same page.
@MainActor
final class SettingsRouter: ObservableObject {
    static let shared = SettingsRouter()

    /// Taking the `TabView`'s selection over means SwiftUI stops restoring the
    /// last-viewed tab for us (that's `com_apple_SwiftUI_Settings_selectedTabIndex`,
    /// which only exists while the selection is unbound), so remember it here
    /// instead rather than silently dropping the behavior.
    private static let lastTabKey = "Pawvis.settings.tab"

    @Published var tab: SettingsTab {
        didSet { UserDefaults.standard.set(tab.rawValue, forKey: Self.lastTabKey) }
    }

    private init() {
        tab = UserDefaults.standard.string(forKey: Self.lastTabKey)
            .flatMap(SettingsTab.init) ?? .general
    }

    func open(_ tab: SettingsTab) {
        self.tab = tab
        SettingsWindow.show()
    }
}
