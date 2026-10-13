import Foundation

public enum JoeBroAPIError: LocalizedError, Sendable {
    case invalidURL
    case invalidResponse
    case http(Int, String)
    case server(String)
    case streamInterrupted

    public var errorDescription: String? {
        switch self {
        case .invalidURL: "Invalid backend URL"
        case .invalidResponse: "Unexpected server response"
        case .http(let code, let detail): detail.isEmpty ? "HTTP \(code)" : detail
        case .server(let detail): detail
        case .streamInterrupted: "Connection dropped before JoeBro finished. Refresh the chat; do not resend automatically."
        }
    }
}

public final class JoeBroAPI: @unchecked Sendable {
    public let baseURL: URL
    private let token: String?
    private let session: URLSession
    private let streamSession: URLSession

    public init(baseURL: URL, token: String? = nil) {
        self.baseURL = baseURL
        self.token = token?.isEmpty == true ? nil : token
        let config = URLSessionConfiguration.default
        config.requestCachePolicy = .reloadIgnoringLocalCacheData
        config.urlCache = nil
        config.timeoutIntervalForRequest = 30
        config.timeoutIntervalForResource = 120
        config.httpMaximumConnectionsPerHost = 12
        self.session = URLSession(configuration: config)
        let streaming = URLSessionConfiguration.default
        streaming.requestCachePolicy = .reloadIgnoringLocalCacheData
        streaming.urlCache = nil
        streaming.timeoutIntervalForRequest = 120
        streaming.timeoutIntervalForResource = 3600
        streaming.httpMaximumConnectionsPerHost = 4
        self.streamSession = URLSession(configuration: streaming)
    }

    func request(_ path: String, method: String = "GET", query: [URLQueryItem] = []) throws -> URLRequest {
        guard var components = URLComponents(url: baseURL, resolvingAgainstBaseURL: false) else { throw JoeBroAPIError.invalidURL }
        let root = components.path.trimmingCharacters(in: CharacterSet(charactersIn: "/"))
        components.path = "/" + ([root, path.trimmingCharacters(in: CharacterSet(charactersIn: "/"))]
            .filter { !$0.isEmpty }.joined(separator: "/"))
        components.queryItems = query.isEmpty ? nil : query
        guard let url = components.url else { throw JoeBroAPIError.invalidURL }
        var result = URLRequest(url: url)
        result.httpMethod = method
        result.cachePolicy = .reloadIgnoringLocalCacheData
        result.setValue(String(-TimeZone.current.secondsFromGMT() / 60), forHTTPHeaderField: "X-TZ-Offset")
        if let token { result.setValue("Bearer \(token)", forHTTPHeaderField: "Authorization") }
        return result
    }

    func segment(_ value: String) -> String {
        value.addingPercentEncoding(withAllowedCharacters: .urlPathAllowed.subtracting(CharacterSet(charactersIn: "/?#%"))) ?? value
    }

    func checked(_ data: Data, _ response: URLResponse) throws -> Data {
        guard let http = response as? HTTPURLResponse else { throw JoeBroAPIError.invalidResponse }
        let obj = (try? JSONSerialization.jsonObject(with: data)) as? [String: Any]
        let detail = obj?["detail"] as? String ?? obj?["error"] as? String ?? ""
        guard (200..<300).contains(http.statusCode) else { throw JoeBroAPIError.http(http.statusCode, detail) }
        if obj?["ok"] as? Bool == false || obj?["success"] as? Bool == false {
            throw JoeBroAPIError.server(detail.isEmpty ? "The backend rejected the request" : detail)
        }
        return data
    }

    func fetch<T: Decodable>(_ type: T.Type, _ path: String, query: [URLQueryItem] = []) async throws -> T {
        let (data, response) = try await session.data(for: request(path, query: query))
        return try JSONDecoder().decode(T.self, from: checked(data, response))
    }

