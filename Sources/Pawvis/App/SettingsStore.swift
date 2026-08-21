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
    /// reads the OpenAI keychain entry; the retired click-gesture picker key,
    /// whose mouse-tap mode won and became the only click, is simply ignored.
    /// `pointerSource` is live again as the accessibility pointer setting —
    /// its pre-v0.1.0 ancestor never shipped in a release, so there is no
    /// stored value to collide with.)
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
        // v9: look-to-control became the default. Same reasoning as v8 — a
        // new default alone reaches fresh installs only, because every
        // settings file written since v0.27.0 has the old `false` in it —
        // but a bool keeps no record of *why* it is off, so unlike the
        // open-hand floor this cannot spare a deliberate one. It runs once,
        // two days into the life of the shipped feature, and the toggle in
        // Tracking is one click away for anyone who wants it back off.
        if !defaults.bool(forKey: "PawvisMigration.attentionOnByDefault") {
            settings.attention.enabled = true
            defaults.set(true, forKey: "PawvisMigration.attentionOnByDefault")
        }
    }

    private func persist() {
        if let data = try? JSONEncoder().encode(settings) {
            UserDefaults.standard.set(data, forKey: Self.defaultsKey)
        }
    }
}
