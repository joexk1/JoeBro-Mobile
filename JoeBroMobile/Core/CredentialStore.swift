import Foundation
import Security

/// Keychain storage for the paired backend: its URL and bearer token live
/// together so a token is never sent to a stale host.
enum CredentialStore {
    private static var service: String { Bundle.main.bundleIdentifier ?? "joebro" }
    private static let tokenAccount = "backendBearerToken"
    private static let urlAccount = "backendURL"

    private static func load(_ account: String) -> String? {
        let query: [String: Any] = [
            kSecClass as String: kSecClassGenericPassword,
            kSecAttrService as String: service,
            kSecAttrAccount as String: account,
            kSecReturnData as String: true,
            kSecMatchLimit as String: kSecMatchLimitOne
        ]
        var item: CFTypeRef?
        guard SecItemCopyMatching(query as CFDictionary, &item) == errSecSuccess,
              let data = item as? Data else { return nil }
        return String(data: data, encoding: .utf8)
    }

    private static func save(_ value: String, account: String) {
        let query: [String: Any] = [
            kSecClass as String: kSecClassGenericPassword,
            kSecAttrService as String: service,
            kSecAttrAccount as String: account
        ]
        SecItemDelete(query as CFDictionary)
        guard !value.isEmpty else { return }
        var attrs = query
        attrs[kSecValueData as String] = Data(value.utf8)
        attrs[kSecAttrAccessible as String] = kSecAttrAccessibleAfterFirstUnlockThisDeviceOnly
        SecItemAdd(attrs as CFDictionary, nil)
    }

    static func loadToken() -> String? { load(tokenAccount) }
    static func saveToken(_ token: String) { save(token, account: tokenAccount) }
    static func loadURL() -> String? { load(urlAccount) }
    static func saveURL(_ url: String) { save(url, account: urlAccount) }
    static func clear() { saveToken(""); saveURL("") }
}