    func send<T: Decodable>(_ type: T.Type, _ path: String, method: String = "POST", json: [String: Any]? = nil, form: [String: String]? = nil) async throws -> T {
        var req = try request(path, method: method)
        if let json {
            req.setValue("application/json", forHTTPHeaderField: "Content-Type")
            req.httpBody = try JSONSerialization.data(withJSONObject: json)
        } else if let form {
            req.setValue("application/x-www-form-urlencoded; charset=utf-8", forHTTPHeaderField: "Content-Type")
            req.httpBody = Self.formData(form)
        }
        let (data, response) = try await session.data(for: req)
        return try JSONDecoder().decode(T.self, from: checked(data, response))
    }

    private static func formData(_ fields: [String: String]) -> Data {
        let allowed = CharacterSet(charactersIn: "ABCDEFGHIJKLMNOPQRSTUVWXYZabcdefghijklmnopqrstuvwxyz0123456789-._* ")
        let pairs = fields.sorted { $0.key < $1.key }.map { key, value in
            let k = key.addingPercentEncoding(withAllowedCharacters: allowed)!.replacingOccurrences(of: " ", with: "+")
            let v = value.addingPercentEncoding(withAllowedCharacters: allowed)!.replacingOccurrences(of: " ", with: "+")
            return "\(k)=\(v)"
        }
        return pairs.joined(separator: "&").data(using: .utf8)!
    }

    struct OK: Decodable { let ok: Bool }
    private struct ModelsEnvelope: Decodable {
        let items: [Item]
        struct Item: Decodable {
            let url: String
            let models: [String]
            let modelsDisplay: [String]?
            let modelsExtra: [String]?
            let modelsExtraDisplay: [String]?
            let endpointID: String?
            let endpointName: String?
            let category: String?
            let offline: Bool?
            enum CodingKeys: String, CodingKey {
                case url, models, category, offline
                case modelsDisplay = "models_display", modelsExtra = "models_extra"
                case modelsExtraDisplay = "models_extra_display", endpointID = "endpoint_id", endpointName = "endpoint_name"
            }
        }
    }
    private struct PulseEnvelope: Decodable { let pulse: JBPulse }
    private struct AgentsEnvelope: Decodable { let agents: [JBAgent] }
    private struct PlanEnvelope: Decodable { let steps: [JBPlanStep] }
    private struct MemoryEnvelope: Decodable { let memory: [JBMemory] }
    private struct SkillsEnvelope: Decodable { let skills: [JBSkill] }
    private struct MCPEnvelope: Decodable { let servers: [JBMCPServer] }
    private struct UploadEnvelope: Decodable { let files: [JBUploadedFile] }
    private struct CalendarEnvelope: Decodable { let events: [JBCalendarEvent] }
    private struct ResearchLibraryEnvelope: Decodable { let research: [JBResearchItem] }
    private struct ResearchActiveEnvelope: Decodable { let active: [JBResearchActive] }
    private struct EmailFoldersEnvelope: Decodable { let folders: [String]; let configured: Bool }
    private struct SpawnEnvelope: Decodable { let agents: [SpawnedAgent] }
    private struct SpawnedAgent: Decodable { let id: String; let title: String }

    public func ping() async throws -> Bool {
        try await fetch(OK.self, "api/ping").ok
    }

    public func models() async throws -> [JBModelChoice] {
        let result = try await fetch(ModelsEnvelope.self, "api/models")
        return result.items.flatMap { item in
            let ids = item.models + (item.modelsExtra ?? [])
            let labels = (item.modelsDisplay ?? item.models) + (item.modelsExtraDisplay ?? item.modelsExtra ?? [])
            return ids.enumerated().map { index, id in
                JBModelChoice(modelID: id, display: index < labels.count ? labels[index] : id,
                              endpointName: item.endpointName ?? "Endpoint", endpointURL: item.url,
                              endpointID: item.endpointID ?? item.url, category: item.category ?? "cloud",
                              offline: item.offline ?? false)
            }
        }
    }

    public func sessions() async throws -> [JBSession] { try await fetch([JBSession].self, "api/sessions") }

