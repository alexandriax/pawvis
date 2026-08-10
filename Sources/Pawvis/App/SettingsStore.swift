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
    /// (Most retirement happens in the tolerant decoders instead. Dictation-era
    /// keys — engine, model, API key — are absorbed by PawvisSettings, which
    /// maps the legacy `dictation` section onto `voiceControl` and no longer
    /// reads the OpenAI keychain entry; retired gesture keys — pointer source,
    /// the click-gesture picker whose mouse-tap mode won and became the only
    /// click — are simply ignored.)
    private func migrate() {
        let defaults = UserDefaults.standard
        // v7: voice control entered beta — off until explicitly enabled,
        // including for settings persisted by pre-beta builds.
        if !defaults.bool(forKey: "PawvisMigration.voiceBetaOff") {
            settings.voiceControl.enabled = false
            defaults.set(true, forKey: "PawvisMigration.voiceBetaOff")
        }
        // v8: the open-hand floor came down after field testing. A new default
        // alone would only reach fresh installs — every existing settings file
        // has the old number written into it — so installs still on the
        // retired floor follow it down, once. A dialed-in strictness stays put.
        if !defaults.bool(forKey: "PawvisMigration.retunedOpenHandFloor") {
            settings.gestures.poseThresholds.adoptRetunedOpenHandFloor()
            defaults.set(true, forKey: "PawvisMigration.retunedOpenHandFloor")
        }
    }

    private func persist() {
        if let data = try? JSONEncoder().encode(settings) {
            UserDefaults.standard.set(data, forKey: Self.defaultsKey)
        }
    }
}
