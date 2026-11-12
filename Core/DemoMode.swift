import Foundation

/// App Review and curious visitors have no Mac to pair with, so "Try the demo"
/// points the normal API clients at a fake host. `DemoURLProtocol` answers those
/// requests from the bundled demo.json; nothing leaves the phone, and pairing
/// state (Keychain, saved URL) is never read or written while it is on.
enum DemoMode {
    /// In memory only: a relaunch always starts at pairing.
    #if DEBUG
    /// `-JoeBroDemo` boots straight into the demo (screenshots, self-check).
    nonisolated(unsafe) static var active = ProcessInfo.processInfo.arguments.contains("-JoeBroDemo")
    /// `-JoeBroArg value` reads a debug launch option.
    static func option(_ name: String) -> String? {
        let args = ProcessInfo.processInfo.arguments
        return args.firstIndex(of: name).flatMap { args.indices.contains($0 + 1) ? args[$0 + 1] : nil }
    }
    /// `-JoeBroNoBanner` hides the yellow demo strip (marketing screenshots).
    static var hidesBanner: Bool { ProcessInfo.processInfo.arguments.contains("-JoeBroNoBanner") }
    #else
    nonisolated(unsafe) static var active = false
    static let hidesBanner = false
    #endif
    static let host = "demo.joebro.invalid"
    static let url = URL(string: "https://\(host)")!

    static func install(_ config: URLSessionConfiguration) {
        config.protocolClasses = [DemoURLProtocol.self] + (config.protocolClasses ?? [])
    }
}

/// Serves `"METHOD /path"` entries of demo.json. A request with a query string
/// tries `"GET /path?query"` first. Unlisted writes succeed with `{"ok":true}`
/// and change nothing; unlisted reads are a 404.
final class DemoURLProtocol: URLProtocol {
    private static let table: [String: Any] = {
        guard let file = Bundle.main.url(forResource: "demo", withExtension: "json"),
              let data = try? Data(contentsOf: file),
              let object = try? JSONSerialization.jsonObject(with: data) as? [String: Any] else { return [:] }
        return object
    }()

    override class func canInit(with request: URLRequest) -> Bool { request.url?.host == DemoMode.host }
    override class func canonicalRequest(for request: URLRequest) -> URLRequest { request }
    override func stopLoading() {}

    /// `{{m-N}}` becomes "N minutes ago", so running agents look live whenever the demo starts.
    private static func resolveMinutes(_ text: String) -> String {
        guard let re = try? NSRegularExpression(pattern: #"\{\{m-(\d+)\}\}"#) else { return text }
        let fmt = DateFormatter()
        fmt.locale = Locale(identifier: "en_US_POSIX")
        fmt.dateFormat = "yyyy-MM-dd'T'HH:mm:ss"
        let ns = text as NSString
        var out = ""
        var last = 0
        for m in re.matches(in: text, range: NSRange(location: 0, length: ns.length)) {
            out += ns.substring(with: NSRange(location: last, length: m.range.location - last))
            let n = Double(ns.substring(with: m.range(at: 1))) ?? 0
            out += fmt.string(from: Date().addingTimeInterval(-n * 60))
            last = m.range.location + m.range.length
        }
        return out + ns.substring(from: last)
    }

    private static func resolveDates(_ text: String) -> String {
        guard let re = try? NSRegularExpression(pattern: #"\{\{d([+-]?\d+):(\d\d):(\d\d)\}\}"#) else { return text }
        let fmt = DateFormatter()
        fmt.locale = Locale(identifier: "en_US_POSIX")
        fmt.dateFormat = "yyyy-MM-dd'T'HH:mm:ss"
        let ns = text as NSString
        var out = ""
        var last = 0
        for m in re.matches(in: text, range: NSRange(location: 0, length: ns.length)) {
            out += ns.substring(with: NSRange(location: last, length: m.range.location - last))
            let day = Int(ns.substring(with: m.range(at: 1))) ?? 0
            let h = Int(ns.substring(with: m.range(at: 2))) ?? 0
            let mi = Int(ns.substring(with: m.range(at: 3))) ?? 0
            let cal = Calendar.current
            let base = cal.date(byAdding: .day, value: day, to: cal.startOfDay(for: Date())) ?? Date()
            out += fmt.string(from: cal.date(bySettingHour: h, minute: mi, second: 0, of: base) ?? base)
            last = m.range.location + m.range.length
        }
        return out + ns.substring(from: last)
    }

    override func startLoading() {
        guard let url = request.url else { return }
        let method = request.httpMethod ?? "GET"
        let path = url.path
        let keys = [url.query.map { "\(method) \(path)?\($0)" }, "\(method) \(path)"].compactMap { $0 }
        var status = 200
        var type = "application/json"
        var body = Data()
        if path == "/api/chat_stream" {
            type = "text/event-stream"
            let reply = (Self.table["chat_reply"] as? String) ?? "This is demo mode."
            let words = reply.split(separator: " ", omittingEmptySubsequences: false)
            for (i, word) in words.enumerated() {
                let piece = String(word) + (i < words.count - 1 ? " " : "")
                let json = (try? JSONSerialization.data(withJSONObject: ["delta": piece])) ?? Data()
                body.append(Data("data: ".utf8) + json + Data("\n\n".utf8))
            }
            body.append(Data("data: [DONE]\n\n".utf8))
        } else if let key = keys.first(where: { Self.table[$0] != nil }),
                  let data = try? JSONSerialization.data(withJSONObject: Self.table[key]!, options: [.fragmentsAllowed]) {
            body = Data(Self.resolveMinutes(Self.resolveDates(String(decoding: data, as: UTF8.self))).utf8)
        } else if method == "GET" {
            status = 404
            body = Data(#"{"detail":"Not part of the demo"}"#.utf8)
        } else {
            body = Data(#"{"ok":true}"#.utf8)
        }
        let response = HTTPURLResponse(url: url, statusCode: status, httpVersion: "HTTP/1.1",
                                       headerFields: ["Content-Type": type])!
        client?.urlProtocol(self, didReceive: response, cacheStoragePolicy: .notAllowed)
        client?.urlProtocol(self, didLoad: body)
        client?.urlProtocolDidFinishLoading(self)
    }
}