    public func createSession(name: String = "New Chat", model: String = "", endpointURL: String = "",
                              endpointID: String = "", mode: String = "chat") async throws -> JBSession {
        try await send(JBSession.self, "api/session", form: ["name": name, "model": model,
                    "endpoint_url": endpointURL, "endpoint_id": endpointID, "mode": mode])
    }

    public func history(_ id: String) async throws -> JBHistory {
        try await fetch(JBHistory.self, "api/history/\(segment(id))")
    }
    public func sessionTip(_ id: String) async throws -> JBSessionTip {
        try await fetch(JBSessionTip.self, "api/session/\(segment(id))/tip")
    }
    public func renameSession(_ id: String, name: String) async throws {
        _ = try await send(OK.self, "api/session/\(segment(id))", method: "PATCH", form: ["name": name])
    }
    public func setSessionMode(_ id: String, mode: String) async throws {
        _ = try await send(OK.self, "api/session/\(segment(id))", method: "PATCH", form: ["mode": mode])
    }
    public func updateSessionModel(_ id: String, model: String, endpointURL: String, endpointID: String) async throws {
        _ = try await send(OK.self, "api/session/\(segment(id))", method: "PATCH", form: [
            "model": model, "endpoint_url": endpointURL, "endpoint_id": endpointID
        ])
    }
    public func deleteSession(_ id: String) async throws {
        _ = try await send(OK.self, "api/session/\(segment(id))", method: "DELETE")
    }
    public struct CompactResult: Decodable { public let compacted: Bool; public let removed: Int? }
    public func compactSession(_ id: String) async throws -> CompactResult {
        try await send(CompactResult.self, "api/session/\(segment(id))/compact")
    }

    // MARK: - Folders
    //
    // There is no folder entity on the backend. A folder is just the `folder`
    // string on each session row, so "create" == set it on a chat, and a
    // folder ceases to exist when its last member is cleared.
    //
    // Always prefer /move over PATCH: it trims and stores NULL for empty,
    // whereas PATCH stores a literal "", and it can set position atomically.

    /// Moves a chat into `folder` (nil or "" to un-group) and optionally repositions it.
    public func moveSession(_ id: String, folder: String?, sortOrder: Double? = nil) async throws {
        var form = ["folder": folder ?? ""]
        if let sortOrder { form["sort_order"] = String(sortOrder) }
        _ = try await send(OK.self, "api/session/\(segment(id))/move", form: form)
    }

    /// Bulk-retags every chat carrying `old`. The backend replies ok even when nothing matched.
    public func renameFolder(old: String, new: String) async throws {
        _ = try await send(OK.self, "api/folder/rename", form: ["old": old, "new": new])
    }

    public func setSessionImportant(_ id: String, important: Bool) async throws {
        _ = try await send(OK.self, "api/session/\(segment(id))/important", form: ["important": important ? "true" : "false"])
    }

    public func archiveSession(_ id: String) async throws {
        _ = try await send(OK.self, "api/session/\(segment(id))/archive")
    }

