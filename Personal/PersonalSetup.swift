// PERSONAL add-on: the owner's build talks to one fixed backend, so it skips
// the pairing screens. Not part of the production app.
#if PERSONAL
import Foundation

enum PersonalSetup {
    /// First launch: pair with the backend named in Config/Secrets.xcconfig
    /// (JOEBRO_DEFAULT_SERVER, JOEBRO_BACKEND_TOKEN), or carry over the address
    /// and Keychain token an earlier personal build saved.
    static func seedPairingIfNeeded() {
        guard ServerConfig.url == nil else { return }
        let legacy = UserDefaults.standard.string(forKey: "serverURL")
        let configured = buildSetting("JoeBroDefaultServer").map { $0.contains("://") ? $0 : "http://" + $0 }
        guard let address = [legacy, configured].compactMap({ $0 }).first(where: { URL(string: $0)?.host != nil })
        else { return }
        let token = CredentialStore.loadToken() ?? buildSetting("JoeBroBackendToken") ?? ""
        ServerConfig.save(url: address, token: token, name: "Personal backend",
                          features: ServerConfig.Features())
    }

    /// An Info.plist value fed by an xcconfig; nil when the setting was not supplied.
    private static func buildSetting(_ key: String) -> String? {
        guard let raw = Bundle.main.object(forInfoDictionaryKey: key) as? String else { return nil }
        let value = raw.trimmingCharacters(in: .whitespacesAndNewlines)
        return value.isEmpty || value.hasPrefix("$(") ? nil : value
    }
}
#endif
