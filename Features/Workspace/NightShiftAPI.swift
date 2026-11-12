import Foundation

// Night Shift (task queue + morning review) and Shared Memory (project facts every
// coding agent reads and writes). Shapes follow reports/feature-api.md. Everything is
// optional or defaulted so a backend that adds a field never breaks the screen.

struct NSDiffFile: Decodable, Hashable { let path: String; let added: Int?; let removed: Int? }
struct NSDiff: Decodable, Hashable {
    let files: Int?, insertions: Int?, deletions: Int?
    let fileList: [NSDiffFile]?
    enum CodingKeys: String, CodingKey { case files, insertions, deletions, fileList = "file_list" }
}
struct NSTests: Decodable, Hashable {
    let command: String?, passed: Bool?, durationS: Double?, outputTail: String?
    enum CodingKeys: String, CodingKey { case command, passed, durationS = "duration_s", outputTail = "output_tail" }
}
struct NSResult: Decodable, Hashable {
    let summary: String?, learned: [String]?, commits: Int?, durationS: Double?, costUSD: Double?
    let screenshot: Bool?, diff: NSDiff?, tests: NSTests?
    enum CodingKeys: String, CodingKey {
        case summary, learned, commits, screenshot, diff, tests
        case durationS = "duration_s", costUSD = "cost_usd"
    }
}
struct NSFollowup: Decodable, Hashable { let text: String? }

struct NSTask: Decodable, Identifiable, Hashable {
    let id: String
    let title: String?, repoName: String?, repo: String?, prompt: String?
    let agent: String?, model: String?, host: String?
    let status: String?, branch: String?, error: String?
    let windowStart: String?, windowEnd: String?, testCommand: String?, onApprove: String?
    let maxMinutes: Int?, position: Int?
    let followups: [NSFollowup]?
    let result: NSResult?
    enum CodingKeys: String, CodingKey {
        case id, title, repo, prompt, agent, model, host, status, branch, error, position, followups, result
        case repoName = "repo_name", windowStart = "window_start", windowEnd = "window_end"
        case testCommand = "test_command", onApprove = "on_approve", maxMinutes = "max_minutes"
    }
    var name: String { (title?.isEmpty == false ? title : nil) ?? String((prompt ?? "Task").prefix(48)) }
    var state: String { status ?? "queued" }
    var needsReview: Bool { state == "review" || (state == "failed" && result != nil) }
    var isOpen: Bool { state == "queued" || state == "running" }
    var agentLabel: String {
        switch agent ?? "any" { case "claude": "Claude Code"; case "codex": "Codex"; case "opencode": "OpenCode"; default: "Any agent" }
    }
}

struct NSConfig: Decodable, Hashable {
    var enabled: Bool?, windowStart: String?, windowEnd: String?, defaultAgent: String?
    enum CodingKeys: String, CodingKey { case enabled, windowStart = "window_start", windowEnd = "window_end", defaultAgent = "default_agent" }
}

struct SMProvenance: Decodable, Hashable { let agent: String?, model: String?, host: String?, source: String? }
struct SMFact: Decodable, Identifiable, Hashable {
    let id: String
    let project: String?, projectName: String?, scope: String?, topic: String?, kind: String?
    let text: String, status: String?
    let pinned: Bool?, strength: Double?, recalls: Int?
    let updatedAt: String?, createdAt: String?
    let provenance: SMProvenance?
    enum CodingKeys: String, CodingKey {
        case id, project, scope, topic, kind, text, status, pinned, strength, recalls, provenance
        case projectName = "project_name", updatedAt = "updated_at", createdAt = "created_at"
    }
    var isArchived: Bool { status == "archived" }
    var isPinned: Bool { pinned == true }
    var strengthValue: Double { min(max(strength ?? 0.5, 0), 1) }
    var kindLabel: String { (kind ?? "fact").capitalized }
    var kindSymbol: String {
        switch kind ?? "fact" {
        case "decision": "checkmark.seal"
        case "gotcha": "exclamationmark.triangle"
        case "preference": "heart"
        case "handoff": "arrow.right.circle"
        case "learned": "lightbulb"
        default: "text.quote"
        }
    }
    /// "Claude Code · opus · mac · MCP"
    var provenanceLine: String {
        guard let p = provenance else { return "" }
        let agent: String? = switch p.agent ?? "" {
        case "claude": "Claude Code"; case "codex": "Codex"; case "opencode": "OpenCode"
        case "app": "JoeBro app"; case "joebro": "JoeBro"; case "": nil; default: p.agent
        }
        let source: String? = switch p.source ?? "" {
        case "mcp": "MCP"; case "night_shift": "Night Shift"; case "consolidation": "consolidated"; case "app": nil; case "": nil; default: p.source
        }
        return [agent, p.model, p.host, source].compactMap { $0 }.filter { !$0.isEmpty }.joined(separator: " · ")
    }
}
struct SMProject: Decodable, Identifiable, Hashable {
    let key: String, name: String?
    let active: Int?, archived: Int?
    var id: String { key }
    var label: String { key == "global" ? "All projects (global)" : (name ?? key) }
}

