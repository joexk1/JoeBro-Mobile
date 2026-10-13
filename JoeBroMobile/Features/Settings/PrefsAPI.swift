import Foundation

/// Backend preferences. The Mac stores the default model as two keys,
/// `default_model` and `default_endpoint_id`, so a choice is only complete
/// when both are written.
extension JoeBroAPI {
    private struct PrefsEnvelope: Decodable {
        let prefs: [String: String]
        init(from decoder: Decoder) throws {
            let box = try decoder.container(keyedBy: Key.self)
            var found: [String: String] = [:]
            // Values arrive loosely typed; only the strings matter here.
            if let nested = try? box.decode([String: AnyPref].self, forKey: .prefs) {
                for (key, value) in nested { if let text = value.text { found[key] = text } }
            } else {
                let flat = try [String: AnyPref](from: decoder)
                for (key, value) in flat { if let text = value.text { found[key] = text } }
            }
            prefs = found
        }
        enum Key: String, CodingKey { case prefs }
    }

    private struct AnyPref: Decodable {
        let text: String?
        init(from decoder: Decoder) throws {
            let single = try decoder.singleValueContainer()
            if let value = try? single.decode(String.self) { text = value }
            else if let value = try? single.decode(Int.self) { text = String(value) }
            else if let value = try? single.decode(Bool.self) { text = String(value) }
            else { text = nil }
        }
    }

    public func preferences() async throws -> [String: String] {
        try await fetch(PrefsEnvelope.self, "api/prefs").prefs
    }

    public func setPreference(_ key: String, value: String?) async throws {
        _ = try await send(OK.self, "api/prefs/\(segment(key))",
                           method: "PUT",
                           json: ["value": value ?? NSNull()])
    }
}
