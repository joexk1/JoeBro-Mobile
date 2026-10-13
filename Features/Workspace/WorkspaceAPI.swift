import Foundation

// MARK: - Models

struct WSTask: Decodable, Identifiable, Hashable {
    let id: String
    let name: String
    let prompt: String
    let schedule: String
    let scheduledTime: String
    let status: String
    let permissionMode: String
    let repeatDay: Int
    let scope: String?
    enum CodingKeys: String, CodingKey {
        case id, name, prompt, schedule, status, scope
        case scheduledTime = "scheduled_time", permissionMode = "permission_mode", repeatDay = "repeat_day"
    }
    var isPaused: Bool { status == "paused" }
    var isPersonal: Bool { scope == "personal" }
}

struct WSSkill: Decodable, Identifiable, Hashable {
    let id: String
    let name: String
    let description: String
    let content: String
    let whenToUse: String
    let status: String
    let confidence: Int?
    enum CodingKeys: String, CodingKey {
        case id, name, description, content, status, confidence
        case whenToUse = "when_to_use"
    }
    var isActive: Bool { status != "disabled" && status != "archived" }
}

struct WSTool: Decodable, Identifiable, Hashable {
    let id: String
    let name: String
    let baseURL: String
    let method: String
    let description: String
    let isEnabled: Bool
    let hasKey: Bool
    enum CodingKeys: String, CodingKey {
        case id, name, method, description
        case baseURL = "base_url", isEnabled = "is_enabled", hasKey = "has_key"
    }
    init(from decoder: Decoder) throws {
        let box = try decoder.container(keyedBy: CodingKeys.self)
        id = try box.decode(String.self, forKey: .id)
        name = (try? box.decode(String.self, forKey: .name)) ?? "Untitled tool"
        baseURL = (try? box.decode(String.self, forKey: .baseURL)) ?? ""
        method = (try? box.decode(String.self, forKey: .method)) ?? "GET"
        description = (try? box.decode(String.self, forKey: .description)) ?? ""
        isEnabled = (try? box.decode(Bool.self, forKey: .isEnabled)) ?? true
        hasKey = (try? box.decode(Bool.self, forKey: .hasKey)) ?? false
    }
}

struct WSPlugin: Decodable, Identifiable, Hashable {
    let id: String
    let name: String
    let description: String
    let kind: String
    let isEnabled: Bool
    let source: String
    let repoPath: String
    let permissionMode: String
    enum CodingKeys: String, CodingKey {
        case id, name, description, kind, source
        case isEnabled = "is_enabled", repoPath = "repo_path", permissionMode = "permission_mode"
    }
    init(from decoder: Decoder) throws {
        let box = try decoder.container(keyedBy: CodingKeys.self)
        id = try box.decode(String.self, forKey: .id)
        name = (try? box.decode(String.self, forKey: .name)) ?? "Untitled plugin"
        description = (try? box.decode(String.self, forKey: .description)) ?? ""
        kind = (try? box.decode(String.self, forKey: .kind)) ?? "foreground"
        isEnabled = (try? box.decode(Bool.self, forKey: .isEnabled)) ?? true
        source = (try? box.decode(String.self, forKey: .source)) ?? "user"
        repoPath = (try? box.decode(String.self, forKey: .repoPath)) ?? ""
        permissionMode = (try? box.decode(String.self, forKey: .permissionMode)) ?? "sandbox"
    }
    /// Bundled plugins ship with JoeBro; the backend keeps them, so hide delete.
    var isBundled: Bool { source == "bundled" }
}

