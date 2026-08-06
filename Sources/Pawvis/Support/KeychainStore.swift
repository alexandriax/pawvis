import Foundation
import Security

/// Stores the OpenAI API key in the user's login keychain — never in
/// UserDefaults, never in the bundle, never in source control.
struct KeychainStore {
    var service = "com.pawvis.Pawvis"
    var account = "openai_api_key"

    func read() -> String? {
        let query: [String: Any] = [
            kSecClass as String: kSecClassGenericPassword,
            kSecAttrService as String: service,
            kSecAttrAccount as String: account,
            kSecReturnData as String: true,
            kSecMatchLimit as String: kSecMatchLimitOne,
        ]
        var item: CFTypeRef?
        guard SecItemCopyMatching(query as CFDictionary, &item) == errSecSuccess,
              let data = item as? Data,
              let key = String(data: data, encoding: .utf8), !key.isEmpty else {
            return nil
        }
        return key
    }

    @discardableResult
    func write(_ value: String) -> Bool {
        let trimmed = value.trimmingCharacters(in: .whitespacesAndNewlines)
        guard !trimmed.isEmpty else {
            delete()
            return true
        }
        let base: [String: Any] = [
            kSecClass as String: kSecClassGenericPassword,
            kSecAttrService as String: service,
            kSecAttrAccount as String: account,
        ]
        let data = Data(trimmed.utf8)
        let update: [String: Any] = [kSecValueData as String: data]

        let status = SecItemUpdate(base as CFDictionary, update as CFDictionary)
        if status == errSecItemNotFound {
            var add = base
            add[kSecValueData as String] = data
            return SecItemAdd(add as CFDictionary, nil) == errSecSuccess
        }
        return status == errSecSuccess
    }

    func delete() {
        let query: [String: Any] = [
            kSecClass as String: kSecClassGenericPassword,
            kSecAttrService as String: service,
            kSecAttrAccount as String: account,
        ]
        SecItemDelete(query as CFDictionary)
    }
}

/// Resolves the OpenAI API key for dictation, preferring the user-entered
/// keychain value. Development fallbacks: OPENAI_API_KEY in the environment,
/// then a `.env` file in the working directory or the repo the app was built
/// from. The key is never bundled with the app.
enum APIKeyResolver {
    static func resolve(keychain: KeychainStore = KeychainStore()) -> String? {
        if let key = keychain.read() { return key }

        if let env = ProcessInfo.processInfo.environment["OPENAI_API_KEY"],
           !env.isEmpty {
            return env
        }

        let candidates = [
            URL(fileURLWithPath: FileManager.default.currentDirectoryPath).appendingPathComponent(".env"),
            repoDotEnvURL(),
        ].compactMap { $0 }

        for url in candidates {
            if let key = parseDotEnv(at: url)?["OPENAI_API_KEY"], !key.isEmpty {
                Log.dictation.info("Using development API key from \(url.path, privacy: .public)")
                return key
            }
        }
        return nil
    }

    /// The repo root at compile time (dev builds only) — lets `make run`
    /// builds find .env no matter the launch cwd.
    private static func repoDotEnvURL() -> URL? {
        let sourceFile = URL(fileURLWithPath: #filePath)
        let repoRoot = sourceFile
            .deletingLastPathComponent() // Support
            .deletingLastPathComponent() // Pawvis
            .deletingLastPathComponent() // Sources
            .deletingLastPathComponent() // repo
        let url = repoRoot.appendingPathComponent(".env")
        return FileManager.default.fileExists(atPath: url.path) ? url : nil
    }

    static func parseDotEnv(at url: URL) -> [String: String]? {
        guard let content = try? String(contentsOf: url, encoding: .utf8) else { return nil }
        var result: [String: String] = [:]
        for line in content.split(separator: "\n") {
            let trimmed = line.trimmingCharacters(in: .whitespaces)
            guard !trimmed.isEmpty, !trimmed.hasPrefix("#"),
                  let eq = trimmed.firstIndex(of: "=") else { continue }
            let key = String(trimmed[..<eq]).trimmingCharacters(in: .whitespaces)
            var value = String(trimmed[trimmed.index(after: eq)...]).trimmingCharacters(in: .whitespaces)
            if value.hasPrefix("\""), value.hasSuffix("\""), value.count >= 2 {
                value = String(value.dropFirst().dropLast())
            }
            result[key] = value
        }
        return result
    }
}