/// "3d ago" from an ISO timestamp; empty when it does not parse.
func nsRelative(_ iso: String?) -> String {
    guard let iso, !iso.isEmpty else { return "" }
    let f = ISO8601DateFormatter()
    f.formatOptions = [.withInternetDateTime, .withFractionalSeconds]
    let g = ISO8601DateFormatter()
    let plain = DateFormatter(); plain.locale = Locale(identifier: "en_US_POSIX"); plain.dateFormat = "yyyy-MM-dd'T'HH:mm:ss"
    guard let d = f.date(from: iso) ?? g.date(from: iso) ?? plain.date(from: String(iso.prefix(19))) else { return "" }
    let out = RelativeDateTimeFormatter(); out.unitsStyle = .short
    return out.localizedString(for: d, relativeTo: .now)
}

extension WorkspaceAPI {
    private struct Plain: Decodable { let ok: Bool? }
    private struct TasksEnv: Decodable { let tasks: [NSTask]; let config: NSConfig? }
    private struct DiffEnv: Decodable { let diff: String?; let truncated: Bool? }
    private struct FactsEnv: Decodable { let facts: [SMFact] }
    private struct ProjectsEnv: Decodable { let projects: [SMProject] }
    private struct HistoryEnv: Decodable { let fact: SMFact; let history: [SMFact]? }

    // MARK: Night Shift
    func nightShift() async throws -> (tasks: [NSTask], config: NSConfig?) {
        let r = try await call(TasksEnv.self, "api/night-shift")
        return (r.tasks, r.config)
    }
    func nightAdd(_ body: [String: Any]) async throws { _ = try await call(Plain.self, "api/night-shift", method: "POST", json: body) }
    func nightReorder(_ ids: [String]) async throws { _ = try await call(Plain.self, "api/night-shift/reorder", method: "POST", json: ["ids": ids]) }
    func nightCancel(_ id: String) async throws { _ = try await call(Plain.self, "api/night-shift/\(idPath(id))/cancel", method: "POST", json: [:]) }
    func nightRun(_ id: String) async throws { _ = try await call(Plain.self, "api/night-shift/\(idPath(id))/run", method: "POST", json: [:]) }
    func nightDecide(_ id: String, decision: String, text: String? = nil) async throws {
        var body: [String: Any] = ["decision": decision]
        if let text { body["text"] = text }
        _ = try await call(Plain.self, "api/night-shift/\(idPath(id))/decide", method: "POST", json: body)
    }
    func nightConfig(enabled: Bool) async throws { _ = try await call(Plain.self, "api/night-shift/config", method: "PUT", json: ["enabled": enabled]) }
    func nightDiff(_ id: String) async throws -> String {
        try await call(DiffEnv.self, "api/night-shift/\(idPath(id))/diff").diff ?? ""
    }

    // MARK: Shared memory
    func memoryProjects() async throws -> [SMProject] { try await call(ProjectsEnv.self, "api/shared-memory/projects").projects }
    func memoryFacts(project: String?, status: String, query: String) async throws -> [SMFact] {
        var q = ["status=\(status)", "limit=200"]
        if let project, project != "global" || true, !project.isEmpty, project != "__all" { q.append("project=" + (project.addingPercentEncoding(withAllowedCharacters: .alphanumerics) ?? project)) }
        if !query.isEmpty { q.append("q=" + (query.addingPercentEncoding(withAllowedCharacters: .alphanumerics) ?? query)) }
        return try await call(FactsEnv.self, "api/shared-memory?" + q.joined(separator: "&")).facts
    }
    func memoryHistory(_ id: String) async throws -> [SMFact] { try await call(HistoryEnv.self, "api/shared-memory/\(idPath(id))").history ?? [] }
    func memoryEdit(_ id: String, text: String, topic: String, kind: String) async throws {
        _ = try await call(Plain.self, "api/shared-memory/\(idPath(id))", method: "PUT", json: ["text": text, "topic": topic, "kind": kind])
    }
    func memoryPin(_ id: String, pinned: Bool) async throws {
        _ = try await call(Plain.self, "api/shared-memory/\(idPath(id))/pin", method: "POST", json: ["pinned": pinned])
    }
    func memoryArchive(_ id: String) async throws { _ = try await call(Plain.self, "api/shared-memory/\(idPath(id))/archive", method: "POST", json: [:]) }
    func memoryRestore(_ id: String) async throws { _ = try await call(Plain.self, "api/shared-memory/\(idPath(id))/restore", method: "POST", json: [:]) }
    func memoryAdd(project: String, text: String, kind: String) async throws {
        var body: [String: Any] = ["text": text, "kind": kind, "source": "app", "agent": "app"]
        if project != "__all" { body["project"] = project }
        _ = try await call(Plain.self, "api/shared-memory", method: "POST", json: body)
    }
}

extension WorkspaceAPI {
    /// Route that resumes a coding session on a linked machine (start_coding_session).
    /// Not in reports/feature-api.md yet: change this one constant when the backend names it.

    private struct AgentsEnv: Decodable { let agents: [JBAgentRecord] }
    /// Raw bytes of an authenticated GET (review screenshots).
    func nightScreenshot(_ id: String) async throws -> Data {
        struct Wrap: Decodable { }
        return try await rawGET("api/night-shift/\(idPath(id))/screenshot")
    }
}