/// The full MCP row. `Core`'s `JBMCPServer` omits command/args/permission mode,
/// which the editor needs, so the Workspace reads its own shape.
struct WSMCPServer: Decodable, Identifiable, Hashable {
    let id: String
    let name: String
    let command: String
    let args: String
    let enabled: Bool
    let permissionMode: String
    let tools: [String]
    let error: String
    enum CodingKeys: String, CodingKey {
        case id, name, command, args, enabled, tools, error
        case permissionMode = "permission_mode"
    }
    init(from decoder: Decoder) throws {
        let box = try decoder.container(keyedBy: CodingKeys.self)
        id = try box.decode(String.self, forKey: .id)
        name = (try? box.decode(String.self, forKey: .name)) ?? "MCP Server"
        command = (try? box.decode(String.self, forKey: .command)) ?? ""
        args = (try? box.decode(String.self, forKey: .args)) ?? ""
        enabled = (try? box.decode(Bool.self, forKey: .enabled)) ?? false
        permissionMode = (try? box.decode(String.self, forKey: .permissionMode)) ?? "sandbox"
        tools = (try? box.decode([String].self, forKey: .tools)) ?? []
        error = (try? box.decode(String.self, forKey: .error)) ?? ""
    }
}

struct WSAICheck: Decodable {
    let aiPercent: Double
    let humanPercent: Double
    let aiWords: Int
    let totalWords: Int
    let flaggedSentences: [String]
    let provider: String?
    enum CodingKeys: String, CodingKey {
        case provider
        case aiPercent = "ai_percent", humanPercent = "human_percent"
        case aiWords = "ai_words", totalWords = "total_words", flaggedSentences = "flagged_sentences"
    }
    init(from decoder: Decoder) throws {
        let box = try decoder.container(keyedBy: CodingKeys.self)
        aiPercent = (try? box.decode(Double.self, forKey: .aiPercent)) ?? 0
        humanPercent = (try? box.decode(Double.self, forKey: .humanPercent)) ?? 0
        aiWords = (try? box.decode(Int.self, forKey: .aiWords)) ?? 0
        totalWords = (try? box.decode(Int.self, forKey: .totalWords)) ?? 0
        flaggedSentences = (try? box.decode([String].self, forKey: .flaggedSentences)) ?? []
        provider = try? box.decode(String.self, forKey: .provider)
    }
}

/// Agent access levels, shared by tasks, MCP servers and plugins.
enum WSPermissionMode: String, CaseIterable, Identifiable {
    case sandbox, readonly, full
    var id: String { rawValue }
    var label: String {
        switch self {
        case .sandbox: "Bound folder"
        case .readonly: "Read-only"
        case .full: "Full access"
        }
    }
    var symbol: String {
        switch self {
        case .sandbox: "folder"
        case .readonly: "eye"
        case .full: "lock.open"
        }
    }
    static func named(_ raw: String) -> WSPermissionMode { WSPermissionMode(rawValue: raw) ?? .sandbox }
}

// MARK: - Client

final class WorkspaceAPI: @unchecked Sendable {
    let baseURL: URL
    private let token: String?
    private let session: URLSession

    init(baseURL: URL, token: String?) {
        self.baseURL = baseURL
        self.token = token?.isEmpty == true ? nil : token
        let config = URLSessionConfiguration.default
        config.timeoutIntervalForRequest = 60
        config.timeoutIntervalForResource = 180
        config.requestCachePolicy = .reloadIgnoringLocalCacheData
        config.urlCache = nil
        session = URLSession(configuration: config)
    }

