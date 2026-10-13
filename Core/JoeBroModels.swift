import Foundation

public enum JBJSON: Decodable, Sendable {
    case object([String: JBJSON]), array([JBJSON]), string(String), number(Double), bool(Bool), null

    public init(from decoder: Decoder) throws {
        let box = try decoder.singleValueContainer()
        if box.decodeNil() { self = .null }
        else if let value = try? box.decode(Bool.self) { self = .bool(value) }
        else if let value = try? box.decode(Double.self) { self = .number(value) }
        else if let value = try? box.decode(String.self) { self = .string(value) }
        else if let value = try? box.decode([JBJSON].self) { self = .array(value) }
        else { self = .object(try box.decode([String: JBJSON].self)) }
    }

    public subscript(_ key: String) -> JBJSON? {
        if case .object(let value) = self { return value[key] }
        return nil
    }
    public var stringValue: String? {
        if case .string(let value) = self { return value }
        return nil
    }
    public var intValue: Int? {
        if case .number(let value) = self { return Int(value) }
        return nil
    }
    public var boolValue: Bool? {
        if case .bool(let value) = self { return value }
        if case .number(let value) = self { return value != 0 }
        return nil
    }
    public var arrayValue: [JBJSON]? {
        if case .array(let value) = self { return value }
        return nil
    }
}

public struct JBSession: Codable, Identifiable, Sendable, Hashable {
    public let id: String
    public var name: String
    public let model: String?
    public let mode: String?
    public let archived: Bool?
    /// The sidebar grouping label. nil/empty means ungrouped. Not a real
    /// entity on the backend — folders are derived by grouping on this string.
    public var folder: String?
    public var isImportant: Bool?
    public var sortOrder: Double?
    public let workdir: String?
    public let hostID: String?
    public let createdAt: String?
    public let endpointID: String?
    enum CodingKeys: String, CodingKey {
        case id, name, model, mode, archived, folder, workdir
        case isImportant = "is_important", sortOrder = "sort_order"
        case hostID = "host_id", createdAt = "created_at", endpointID = "endpoint_id"
    }

    /// Trimmed grouping key; "" for ungrouped.
    public var folderKey: String { (folder ?? "").trimmingCharacters(in: .whitespacesAndNewlines) }
}

public struct JBModelChoice: Identifiable, Sendable, Hashable {
    public let modelID: String
    public let display: String
    public let endpointName: String
    public let endpointURL: String
    public let endpointID: String
    public let category: String
    public let offline: Bool
    public var id: String { modelID + "@" + endpointID }
}

public struct JBHistory: Decodable, Sendable {
    public let history: [JBMessage]
    public let model: String?
    public let name: String?
}

public struct JBMessage: Decodable, Sendable {
    public let role: String
    public let content: String
    public let metadata: JBJSON?
    enum CodingKeys: String, CodingKey { case role, content, metadata }
    public init(from decoder: Decoder) throws {
        let box = try decoder.container(keyedBy: CodingKeys.self)
        role = (try? box.decode(String.self, forKey: .role)) ?? "assistant"
        metadata = try? box.decode(JBJSON.self, forKey: .metadata)
        if let text = try? box.decode(String.self, forKey: .content) {
            content = text
        } else if let value = try? box.decode(JBJSON.self, forKey: .content) {
            content = value.arrayValue?.compactMap { $0["text"]?.stringValue ?? $0.stringValue }.joined(separator: "\n") ?? ""
        } else { content = "" }
    }
    public var databaseID: Int? { metadata?["_db_id"]?.intValue }
}

public struct JBSessionTip: Decodable, Sendable {
    public let lastID: Int
    public let mode: String
    public let model: String
    enum CodingKeys: String, CodingKey { case lastID = "last_id", mode, model }
}

public struct JBPulse: Codable, Sendable {
    public let enabled: Bool
    public let intervalMinutes: Int
    public let checklist: String
    public let quietHours: String
    public let model: String
    public let endpointID: String
    public let lastRun: String
    public let lastSpoke: String
    enum CodingKeys: String, CodingKey {
        case enabled, checklist, model
        case intervalMinutes = "interval_minutes", quietHours = "quiet_hours"
        case endpointID = "endpoint_id", lastRun = "last_run", lastSpoke = "last_spoke"
    }
}

public struct JBPulseUpdate: Sendable {
    public var enabled: Bool?
    public var intervalMinutes: Int?
    public var checklist: String?
    public var quietHours: String?
    public var model: String?
    public var endpointID: String?
    public init(enabled: Bool? = nil, intervalMinutes: Int? = nil, checklist: String? = nil,
                quietHours: String? = nil, model: String? = nil, endpointID: String? = nil) {
        self.enabled = enabled; self.intervalMinutes = intervalMinutes; self.checklist = checklist
        self.quietHours = quietHours; self.model = model; self.endpointID = endpointID
    }
}