    public func pulse() async throws -> JBPulse { try await fetch(PulseEnvelope.self, "api/pulse").pulse }
    public func updatePulse(_ update: JBPulseUpdate) async throws -> JBPulse {
        var body: [String: Any] = [:]
        if let value = update.enabled { body["enabled"] = value }
        if let value = update.intervalMinutes { body["interval_minutes"] = value }
        if let value = update.checklist { body["checklist"] = value }
        if let value = update.quietHours { body["quiet_hours"] = value }
        if let value = update.model { body["model"] = value }
        if let value = update.endpointID { body["endpoint_id"] = value }
        return try await send(PulseEnvelope.self, "api/pulse", json: body).pulse
    }
    public func runPulse() async throws -> JBPulseRunResult {
        try await send(JBPulseRunResult.self, "api/pulse", json: ["action": "run"])
    }
    public func agents() async throws -> [JBAgent] { try await fetch(AgentsEnvelope.self, "api/agents").agents }
    public func spawnAgent(prompt: String, title: String, permissionMode: String = "readonly") async throws -> JBAgent {
        let result = try await send(SpawnEnvelope.self, "api/agents", json: [
            "prompt": prompt, "title": title, "permission_mode": permissionMode, "notify": true
        ])
        guard let launched = result.agents.first else { throw JoeBroAPIError.invalidResponse }
        if let fresh = try? await agents().first(where: { $0.id == launched.id }) { return fresh }
        return JBAgent(id: launched.id, title: launched.title, status: "queued")
    }
    public func stopAgent(id: String) async throws {
        _ = try await send(OK.self, "api/agents/\(segment(id))", method: "DELETE")
    }
    public func calendarStatus() async throws -> JBCalendarStatus {
        try await fetch(JBCalendarStatus.self, "api/calendar/status")
    }
    public func calendarEvents(start: Date? = nil, end: Date? = nil) async throws -> [JBCalendarEvent] {
        let format = ISO8601DateFormatter()
        format.formatOptions = [.withInternetDateTime]
        var query: [URLQueryItem] = []
        if let start { query.append(URLQueryItem(name: "start", value: format.string(from: start))) }
        if let end { query.append(URLQueryItem(name: "end", value: format.string(from: end))) }
        return try await fetch(CalendarEnvelope.self, "api/calendar/events", query: query).events
    }
    public func plan(sessionID: String) async throws -> [JBPlanStep] {
        try await fetch(PlanEnvelope.self, "api/plan", query: [URLQueryItem(name: "session", value: sessionID)]).steps
    }
    public func memory() async throws -> [JBMemory] { try await fetch(MemoryEnvelope.self, "api/memory").memory }
    public func addMemory(text: String, category: String = "general") async throws -> JBJSON {
        try await send(JBJSON.self, "api/memory/add", json: ["text": text, "category": category, "source": "ios"])
    }
    public func skills() async throws -> [JBSkill] { try await fetch(SkillsEnvelope.self, "api/skills").skills }
    public func mcpServers() async throws -> [JBMCPServer] { try await fetch(MCPEnvelope.self, "api/mcp").servers }

    public func researchLibrary() async throws -> [JBResearchItem] {
        try await fetch(ResearchLibraryEnvelope.self, "api/research/library").research
    }
    public func researchActive() async throws -> [JBResearchActive] {
        try await fetch(ResearchActiveEnvelope.self, "api/research/active").active
    }
    public func researchStatus(id: String) async throws -> JBResearchStatus {
        try await fetch(JBResearchStatus.self, "api/research/status/\(segment(id))")
    }
    public func researchDetail(id: String) async throws -> JBResearchItem {
        try await fetch(JBResearchItem.self, "api/research/detail/\(segment(id))")
    }
    public func emailStatus() async throws -> JBEmailStatus {
        try await fetch(JBEmailStatus.self, "api/email/status")
    }
    public func emailFolders() async throws -> [String] {
        try await fetch(EmailFoldersEnvelope.self, "api/email/folders").folders
    }
    public func emailList(folder: String = "INBOX", unreadOnly: Bool = false,
                          refresh: Bool = false) async throws -> JBEmailList {
        // The backend applies the shared email_load_count preference.
        return try await fetch(JBEmailList.self, "api/email/list", query: [
            URLQueryItem(name: "folder", value: folder),
            URLQueryItem(name: "filter", value: unreadOnly ? "unread" : "all"),
            URLQueryItem(name: "refresh", value: refresh ? "1" : "0")
        ])
    }
    public struct EmailMessage: Sendable {
        public let detail: JBEmailDetail
        public let messageID: String?
        public let references: String?
    }