    private func request(_ path: String, method: String = "GET",
                         json: [String: Any]? = nil, form: [String: String]? = nil) throws -> URLRequest {
        guard var url = URLComponents(url: baseURL, resolvingAgainstBaseURL: false) else { throw JoeBroAPIError.invalidURL }
        let pathParts = path.split(separator: "?", maxSplits: 1, omittingEmptySubsequences: false)
        url.path = "/" + [url.path.trimmingCharacters(in: CharacterSet(charactersIn: "/")), String(pathParts[0])]
            .filter { !$0.isEmpty }.joined(separator: "/")
        if pathParts.count > 1 { url.percentEncodedQuery = String(pathParts[1]) }
        guard let endpoint = url.url else { throw JoeBroAPIError.invalidURL }
        var request = URLRequest(url: endpoint)
        request.httpMethod = method
        request.cachePolicy = .reloadIgnoringLocalCacheData
        request.setValue(String(-TimeZone.current.secondsFromGMT() / 60), forHTTPHeaderField: "X-TZ-Offset")
        if let token { request.setValue("Bearer \(token)", forHTTPHeaderField: "Authorization") }
        if let json {
            request.setValue("application/json", forHTTPHeaderField: "Content-Type")
            request.httpBody = try JSONSerialization.data(withJSONObject: json)
        } else if let form {
            request.setValue("application/x-www-form-urlencoded; charset=utf-8", forHTTPHeaderField: "Content-Type")
            request.httpBody = Self.formData(form)
        }
        return request
    }

    /// The backend's tools / MCP / plugin writes read `_form_body()`, so those
    /// bodies must be form-encoded — JSON silently arrives as an empty dict.
    private static func formData(_ fields: [String: String]) -> Data {
        let allowed = CharacterSet(charactersIn: "ABCDEFGHIJKLMNOPQRSTUVWXYZabcdefghijklmnopqrstuvwxyz0123456789-._* ")
        let pairs = fields.sorted { $0.key < $1.key }.map { key, value -> String in
            let k = key.addingPercentEncoding(withAllowedCharacters: allowed)?.replacingOccurrences(of: " ", with: "+") ?? key
            let v = value.addingPercentEncoding(withAllowedCharacters: allowed)?.replacingOccurrences(of: " ", with: "+") ?? value
            return "\(k)=\(v)"
        }
        return Data(pairs.joined(separator: "&").utf8)
    }

    private func call<T: Decodable>(_ type: T.Type, _ path: String, method: String = "GET",
                                    json: [String: Any]? = nil, form: [String: String]? = nil) async throws -> T {
        let (data, response) = try await session.data(for: request(path, method: method, json: json, form: form))
        guard let http = response as? HTTPURLResponse else { throw JoeBroAPIError.invalidResponse }
        let object = (try? JSONSerialization.jsonObject(with: data)) as? [String: Any]
        let detail = object?["detail"] as? String ?? object?["error"] as? String ?? ""
        guard (200..<300).contains(http.statusCode) else { throw JoeBroAPIError.http(http.statusCode, detail) }
        if object?["ok"] as? Bool == false { throw JoeBroAPIError.server(detail.isEmpty ? "Request rejected" : detail) }
        do { return try JSONDecoder().decode(T.self, from: data) }
        catch { throw JoeBroAPIError.server("Unexpected reply from \(path): \(error.localizedDescription)") }
    }

    private func idPath(_ id: String) -> String {
        id.addingPercentEncoding(withAllowedCharacters: .urlPathAllowed.subtracting(CharacterSet(charactersIn: "/?#%"))) ?? id
    }

    private struct OK: Decodable { let ok: Bool? }
    private struct TasksEnvelope: Decodable { let tasks: [WSTask] }
    private struct SkillsEnvelope: Decodable { let skills: [WSSkill] }
    private struct ToolsEnvelope: Decodable { let tools: [WSTool] }
    private struct PluginsEnvelope: Decodable { let plugins: [WSPlugin] }
    private struct MCPEnvelope: Decodable { let servers: [WSMCPServer] }
    private struct TaskRun: Decodable { let result: String? }
    private struct ResearchStart: Decodable { let id: String?; let sessionID: String?
        enum CodingKeys: String, CodingKey { case id; case sessionID = "session_id" } }

    // MARK: Tasks

    /// `scope`: "general" (default) or "personal" (the phone agent's own tasks).
    func tasks(scope: String = "general") async throws -> [WSTask] {
        try await call(TasksEnvelope.self, scope == "personal" ? "api/tasks?scope=personal" : "api/tasks").tasks
    }

