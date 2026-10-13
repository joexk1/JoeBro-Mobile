import Foundation

// The agent registry covers research runs, chats doing direct work, and
// background tasks. The legacy briefing kind is decoded for filtering.
//
// NOTE: this mirrors the registry being added to the backend in parallel.
// Decoding is deliberately lenient — every field but `id` is optional — so a
// field named differently on the server degrades to a missing value instead of
// failing the whole list.

public enum JBAgentKind: String, Decodable, Sendable, CaseIterable {
    case research, chat, task, briefing, subagent, unknown

    public init(from decoder: Decoder) throws {
        let raw = (try? String(from: decoder))?.lowercased() ?? ""
        self = JBAgentKind(rawValue: raw) ?? .unknown
    }

    public var label: String {
        switch self {
        case .research: "Research"
        case .chat: "Chat"
        case .task: "Task"
        case .briefing: "Briefing"
        case .subagent: "Subagent"
        case .unknown: "Agent"
        }
    }

    public var symbol: String {
        switch self {
        case .research: "magnifyingglass"
        case .chat: "bubble.left.and.bubble.right"
        case .task: "clock.arrow.circlepath"
        case .briefing: "sun.max.fill"
        case .subagent: "arrow.triangle.branch"
        case .unknown: "sparkles"
        }
    }
}

public struct JBAgentRecord: Decodable, Identifiable, Sendable, Hashable {
    public let id: String
    public let kind: JBAgentKind?
    public let title: String?
    public let status: String?
    public let live: Bool?
    public let model: String?
    public let progress: String?
    public let result: String?
    public let error: String?
    public let sessionID: String?
    public let parentID: String?
    public let createdAt: String?
    public let startedAt: String?
    public let finishedAt: String?
    public let resultChars: Int?
    public let resultTruncated: Bool?
    public let sourceCount: Int?
    public let sources: [JBResearchSource]?
    public let cancelRequested: Bool?
    public let messages: [JBAgentMessage]?

    /// Agent-mode chats do not create a registry row unless they are a spawned
    /// background run. Surface those sessions in All without inventing a run.
    public init(agentModeSession session: JBSession, kind sessionKind: JBAgentKind = .chat) {
        id = "session:" + session.id
        kind = sessionKind
        title = session.name
        status = "idle"; live = nil
        model = session.model
        progress = nil
        result = nil
        error = nil
        sessionID = session.id
        parentID = nil
        createdAt = session.createdAt
        startedAt = nil
        finishedAt = nil
        resultChars = nil
        resultTruncated = nil
        sourceCount = nil
        sources = nil
        cancelRequested = nil
        messages = nil
    }

    /// Local chat streaming state can be newer than a completed registry row.
    public init(copying original: JBAgentRecord, localStatus: String) {
        id = original.id
        kind = original.kind
        title = original.title
        status = localStatus; live = nil
        model = original.model
        progress = localStatus == "running" ? "Working in Chats" : original.progress
        result = original.result
        error = original.error
        sessionID = original.sessionID
        parentID = original.parentID
        createdAt = original.createdAt
        startedAt = original.startedAt
        finishedAt = original.finishedAt
        resultChars = original.resultChars
        resultTruncated = original.resultTruncated
        sourceCount = original.sourceCount
        sources = original.sources
        cancelRequested = original.cancelRequested
        messages = original.messages
    }

    enum CodingKeys: String, CodingKey {
        case id, kind, title, status, live, model, progress, result, error, messages
        case parentID = "parent_id", sessionID = "session_id", createdAt = "created_at", startedAt = "started_at", finishedAt = "finished_at"
        case resultChars = "result_chars", resultTruncated = "result_truncated", cancelRequested = "cancel_requested"
        case sourceCount = "source_count", sources
    }

    public init(from decoder: Decoder) throws {
        let box = try decoder.container(keyedBy: CodingKeys.self)
        id = (try? box.decode(String.self, forKey: .id))
            ?? (try? box.decode(Int.self, forKey: .id)).map(String.init) ?? UUID().uuidString
        kind = try? box.decode(JBAgentKind.self, forKey: .kind)
        title = try? box.decode(String.self, forKey: .title)
        status = try? box.decode(String.self, forKey: .status)
        live = try? box.decode(Bool.self, forKey: .live)
        model = try? box.decode(String.self, forKey: .model)
        progress = try? box.decode(String.self, forKey: .progress)
        result = try? box.decode(String.self, forKey: .result)
        error = try? box.decode(String.self, forKey: .error)
        sessionID = try? box.decode(String.self, forKey: .sessionID)
        let parent = (try? box.decode(String.self, forKey: .parentID))
            ?? (try? box.decode(Int.self, forKey: .parentID)).map(String.init)
        parentID = parent?.isEmpty == false ? parent : nil
        createdAt = try? box.decode(String.self, forKey: .createdAt)
        startedAt = try? box.decode(String.self, forKey: .startedAt)
        finishedAt = try? box.decode(String.self, forKey: .finishedAt)
        resultChars = try? box.decode(Int.self, forKey: .resultChars)
        resultTruncated = try? box.decode(Bool.self, forKey: .resultTruncated)
        sourceCount = try? box.decode(Int.self, forKey: .sourceCount)
        sources = try? box.decode([JBResearchSource].self, forKey: .sources)
        cancelRequested = try? box.decode(Bool.self, forKey: .cancelRequested)
        messages = try? box.decode([JBAgentMessage].self, forKey: .messages)
    }

    public var displayTitle: String { (title?.isEmpty == false ? title : nil) ?? "Untitled agent" }
    public var isSessionOnly: Bool { id.hasPrefix("session:") }
    public var isLive: Bool { live == true || ["running", "queued", "working"].contains(status ?? "") }
    public var failed: Bool { ["error", "failed"].contains(status ?? "") }
}

public struct JBAgentMessage: Decodable, Sendable, Hashable {
    public let role: String
    public let content: String
    public let createdAt: String?

    public init(role: String, content: String, createdAt: String? = nil) {
        self.role = role
        self.content = content
        self.createdAt = createdAt
    }

    enum CodingKeys: String, CodingKey {
        case role, content
        case createdAt = "created_at"
    }
}

extension JoeBroAPI {
    // The backend wraps these in an envelope: {"ok", "agents"} or {"ok", "agent"}.
    private struct AgentsEnvelope: Decodable {
        let agents: [JBAgentRecord]?
        /// Also tolerates a bare array, which earlier builds returned.
        init(from decoder: Decoder) throws {
            if let list = try? [JBAgentRecord](from: decoder) { agents = list; return }
            let box = try decoder.container(keyedBy: CodingKeys.self)
            agents = try? box.decode([JBAgentRecord].self, forKey: .agents)
        }
        enum CodingKeys: String, CodingKey { case agents }
    }
    private struct AgentEnvelope: Decodable { let agent: JBAgentRecord }

    /// Every agent in the registry, newest first.
    public func agentRegistry() async throws -> [JBAgentRecord] {
        try await fetch(AgentsEnvelope.self, "api/agents").agents ?? []
    }

    /// One agent with its full result text, rather than the list's preview.
    public func agentDetail(id: String) async throws -> JBAgentRecord {
        try await fetch(AgentEnvelope.self, "api/agents/\(segment(id))").agent
    }

    public func cancelAgent(id: String) async throws {
        _ = try await send(OK.self, "api/agents/\(segment(id))/cancel")
    }

    /// Cancels an ordinary chat turn, which has no agent registry run ID.
    public func stopChatAgentSession(id: String) async throws {
        _ = try await send(OK.self, "api/chat/stop/\(segment(id))")
    }

}
