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
    /// (Dictation-era keys — engine, model, API key — are handled by the
    /// tolerant decoder in PawvisSettings, which maps the legacy `dictation`
    /// section onto `voiceControl`. The OpenAI keychain entry is simply no
    /// longer read; voice control is fully on-device.)
    private func migrate() {
        let defaults = UserDefaults.standard
        // v5: whole-hand pinch proved the most reliable mode in testing and
        // became the default; move users still on the old pinch default.
        if !defaults.bool(forKey: "PawvisMigration.wholeHandDefault") {
            if settings.gestures.clickGesture == .pinch {
                settings.gestures.clickGesture = .wholeHandPinch
            }
            defaults.set(true, forKey: "PawvisMigration.wholeHandDefault")
        }
        // v6: the mouse-tap mode superseded it as the preferred default.
        if !defaults.bool(forKey: "PawvisMigration.indexTapDefault") {
            if settings.gestures.clickGesture == .wholeHandPinch {
                settings.gestures.clickGesture = .indexTap
            }
            defaults.set(true, forKey: "PawvisMigration.indexTapDefault")
        }
        // v7: voice control entered beta — off until explicitly enabled,
        // including for settings persisted by pre-beta builds.
        if !defaults.bool(forKey: "PawvisMigration.voiceBetaOff") {
            settings.voiceControl.enabled = false
            defaults.set(true, forKey: "PawvisMigration.voiceBetaOff")
        }
    }

    private func persist() {
        if let data = try? JSONEncoder().encode(settings) {
            UserDefaults.standard.set(data, forKey: Self.defaultsKey)
        }
    }
}