    func saveTask(id: String?, name: String, prompt: String, schedule: String, time: String,
                  repeatDay: Int, permissionMode: String, scope: String = "general") async throws {
        var body: [String: Any] = ["name": name, "prompt": prompt, "schedule": schedule,
                                   "scheduled_time": time, "repeat_day": repeatDay, "permission_mode": permissionMode]
        if id == nil && scope == "personal" { body["scope"] = "personal" }
        let path = id.map { "api/tasks/\(idPath($0))" } ?? "api/tasks"
        _ = try await call(OK.self, path, method: id == nil ? "POST" : "PUT", json: body)
    }
    func setTaskPermission(id: String, mode: String) async throws {
        _ = try await call(OK.self, "api/tasks/\(idPath(id))", method: "PUT", json: ["permission_mode": mode])
    }
    func taskAction(id: String, action: String) async throws {
        _ = try await call(OK.self, "api/tasks/\(idPath(id))/\(action)", method: "POST")
    }
    func runTask(id: String) async throws -> String {
        try await call(TaskRun.self, "api/tasks/\(idPath(id))/run", method: "POST").result ?? "Task finished with no output."
    }
    func deleteTask(id: String) async throws {
        _ = try await call(OK.self, "api/tasks/\(idPath(id))", method: "DELETE")
    }

    // MARK: Brain

    func addMemory(text: String, category: String) async throws {
        _ = try await call(OK.self, "api/memory/add", method: "POST",
                           json: ["text": text, "category": category, "source": "ios"])
    }
    func updateMemory(id: String, text: String, category: String) async throws {
        _ = try await call(OK.self, "api/memory/\(idPath(id))", method: "PUT", json: ["text": text, "category": category])
    }
    func pinMemory(id: String) async throws {
        _ = try await call(OK.self, "api/memory/\(idPath(id))/pin", method: "POST")
    }
    func deleteMemory(id: String) async throws {
        _ = try await call(OK.self, "api/memory/\(idPath(id))", method: "DELETE")
    }

    // MARK: Muse memory (personal agent's markdown files)

    struct MuseFile: Decodable, Identifiable, Hashable {
        let name: String
        let lines: Int
        let always: Bool
        var id: String { name }
    }
    private struct MuseList: Decodable { let files: [MuseFile] }
    private struct MuseDoc: Decodable { let content: String }

    func museFiles() async throws -> [MuseFile] { try await call(MuseList.self, "api/muse").files }
    func museRead(_ name: String) async throws -> String {
        try await call(MuseDoc.self, "api/muse/\(idPath(name))").content
    }
    func museWrite(_ name: String, content: String) async throws {
        _ = try await call(OK.self, "api/muse/\(idPath(name))", method: "PUT", json: ["content": content])
    }
    func museCreate(_ name: String) async throws {
        _ = try await call(OK.self, "api/muse", method: "POST", json: ["name": name])
    }
    func museDelete(_ name: String) async throws {
        _ = try await call(OK.self, "api/muse/\(idPath(name))", method: "DELETE")
    }

    // MARK: Skills

    func skills() async throws -> [WSSkill] { try await call(SkillsEnvelope.self, "api/skills").skills }
    func setSkillActive(id: String, active: Bool) async throws {
        _ = try await call(OK.self, "api/skills/\(idPath(id))", method: "PUT", json: ["status": active ? "active" : "disabled"])
    }
    func saveSkill(id: String?, name: String, description: String, whenToUse: String, content: String) async throws {
        let body = ["name": name, "description": description, "when_to_use": whenToUse, "content": content]
        let path = id.map { "api/skills/\(idPath($0))" } ?? "api/skills"
        _ = try await call(OK.self, path, method: id == nil ? "POST" : "PUT", json: body)
    }
    func deleteSkill(id: String) async throws {
        _ = try await call(OK.self, "api/skills/\(idPath(id))", method: "DELETE")
    }

    // MARK: API tools (form-encoded)