    /// Backend GET /api/email/read/{uid} also sets the IMAP Seen flag.
    public func emailMessage(uid: String, folder: String = "INBOX") async throws -> EmailMessage {
        let req = try request("api/email/read/\(segment(uid))", query: [URLQueryItem(name: "folder", value: folder)])
        let (data, response) = try await session.data(for: req)
        let valid = try checked(data, response)
        let detail = try JSONDecoder().decode(JBEmailDetail.self, from: valid)
        let raw = try JSONDecoder().decode(JBJSON.self, from: valid)
        return EmailMessage(detail: detail, messageID: raw["message_id"]?.stringValue,
                            references: raw["references"]?.stringValue)
    }
    public func emailDetail(uid: String, folder: String = "INBOX") async throws -> JBEmailDetail {
        try await emailMessage(uid: uid, folder: folder).detail
    }

    private struct EmailMutation: Decodable { let success: Bool }
    private func emailAction(_ action: String, uid: String, folder: String, method: String = "POST") async throws {
        let req = try request("api/email/\(action)/\(segment(uid))", method: method,
                              query: [URLQueryItem(name: "folder", value: folder)])
        let (data, response) = try await session.data(for: req)
        let result = try JSONDecoder().decode(EmailMutation.self, from: checked(data, response))
        if !result.success { throw JoeBroAPIError.server("Email action failed") }
    }
    public func markEmail(uid: String, folder: String = "INBOX", read: Bool) async throws {
        try await emailAction(read ? "mark-read" : "mark-unread", uid: uid, folder: folder)
    }
    public func archiveEmail(uid: String, folder: String = "INBOX") async throws {
        try await emailAction("archive", uid: uid, folder: folder)
    }
    public func deleteEmail(uid: String, folder: String = "INBOX") async throws {
        try await emailAction("delete", uid: uid, folder: folder, method: "DELETE")
    }
    public func sendEmail(to: String, cc: String = "", subject: String, body: String,
                          inReplyTo: String? = nil, references: String? = nil) async throws {
        var payload: [String: Any] = ["to": to, "subject": subject, "body": body]
        if !cc.isEmpty { payload["cc"] = cc }
        if let inReplyTo, !inReplyTo.isEmpty { payload["in_reply_to"] = inReplyTo }
        if let references, !references.isEmpty { payload["references"] = references }
        let result = try await send(EmailMutation.self, "api/email/send", json: payload)
        if !result.success { throw JoeBroAPIError.server("Email send failed") }
    }

    // MARK: - Documents
    //
    // The library is global and flat. Create/update take JSON; delete only
    // archives. There is no raw download for a library doc — only PDF export.

    private struct DocsLibraryEnvelope: Decodable { let documents: [JBDocSummary] }
    private struct WorkdirListEnvelope: Decodable { let entries: [JBWorkdirEntry]? }
    private struct WorkdirEnvelope: Decodable { let workdir: String? }

    public func documents(search: String = "", limit: Int = 100) async throws -> [JBDocSummary] {
        var query = [URLQueryItem(name: "limit", value: String(limit))]
        if !search.isEmpty { query.append(URLQueryItem(name: "search", value: search)) }
        return try await fetch(DocsLibraryEnvelope.self, "api/documents/library", query: query).documents
    }

    public func document(_ id: String) async throws -> JBDocDetail {
        try await fetch(JBDocDetail.self, "api/document/\(segment(id))")
    }

    public func createDocument(title: String, content: String, language: String = "markdown") async throws -> JBDocDetail {
        try await send(JBDocDetail.self, "api/document",
                       json: ["title": title, "content": content, "language": language])
    }

    public func updateDocument(_ id: String, content: String, title: String? = nil) async throws -> JBDocDetail {
        var body: [String: Any] = ["content": content]
        if let title { body["title"] = title }
        return try await send(JBDocDetail.self, "api/document/\(segment(id))", method: "PUT", json: body)
    }

    /// Archives the document; the row is kept.
    public func deleteDocument(_ id: String) async throws {
        _ = try await send(OK.self, "api/document/\(segment(id))", method: "DELETE")
    }

    public func documentPDFURL(_ id: String) -> URL? {
        URL(string: "api/document/\(segment(id))/export-pdf", relativeTo: baseURL)
    }

    // MARK: - Bound folder (workdir) files

    /// The folder this chat's file tools are bound to, if any.
    public func workdir(session: String) async throws -> String? {
        try await fetch(WorkdirEnvelope.self, "api/session/\(segment(session))/workdir").workdir
    }