public struct JBPulseRunResult: Decodable, Sendable {
    public let ok: Bool
    public let ran: Bool?
    public let spoke: Bool?
    public let message: String?
    public let reason: String?
}

public struct JBAgent: Codable, Identifiable, Sendable {
    public let id: String
    public let title: String?
    public let status: String
    public let result: String?
    public let error: String?
    public let createdAt: String?
    public let finishedAt: String?
    enum CodingKeys: String, CodingKey {
        case id, title, status, result, error
        case createdAt = "created_at", finishedAt = "finished_at"
    }
    public init(id: String, title: String?, status: String, result: String? = nil, error: String? = nil,
                createdAt: String? = nil, finishedAt: String? = nil) {
        self.id = id; self.title = title; self.status = status; self.result = result
        self.error = error; self.createdAt = createdAt; self.finishedAt = finishedAt
    }
}

public struct JBPlanStep: Codable, Sendable {
    public let text: String
    public let status: String
}

public struct JBMemory: Decodable, Identifiable, Sendable {
    public let id: String
    public let text: String?
    public let content: String?
    public let category: String?
    public let pinned: Bool?
    enum CodingKeys: String, CodingKey { case id, text, content, category, pinned }
    public init(from decoder: Decoder) throws {
        let box = try decoder.container(keyedBy: CodingKeys.self)
        id = (try? box.decode(String.self, forKey: .id)) ??
             (try? box.decode(Int.self, forKey: .id)).map(String.init) ?? ""
        text = try? box.decode(String.self, forKey: .text)
        content = try? box.decode(String.self, forKey: .content)
        category = try? box.decode(String.self, forKey: .category)
        pinned = try? box.decode(Bool.self, forKey: .pinned)
    }
    public var displayText: String { text ?? content ?? "" }
    public var stringID: String { id }
}

public struct JBSkill: Decodable, Identifiable, Sendable {
    public let id: String
    public let name: String?
    public let description: String?
    public let enabled: Bool?
    public let status: String?
}

public struct JBMCPServer: Decodable, Identifiable, Sendable {
    public let id: String
    public let name: String
    public let enabled: Bool?
    public let tools: [String]?
    public let error: String?
}

public struct JBUploadedFile: Decodable, Identifiable, Sendable {
    public let id: String
    public let name: String
    public let mime: String
    public let size: Int?
}

public struct JBChatTurn: Sendable {
    public var message: String
    public var sessionID: String
    public var mode: String
    public var model: String?
    public var endpointID: String?
    public var endpointURL: String?
    public var attachmentIDs: [String]
    public var useWeb: Bool
    public var allowBash: Bool
    public var thinking: Bool?
    public var permissionMode: String
    public var orchestrator: Bool
    public var askPermission: Bool
    public init(message: String, sessionID: String, mode: String = "chat", model: String? = nil,
                endpointID: String? = nil, endpointURL: String? = nil, attachmentIDs: [String] = [],
                useWeb: Bool = false, allowBash: Bool = false, thinking: Bool? = nil, permissionMode: String = "sandbox",
                orchestrator: Bool = false, askPermission: Bool = false) {
        self.message = message; self.sessionID = sessionID; self.mode = mode
        self.model = model; self.endpointID = endpointID; self.endpointURL = endpointURL
        self.attachmentIDs = attachmentIDs; self.useWeb = useWeb; self.allowBash = allowBash; self.thinking = thinking
        self.permissionMode = permissionMode
        self.orchestrator = orchestrator; self.askPermission = askPermission
    }
}

public enum JBStreamEvent: Sendable {
    case delta(String), thinking(String), typed(String, JBJSON), done
}

public struct JBCalendarStatus: Decodable, Sendable {
    public let configured: Bool
    public let type: String
    public let display: String
    public let macosAuthorized: Bool
    enum CodingKeys: String, CodingKey {
        case configured, type, display
        case macosAuthorized = "macos_authorized"
    }
}

public struct JBCalendarEvent: Decodable, Identifiable, Sendable {
    public let id: String
    public let uid: String
    public let summary: String
    public let dtstart: String
    public let dtend: String
    public let allDay: Bool
    public let location: String?
    public let description: String?
    enum CodingKeys: String, CodingKey {
        case id, uid, summary, dtstart, dtend, location, description
        case allDay = "all_day"
    }
}

public struct JBResearchItem: Decodable, Identifiable, Sendable {
    public let id: String
    public let query: String
    public let status: String
    public let content: String?
    public let progress: JBJSON?
    public let createdAt: String?
    public let updatedAt: String?
    public let report: String?
    public let sources: [JBResearchSource]?
    public let sourceCount: Int?
    enum CodingKeys: String, CodingKey {
        case id, query, status, content, progress, report, sources
        case sourceCount = "source_count"
        case createdAt = "created_at", updatedAt = "updated_at"
    }
}

public struct JBResearchSource: Decodable, Sendable, Hashable {
    public let title: String
    public let url: String
    public let snippet: String?
}