    func tools() async throws -> [WSTool] { try await call(ToolsEnvelope.self, "api/tools").tools }
    func saveTool(id: String?, name: String, baseURL: String, method: String,
                  description: String, apiKey: String?) async throws {
        var form = ["name": name, "base_url": baseURL, "method": method, "description": description]
        if let apiKey { form["api_key"] = apiKey }
        let path = id.map { "api/tools/\(idPath($0))" } ?? "api/tools"
        _ = try await call(OK.self, path, method: id == nil ? "POST" : "PUT", form: form)
    }
    func setToolEnabled(id: String, on: Bool) async throws {
        _ = try await call(OK.self, "api/tools/\(idPath(id))", method: "PUT", form: ["is_enabled": on ? "true" : "false"])
    }
    func deleteTool(id: String) async throws {
        _ = try await call(OK.self, "api/tools/\(idPath(id))", method: "DELETE")
    }

    // MARK: MCP servers (form-encoded)

    func mcpServers() async throws -> [WSMCPServer] { try await call(MCPEnvelope.self, "api/mcp").servers }
    func saveMCPServer(id: String?, name: String, command: String, args: String, permissionMode: String) async throws {
        let form = ["name": name, "command": command, "args": args, "permission_mode": permissionMode]
        let path = id.map { "api/mcp/\(idPath($0))" } ?? "api/mcp"
        _ = try await call(OK.self, path, method: id == nil ? "POST" : "PUT", form: form)
    }
    func setMCPEnabled(id: String, on: Bool) async throws {
        _ = try await call(OK.self, "api/mcp/\(idPath(id))", method: "PUT", form: ["enabled": on ? "true" : "false"])
    }
    func deleteMCPServer(id: String) async throws {
        _ = try await call(OK.self, "api/mcp/\(idPath(id))", method: "DELETE")
    }

    // MARK: Plugins (form-encoded)

    func plugins() async throws -> [WSPlugin] { try await call(PluginsEnvelope.self, "api/plugins").plugins }
    func savePlugin(id: String?, name: String, kind: String, repoPath: String,
                    description: String, permissionMode: String) async throws {
        let form = ["name": name, "kind": kind, "repo_path": repoPath,
                    "description": description, "permission_mode": permissionMode]
        let path = id.map { "api/plugins/\(idPath($0))" } ?? "api/plugins"
        _ = try await call(OK.self, path, method: id == nil ? "POST" : "PUT", form: form)
    }
    func setPluginEnabled(id: String, on: Bool) async throws {
        _ = try await call(OK.self, "api/plugins/\(idPath(id))", method: "PUT", form: ["is_enabled": on ? "true" : "false"])
    }
    func setPluginPermission(id: String, mode: String) async throws {
        _ = try await call(OK.self, "api/plugins/\(idPath(id))", method: "PUT", form: ["permission_mode": mode])
    }
    func deletePlugin(id: String) async throws {
        _ = try await call(OK.self, "api/plugins/\(idPath(id))", method: "DELETE")
    }

    // MARK: Research

    @discardableResult
    func startResearch(query: String, model: String?, endpointID: String?) async throws -> String {
        var body: [String: Any] = ["query": query]
        if let model, !model.isEmpty { body["model"] = model }
        if let endpointID, !endpointID.isEmpty { body["endpoint_id"] = endpointID }
        let started = try await call(ResearchStart.self, "api/research/start", method: "POST", json: body)
        return started.id ?? started.sessionID ?? ""
    }
    func cancelResearch(id: String) async throws {
        _ = try await call(OK.self, "api/research/cancel/\(idPath(id))", method: "POST")
    }
    func deleteResearch(id: String) async throws {
        _ = try await call(OK.self, "api/research/\(idPath(id))", method: "DELETE")
    }

    // MARK: AI check

    func aiCheck(text: String) async throws -> WSAICheck {
        try await call(WSAICheck.self, "api/ai-check", method: "POST", json: ["text": text])
    }
}
