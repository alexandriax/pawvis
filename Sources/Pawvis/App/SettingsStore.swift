import Combine
import Foundation
import PawvisCore

/// Persists `PawvisSettings` in UserDefaults (JSON, tolerant decode).
@MainActor
final class SettingsStore: ObservableObject {
    private static let defaultsKey = "PawvisSettings.v1"

    @Published var settings: PawvisSettings {
        didSet { persist() }
    }

    init() {
        if let data = UserDefaults.standard.data(forKey: Self.defaultsKey),
           let decoded = try? JSONDecoder().decode(PawvisSettings.self, from: data) {
            settings = decoded
        } else {
            settings = .default
        }
        migrate()
    }

    /// One-time migrations for settings persisted by older builds.
    /// (There are none at present: retirement happens in the tolerant
    /// decoders instead. Dictation-era keys — engine, model, API key — are
    /// absorbed by PawvisSettings, which maps the legacy `dictation` section
    /// onto `voiceControl` and no longer reads the OpenAI keychain entry;
    /// retired gesture keys — pointer source, the click-gesture picker whose
    /// mouse-tap mode won and became the only click — are simply ignored.)
    private func migrate() {}

    private func persist() {
        if let data = try? JSONEncoder().encode(settings) {
            UserDefaults.standard.set(data, forKey: Self.defaultsKey)
        }
    }
}
