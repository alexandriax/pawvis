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
    @Published private(set) var apiKeyAvailable: Bool
    /// Whether the key came from the keychain (i.e., user-entered in the UI).
    @Published private(set) var apiKeyInKeychain: Bool

    private let keychain = KeychainStore()

    init() {
        if let data = UserDefaults.standard.data(forKey: Self.defaultsKey),
           let decoded = try? JSONDecoder().decode(PawvisSettings.self, from: data) {
            settings = decoded
        } else {
            settings = .default
        }
        apiKeyInKeychain = keychain.read() != nil
        apiKeyAvailable = APIKeyResolver.resolve() != nil
    }

    private func persist() {
        if let data = try? JSONEncoder().encode(settings) {
            UserDefaults.standard.set(data, forKey: Self.defaultsKey)
        }
    }

    func saveAPIKey(_ key: String) {
        keychain.write(key)
        refreshKeyStatus()
    }

    func clearAPIKey() {
        keychain.delete()
        refreshKeyStatus()
    }

    private func refreshKeyStatus() {
        apiKeyInKeychain = keychain.read() != nil
        apiKeyAvailable = APIKeyResolver.resolve() != nil
    }
}