public struct JBResearchActive: Decodable, Identifiable, Sendable {
    public let id: String
    public let query: String
}

public struct JBResearchStatus: Decodable, Sendable {
    public let status: String
    public let progress: JBJSON
}

public struct JBEmailSource: Decodable, Identifiable, Sendable {
    public let id: String
    public let type: String?
    public let display: String?
}

public struct JBEmailStatus: Decodable, Sendable {
    public let configured: Bool
    public let type: String
    public let display: String
    public let sources: [JBEmailSource]
}

public struct JBEmailList: Decodable, Sendable {
    public let emails: [JBEmailSummary]
    public let total: Int
    public let configured: Bool
    public let error: String?
}

public struct JBEmailSummary: Decodable, Identifiable, Sendable {
    public let uid: String
    public let subject: String
    public let fromName: String?
    public let fromAddress: String?
    public let date: String?
    public let isRead: Bool
    public let isFlagged: Bool
    public let size: Int?
    public var id: String { uid }
    enum CodingKeys: String, CodingKey {
        case uid, subject, date, size
        case fromName = "from_name", fromAddress = "from_address"
        case isRead = "is_read", isFlagged = "is_flagged"
    }
}

public struct JBEmailDetail: Decodable, Identifiable, Sendable {
    public let uid: String
    public let subject: String
    public let fromName: String?
    public let fromAddress: String?
    public let to: String?
    public let cc: String?
    public let date: String?
    public let body: String?
    public let bodyHTML: String?
    public let attachments: [JBEmailAttachment]
    public var id: String { uid }
    enum CodingKeys: String, CodingKey {
        case uid, subject, to, cc, date, body, attachments
        case fromName = "from_name", fromAddress = "from_address", bodyHTML = "body_html"
    }
}

public struct JBEmailAttachment: Decodable, Identifiable, Sendable {
    public let filename: String?
    public let size: Int?
    public let index: Int
    public let contentType: String?
    public var id: Int { index }
    enum CodingKeys: String, CodingKey {
        case filename, size, index
        case contentType = "content_type"
    }
}

// MARK: - Documents
//
// Two different things are called a document. A library document is a row in
// the backend `documents` table — global and flat, with no session or folder.
// A workdir file is a real file under the chat's bound folder, with no row at
// all; it is addressed by its path relative to that folder ("sub").

public struct JBDocSummary: Decodable, Identifiable, Sendable, Hashable {
    public let id: String
    public let title: String?
    public let language: String?
    public let updatedAt: String?
    public let versionCount: Int?
    public let archived: Bool?
    enum CodingKeys: String, CodingKey {
        case id, title, language, archived
        case updatedAt = "updated_at", versionCount = "version_count"
    }
    public var displayTitle: String { (title?.isEmpty == false ? title : nil) ?? "Untitled" }
}

public struct JBDocDetail: Decodable, Identifiable, Sendable {
    public let id: String
    public let title: String?
    public let language: String?
    public let currentContent: String?
    public let versionCount: Int?
    enum CodingKeys: String, CodingKey {
        case id, title, language
        case currentContent = "current_content", versionCount = "version_count"
    }
    public var text: String { currentContent ?? "" }
}

public struct JBWorkdirEntry: Decodable, Identifiable, Sendable, Hashable {
    public let name: String
    public let isDir: Bool
    enum CodingKeys: String, CodingKey { case name, isDir = "is_dir" }
    public var id: String { name }
}

/// How the app should present a workdir file, decided by extension exactly as
/// the Mac app does in AppStore.openWorkdirFile.
public enum JBFileKind: Sendable {
    case text(language: String)
    case image
    case pdf
    case spreadsheet
    case flashcards
    case unsupported

    public static func of(_ name: String) -> JBFileKind {
        let ext = (name as NSString).pathExtension.lowercased()
        switch ext {
        case "png", "jpg", "jpeg", "gif", "heic", "webp", "bmp", "tiff": return .image
        case "pdf": return .pdf
        case "csv", "xlsx": return .spreadsheet
        case "apkg": return .flashcards
        case "mp4", "mov", "zip", "pptx", "key", "numbers", "pages", "doc", "docx": return .unsupported
        default: return .text(language: language(ext))
        }
    }

    private static func language(_ ext: String) -> String {
        switch ext {
        case "swift": "swift"
        case "py": "python"
        case "js", "mjs": "javascript"
        case "ts", "tsx": "typescript"
        case "json": "json"
        case "html": "html"
        case "css": "css"
        case "sh", "zsh", "bash": "bash"
        case "yml", "yaml": "yaml"
        case "sql": "sql"
        case "rs": "rust"
        case "go": "go"
        case "c", "h": "c"
        case "md", "markdown", "": "markdown"
        default: "text"
        }
    }

    public var isMonospaced: Bool {
        if case .text(let language) = self { return !["markdown", "md", "text", ""].contains(language) }
        return false
    }
}