    /// One level of the bound folder. `sub` is relative to the folder root.
    public func workdirList(session: String, sub: String = "") async throws -> [JBWorkdirEntry] {
        try await fetch(WorkdirListEnvelope.self, "api/session/\(segment(session))/workdir/list",
                        query: [URLQueryItem(name: "sub", value: sub)]).entries ?? []
    }

    /// Opens a workdir text file as a document. The returned id is synthetic
    /// ("file_<hex>") and has no library row, so saves must go back through
    /// saveWorkdirFile rather than PUT /api/document.
    public func openWorkdirFile(session: String, sub: String) async throws -> JBDocDetail {
        try await send(JBDocDetail.self, "api/session/\(segment(session))/workdir/open-file", json: ["sub": sub])
    }

    public func saveWorkdirFile(session: String, sub: String, content: String) async throws {
        _ = try await send(OK.self, "api/session/\(segment(session))/workdir/save-file",
                           json: ["sub": sub, "content": content])
    }

    public func renameWorkdirFile(session: String, sub: String, newName: String) async throws {
        _ = try await send(OK.self, "api/session/\(segment(session))/workdir/rename-file",
                           json: ["sub": sub, "new_name": newName])
    }

    public func deleteWorkdirFile(session: String, sub: String) async throws {
        _ = try await send(OK.self, "api/session/\(segment(session))/workdir/delete-file", json: ["sub": sub])
    }

    /// Raw bytes of a workdir file — the only way to get images and PDFs.
    public func workdirRaw(session: String, sub: String) async throws -> Data {
        let request = try request("api/session/\(segment(session))/workdir/raw",
                                  query: [URLQueryItem(name: "sub", value: sub)])
        let (data, response) = try await self.session.data(for: request)
        return try checked(data, response)
    }

    /// Binds this chat to a folder on the backend host. iOS has no local
    /// filesystem to offer, so the device branch the Mac has is not exposed.
    public func bindWorkdir(session sid: String, path: String) async throws {
        _ = try await send(OK.self, "api/session/\(segment(sid))/workdir", method: "PUT", json: ["workdir": path])
    }

    private struct BrowseEnvelope: Decodable { let path: String?; let entries: [JBWorkdirEntry]? }
    public func browse(path: String = "") async throws -> [JBWorkdirEntry] {
        try await fetch(BrowseEnvelope.self, "api/fs/browse",
                        query: [URLQueryItem(name: "path", value: path)]).entries ?? []
    }

    public func respondToPermission(id: String, decision: String) async throws {
        _ = try await send(OK.self, "api/permission/\(segment(id))", json: ["decision": decision])
    }

    public func upload(data: Data, filename: String, mimeType: String) async throws -> JBUploadedFile {
        var req = try request("api/upload", method: "POST")
        let boundary = "joebro-\(UUID().uuidString)"
        req.setValue("multipart/form-data; boundary=\(boundary)", forHTTPHeaderField: "Content-Type")
        let safeName = filename.replacingOccurrences(of: "\"", with: "_").replacingOccurrences(of: "\r", with: "_").replacingOccurrences(of: "\n", with: "_")
        var body = Data("--\(boundary)\r\nContent-Disposition: form-data; name=\"files\"; filename=\"\(safeName)\"\r\nContent-Type: \(mimeType)\r\n\r\n".utf8)
        body.append(data)
        body.append(Data("\r\n--\(boundary)--\r\n".utf8))
        req.httpBody = body
        let (responseData, response) = try await session.data(for: req)
        guard let file = try JSONDecoder().decode(UploadEnvelope.self, from: checked(responseData, response)).files.first else {
            throw JoeBroAPIError.invalidResponse
        }
        return file
    }

