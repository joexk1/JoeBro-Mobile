import Foundation

/// The single source of truth for the paired backend. URL and token are kept
/// in the Keychain; the display name and feature flags in UserDefaults.
enum ServerConfig {
    struct Features: Codable, Equatable {
        var values: [String: Bool] = [:]
        /// Unknown features are shown; only an explicit `false` hides one.
        func has(_ key: String) -> Bool { values[key] ?? true }
    }

    static var urlString: String { CredentialStore.loadURL() ?? "" }
    static var url: URL? {
        let raw = urlString
        guard !raw.isEmpty else { return nil }
        return URL(string: raw)
    }
    static var token: String? { CredentialStore.loadToken() }
    static var name: String { UserDefaults.standard.string(forKey: "pairedServerName") ?? "" }
    static var isPaired: Bool {
        #if DEBUG
        if ProcessInfo.processInfo.arguments.contains("-JoeBroUITestPaired") { return true }
        #endif
        return url != nil
    }

    static var features: Features {
        get {
            guard let data = UserDefaults.standard.data(forKey: "pairedServerFeatures"),
                  let f = try? JSONDecoder().decode(Features.self, from: data) else { return Features() }
            return f
        }
        set { UserDefaults.standard.set(try? JSONEncoder().encode(newValue), forKey: "pairedServerFeatures") }
    }

    static func save(url: String, token: String, name: String, features: Features) {
        CredentialStore.saveURL(url)
        CredentialStore.saveToken(token)
        UserDefaults.standard.set(name, forKey: "pairedServerName")
        Self.features = features
    }

    static func forget() {
        CredentialStore.clear()
        UserDefaults.standard.removeObject(forKey: "pairedServerName")
        UserDefaults.standard.removeObject(forKey: "pairedServerFeatures")
    }

    static func api() -> JoeBroAPI? {
        guard let url else { return nil }
        return JoeBroAPI(baseURL: url, token: token)
    }
}
