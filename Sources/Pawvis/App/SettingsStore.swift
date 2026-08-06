import Combine
import Foundation
import PawvisCore

/// Persists `PawvisSettings` in UserDefaults (JSON, tolerant decode) and the
/// OpenAI API key in the Keychain.
@MainActor
final class SettingsStore: ObservableObject {
    private static let defaultsKey = "PawvisSettings.v1"

    @Published var settings: PawvisSettings {
        didSet { persist() }
    }

    /// Whether an API key is available from any source (keychain/env/.env).
    /// Meaningful only after `ensureKeyStatusLoaded()` has run.
    @Published private(set) var apiKeyAvailable = false
    /// Whether the key came from the keychain (i.e., user-entered in the UI).
    @Published private(set) var apiKeyInKeychain = false
    /// Keychain access can show a system permission prompt, so the key status
    /// is loaded lazily — only when the OpenAI engine is actually in play —
    /// and at most once per launch.
    @Published private(set) var keyStatusLoaded = false

    private let keychain = KeychainStore()

    init() {
        if let data = UserDefaults.standard.data(forKey: Self.defaultsKey),
           let decoded = try? JSONDecoder().decode(PawvisSettings.self, from: data) {
            settings = decoded
        } else {
            settings = .default
        }
        // Deliberately NO keychain access here: launching the app must never
        // prompt. Status loads when the OpenAI dictation engine needs it.
        migrate()
    }

    /// One keychain read per launch, on demand.
    func ensureKeyStatusLoaded() {
        guard !keyStatusLoaded else { return }
        keyStatusLoaded = true
        let keychainKey = keychain.read()
        apiKeyInKeychain = keychainKey != nil
        apiKeyAvailable = keychainKey != nil || APIKeyResolver.resolveNonKeychain() != nil
    }

    /// One-time migrations for settings persisted by older builds.
    private func migrate() {
        let defaults = UserDefaults.standard
        // v2: the default pointer source changed pinchMidpoint → palmCenter
        // (palm holds still during pinches). Only remap users still on the old
        // default; a deliberate choice of another source is preserved.
        if !defaults.bool(forKey: "PawvisMigration.palmPointer") {
            if settings.gestures.pointerSource == .pinchMidpoint {
                settings.gestures.pointerSource = .palmCenter
            }
            defaults.set(true, forKey: "PawvisMigration.palmPointer")
        }
        // v3: OpenAI default model moved to gpt-4o-transcribe (server VAD
        // works; the old default rejected our session config outright).
        if !defaults.bool(forKey: "PawvisMigration.gpt4oTranscribe") {
            if settings.dictation.model == "gpt-live-transcribe" {
                settings.dictation.model = "gpt-4o-transcribe"
            }
            defaults.set(true, forKey: "PawvisMigration.gpt4oTranscribe")
        }
        // v4: palm tracking retired — the cursor follows the index fingertip,
        // with pre-click stabilization handling pinch jostle.
        if !defaults.bool(forKey: "PawvisMigration.indexPointer") {
            if settings.gestures.pointerSource == .palmCenter {
                settings.gestures.pointerSource = .indexTip
            }
            defaults.set(true, forKey: "PawvisMigration.indexPointer")
        }
    }

    private func persist() {
        if let data = try? JSONEncoder().encode(settings) {
            UserDefaults.standard.set(data, forKey: Self.defaultsKey)
        }
    }

    func saveAPIKey(_ key: String) {
        keychain.write(key)
        keyStatusLoaded = true
        apiKeyInKeychain = !key.trimmingCharacters(in: .whitespacesAndNewlines).isEmpty
        apiKeyAvailable = apiKeyInKeychain || APIKeyResolver.resolveNonKeychain() != nil
    }

    func clearAPIKey() {
        keychain.delete()
        keyStatusLoaded = true
        apiKeyInKeychain = false
        apiKeyAvailable = APIKeyResolver.resolveNonKeychain() != nil
    }
}
