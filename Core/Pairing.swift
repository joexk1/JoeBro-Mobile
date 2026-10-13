import Foundation

/// A `joebro://pair?u=<url>&t=<token>&n=<name>` link. Long names `url`,
/// `token` and `name` are accepted as aliases.
struct PairingPayload: Equatable {
    var url: String
    var token: String
    var name: String

    static func parse(_ link: URL) -> PairingPayload? {
        guard link.scheme == "joebro", link.host == "pair",
              let items = URLComponents(url: link, resolvingAgainstBaseURL: false)?.queryItems else { return nil }
        func value(_ keys: String...) -> String {
            for k in keys { if let v = items.first(where: { $0.name == k })?.value, !v.isEmpty { return v } }
            return ""
        }
        let url = value("u", "url")
        guard !url.isEmpty else { return nil }
        return PairingPayload(url: url, token: value("t", "token"), name: value("n", "name"))
    }

    static func parse(text: String) -> PairingPayload? {
        URL(string: text.trimmingCharacters(in: .whitespacesAndNewlines)).flatMap(parse)
    }
}

enum PairingError: LocalizedError {
    case invalidURL, unauthorized, unreachable, tooOld

    var errorDescription: String? {
        switch self {
        case .invalidURL: return "That address is not valid. It should start with http:// or https://."
        case .unauthorized: return "Token not accepted. Scan the code again."
        case .unreachable: return "Can't reach your Mac. Same Wi-Fi? Is Tailscale on?"
        case .tooOld: return "That Mac is running an older JoeBro. Update JoeBro on your Mac to 1.3.0."
        }
    }
}

struct PairingResult {
    let url: String
    let token: String
    let name: String
    let features: ServerConfig.Features
}

enum Pairing {
    /// Proves the URL and token (`/api/ping`, then `/api/mobile/hello`) before anything is saved.
    static func verify(_ payload: PairingPayload) async throws -> PairingResult {
        var raw = payload.url.trimmingCharacters(in: .whitespacesAndNewlines)
        while raw.hasSuffix("/") { raw.removeLast() }
        guard let base = URL(string: raw), let scheme = base.scheme?.lowercased(),
              ["http", "https"].contains(scheme), let host = base.host, !host.isEmpty
        else { throw PairingError.invalidURL }
        let token = payload.token.trimmingCharacters(in: .whitespacesAndNewlines)

        _ = try await get(base, "api/ping", token: token)
        let (status, data) = try await get(base, "api/mobile/hello", token: token, allow404: true)
        guard status != 404 else { throw PairingError.tooOld }
        struct Hello: Decodable { let name: String?; let features: [String: Bool]? }
        let hello = try? JSONDecoder().decode(Hello.self, from: data)
        let name = payload.name.isEmpty ? (hello?.name ?? "") : payload.name
        return PairingResult(url: raw, token: token, name: name,
                             features: ServerConfig.Features(values: hello?.features ?? [:]))
    }

    private static func get(_ base: URL, _ path: String, token: String, allow404: Bool = false) async throws -> (Int, Data) {
        var req = URLRequest(url: base.appendingPathComponent(path))
        req.timeoutInterval = 8
        req.setValue(String(-TimeZone.current.secondsFromGMT() / 60), forHTTPHeaderField: "X-TZ-Offset")
        if !token.isEmpty { req.setValue("Bearer \(token)", forHTTPHeaderField: "Authorization") }
        let data: Data, response: URLResponse
        do { (data, response) = try await URLSession.shared.data(for: req) }
        catch { throw PairingError.unreachable }
        let status = (response as? HTTPURLResponse)?.statusCode ?? 0
        if status == 401 || status == 403 { throw PairingError.unauthorized }
        if status == 404 && allow404 { return (404, data) }
        guard (200..<300).contains(status) else { throw PairingError.unreachable }
        return (status, data)
    }
}