    public func chatStream(_ turn: JBChatTurn) -> AsyncThrowingStream<JBStreamEvent, Error> {
        AsyncThrowingStream { continuation in
            let task = Task {
                do {
                    var req = try request("api/chat_stream", method: "POST")
                    req.setValue("application/x-www-form-urlencoded; charset=utf-8", forHTTPHeaderField: "Content-Type")
                    var fields: [String: String] = ["message": turn.message, "session": turn.sessionID,
                                                    "mode": turn.mode, "permission_mode": turn.permissionMode,
                                                    "max_tokens": "8192"]
                    if turn.orchestrator { fields["orchestrator"] = "true" }
                    if turn.askPermission { fields["ask_permission"] = "true" }
                    if let value = turn.model { fields["model"] = value }
                    if let value = turn.endpointID { fields["endpoint_id"] = value }
                    if let value = turn.endpointURL { fields["endpoint_url"] = value }
                    if let value = turn.thinking { fields["thinking"] = value ? "true" : "false" }
                    if turn.useWeb { fields[turn.mode == "agent" ? "allow_web_search" : "use_web"] = "true" }
                    if turn.mode == "agent" && turn.allowBash { fields["allow_bash"] = "true" }
                    if !turn.attachmentIDs.isEmpty {
                        let encoded = try JSONSerialization.data(withJSONObject: turn.attachmentIDs)
                        fields["attachments"] = String(decoding: encoded, as: UTF8.self)
                    }
                    req.httpBody = Self.formData(fields)
                    let (bytes, response) = try await streamSession.bytes(for: req)
                    guard let http = response as? HTTPURLResponse else { throw JoeBroAPIError.invalidResponse }
                    guard (200..<300).contains(http.statusCode) else {
                        var text = ""
                        for try await line in bytes.lines.prefix(5) { text += line }
                        let data = Data(text.utf8)
                        let obj = (try? JSONSerialization.jsonObject(with: data)) as? [String: Any]
                        throw JoeBroAPIError.http(http.statusCode, obj?["detail"] as? String ?? text)
                    }
                    var eventName = ""
                    var dataLines: [String] = []
                    var done = false
                    func flush() throws {
                        defer { eventName = ""; dataLines.removeAll(keepingCapacity: true) }
                        guard !dataLines.isEmpty else { return }
                        let payload = dataLines.joined(separator: "\n")
                        if payload == "[DONE]" { done = true; continuation.yield(.done); return }
                        guard let json = try? JSONDecoder().decode(JBJSON.self, from: Data(payload.utf8)) else { return }
                        if eventName == "error" {
                            throw JoeBroAPIError.server(json["error"]?.stringValue ?? json["detail"]?.stringValue ?? payload)
                        }
                        if let delta = json["delta"]?.stringValue {
                            continuation.yield(json["thinking"]?.boolValue == true ? .thinking(delta) : .delta(delta))
                        } else if let type = json["type"]?.stringValue {
                            continuation.yield(.typed(type, json))
                        } else if let error = json["error"]?.stringValue {
                            throw JoeBroAPIError.server(error)
                        }
                    }
                    for try await line in bytes.lines {
                        try Task.checkCancellation()
                        if line.isEmpty { try flush(); if done { break }; continue }
                        if line.hasPrefix("event:") { eventName = String(line.dropFirst(6)).trimmingCharacters(in: .whitespaces); continue }
                        if line.hasPrefix("data:") {
                            var value = String(line.dropFirst(5))
                            if value.first == " " { value.removeFirst() }
                            dataLines.append(value)
                            // The current backend writes one data line per frame without blank separators.
                            // Decode complete JSON frames immediately while retaining standard SSE support.
                            if value == "[DONE]" || (dataLines.count == 1 && (try? JSONDecoder().decode(JBJSON.self, from: Data(value.utf8))) != nil) {
                                try flush(); if done { break }
                            }
                        }
                    }
                    if !done { throw JoeBroAPIError.streamInterrupted }
                    continuation.finish()
                } catch is CancellationError {
                    continuation.finish(throwing: CancellationError())
                } catch {
                    continuation.finish(throwing: error)
                }
            }
            continuation.onTermination = { _ in task.cancel() }
        }
    }
}
