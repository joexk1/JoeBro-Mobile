import SwiftUI
import PhotosUI
import UniformTypeIdentifiers

struct ChatToolCall: Identifiable, Codable {
    let id: UUID
    var name: String
    var command: String
    var output: String
    var exitCode: Int?
    var finished: Bool

    init(name: String, command: String = "", output: String = "", exitCode: Int? = nil, finished: Bool = false) {
        id = UUID()
        self.name = name
        self.command = command
        self.output = output
        self.exitCode = exitCode
        self.finished = finished
    }
}

struct ChatDocumentRef: Identifiable, Codable, Hashable {
    let id: String
    let title: String
    let language: String
}

struct ChatLine: Identifiable, Codable {
    let id: UUID
    var serverID: Int?
    var role: String
    var text: String
    var thinking: String = ""
    var tools: [String] = [] // Legacy cached snapshots.
    var toolCalls: [ChatToolCall] = []
    var documents: [ChatDocumentRef] = []
    var attachments: [String] = []
    var streaming = false
    init(role: String, text: String, id: UUID = UUID()) { self.role = role; self.text = text; self.id = id }
    enum CodingKeys: String, CodingKey { case id, serverID, role, text, thinking, tools, toolCalls, documents, attachments, streaming }
    init(from decoder: Decoder) throws {
        let box = try decoder.container(keyedBy: CodingKeys.self)
        id = try box.decode(UUID.self, forKey: .id)
        serverID = try box.decodeIfPresent(Int.self, forKey: .serverID)
        role = try box.decode(String.self, forKey: .role)
        text = try box.decode(String.self, forKey: .text)
        thinking = try box.decodeIfPresent(String.self, forKey: .thinking) ?? ""
        tools = try box.decodeIfPresent([String].self, forKey: .tools) ?? []
        toolCalls = try box.decodeIfPresent([ChatToolCall].self, forKey: .toolCalls) ?? []
        documents = try box.decodeIfPresent([ChatDocumentRef].self, forKey: .documents) ?? []
        attachments = try box.decodeIfPresent([String].self, forKey: .attachments) ?? []
        streaming = try box.decodeIfPresent(Bool.self, forKey: .streaming) ?? false
    }
}

@MainActor
@Observable final class ChatStore {
    let api: JoeBroAPI
    let isMainJoeBro: Bool
    var sessions: [JBSession] = []
    var models: [JBModelChoice] = []
    var selectedSessionID: String?
    var lines: [ChatLine] = []
    var selectedModelID: String?
    private var serverDefaultModelID: String?
    var agentMode = false
    var thinkingOn = UserDefaults.standard.object(forKey: "thinkingOn") as? Bool ?? true
    var useWeb = false
    var allowBash = false
    var permissionMode = UserDefaults.standard.string(forKey: "chatPermissionMode") ?? "sandbox"
    var workingSessions: Set<String> = []
    var busy: Bool { selectedSessionID.map { workingSessions.contains($0) } ?? false }
    var stoppingSessions: Set<String> = []
    var stopRequestedSessions: Set<String> = []
    var stopping: Bool { selectedSessionID.map { stoppingSessions.contains($0) } ?? false }
    var stopRequested: Bool { selectedSessionID.map { stopRequestedSessions.contains($0) } ?? false }
    var uploadingAttachment = false
    var error: String?
    var mainConnectionIssue: String?
    var permission: (id: String, tool: String, command: String)?
    var pendingAttachments: [JBUploadedFile] = []
    var pendingAttachment: JBUploadedFile? {
        get { pendingAttachments.first }
        set { pendingAttachments = newValue.map { [$0] } ?? [] }
    }
    var draft = ""
    private var documentsBySession: [String: [ChatDocumentRef]] = [:]
    private var liveAssistants: [String: ChatLine] = [:]
    private var pendingUsers: [String: ChatLine] = [:]
    private var turnBaselines: [String: Int] = [:]
    private var creatingSession = false

    init(api: JoeBroAPI, isMainJoeBro: Bool = false) {
        self.api = api
        self.isMainJoeBro = isMainJoeBro
        selectedModelID = isMainJoeBro ? nil : UserDefaults.standard.string(forKey: "selectedModelID")
        if let data = try? Data(contentsOf: isMainJoeBro ? Self.mainCacheURL : Self.cacheURL),
           let snapshot = try? JSONDecoder().decode(ChatSnapshot.self, from: data) {
            sessions = snapshot.sessions
            selectedSessionID = snapshot.selectedID
            lines = snapshot.lines
            documentsBySession = snapshot.documentsBySession ?? [:]
            if let id = selectedSessionID,
               let assistant = lines.last, assistant.role == "assistant", assistant.serverID == nil,
               let user = lines.dropLast().last, user.role == "user" {
                liveAssistants[id] = assistant
                if user.serverID == nil { pendingUsers[id] = user }
                turnBaselines[id] = lines.compactMap(\.serverID).max() ?? 0
            }
        }
    }

    private struct ChatSnapshot: Codable {
        let sessions: [JBSession]
        let selectedID: String?
        let lines: [ChatLine]
        let documentsBySession: [String: [ChatDocumentRef]]?
        let savedAt: Date
    }
    private static var cacheURL: URL {
        FileManager.default.urls(for: .applicationSupportDirectory, in: .userDomainMask)[0]
            .appendingPathComponent("JoeBro/chats.json")
    }
    private static var mainCacheURL: URL {
        FileManager.default.urls(for: .applicationSupportDirectory, in: .userDomainMask)[0]
            .appendingPathComponent("JoeBro/main-agent.json")
    }
    private func saveSnapshot() {
        let snapshot = ChatSnapshot(sessions: sessions, selectedID: selectedSessionID, lines: lines,
                                    documentsBySession: documentsBySession, savedAt: .now)
        guard let data = try? JSONEncoder().encode(snapshot) else { return }
        let url = isMainJoeBro ? Self.mainCacheURL : Self.cacheURL
        try? FileManager.default.createDirectory(at: url.deletingLastPathComponent(), withIntermediateDirectories: true)
        try? data.write(to: url, options: [.atomic, .completeFileProtectionUnlessOpen])
    }
    var selectedSession: JBSession? { sessions.first { $0.id == selectedSessionID } }
    var selectedModel: JBModelChoice? { models.first { $0.id == selectedModelID } }

    func setPermissionMode(_ mode: String) {
        guard ["sandbox", "readonly", "full"].contains(mode) else { return }
        permissionMode = mode
        if mode == "full" { agentMode = true }
        UserDefaults.standard.set(mode, forKey: "chatPermissionMode")
    }

    func load() async {
        if isMainJoeBro { await loadMainJoeBro(); return }
        do {
            async let sessionsResult = api.sessions()
            async let modelsResult = api.models()
            async let prefsResult = api.preferences()
            sessions = try await sessionsResult.filter { $0.archived != true }
            models = try await modelsResult.filter { !$0.offline }
            if let prefs = try? await prefsResult { updateServerDefault(from: prefs) }
            if selectedSessionID == nil, let id = serverDefaultModelID {
                selectedModelID = id
            } else if selectedModel == nil {
                selectedModelID = serverDefaultModelID
                    ?? models.first(where: { $0.category == "local" && !$0.offline })?.id
                    ?? models.first(where: { !$0.offline })?.id ?? models.first?.id
            }
            if let id = selectedSessionID, !sessions.contains(where: { $0.id == id }) { selectedSessionID = nil; lines = [] }
            if selectedSessionID == nil && draft.isEmpty && pendingAttachments.isEmpty {
                selectedSessionID = sessions.first?.id
            }
            if let id = selectedSessionID { await select(id) }
            saveSnapshot()
        } catch { self.error = error.localizedDescription }
    }

    private func loadMainJoeBro() async {
        do {
            let profile = try await api.openJoeBro()
            models = (try? await api.models().filter { !$0.offline }) ?? []
            guard let session = profile.session else { throw JoeBroAPIError.invalidResponse }
            sessions = [session]
            selectedSessionID = session.id
            selectedModelID = models.first(where: {
                $0.modelID == profile.model && $0.endpointID == profile.endpointID
            })?.id
            agentMode = true
            useWeb = true
            allowBash = true
            permissionMode = profile.permissionMode
            mainConnectionIssue = nil
            error = nil
            await select(session.id)
        } catch {
            if case JoeBroAPIError.http(404, _) = error {
                mainConnectionIssue = "Update the backend to enable JoeBro."
            } else {
                mainConnectionIssue = "JoeBro is offline."
            }
        }
    }

    func refreshModels() async {
        do {
            models = try await api.models().filter { !$0.offline }
            if let prefs = try? await api.preferences() { updateServerDefault(from: prefs) }
            if selectedModel == nil {
                selectedModelID = serverDefaultModelID ?? models.first(where: { $0.category == "local" })?.id ?? models.first?.id
            }
        } catch { self.error = "Models: " + error.localizedDescription }
    }

    private func updateServerDefault(from prefs: [String: String]) {
        guard let model = prefs["default_model"], let endpoint = prefs["default_endpoint_id"] else {
            serverDefaultModelID = nil
            return
        }
        let id = model + "@" + endpoint
        serverDefaultModelID = models.contains(where: { $0.id == id }) ? id : nil
    }

    func select(_ id: String) async {
        selectedSessionID = id
        do {
            let history = try await api.history(id)
            guard selectedSessionID == id else { return }
            let previousLines = lines
            lines = history.history.map { message in
                // Resume polling must retain identity for already displayed rows.
                let existingID = previousLines.first { $0.serverID != nil && $0.serverID == message.databaseID }?.id
                var line = ChatLine(role: message.role, text: message.content, id: existingID ?? UUID())
                line.serverID = message.databaseID
                line.thinking = message.metadata?["thinking"]?.stringValue ?? ""
                line.toolCalls = message.metadata?["tool_events"]?.arrayValue?.map { event in
                    ChatToolCall(name: event["tool"]?.stringValue ?? "Tool",
                                 command: event["command"]?.stringValue ?? "",
                                 output: event["output"]?.stringValue ?? "",
                                 exitCode: event["exit_code"]?.intValue,
                                 finished: true)
                } ?? []
                line.attachments = message.metadata?["attachments"]?.arrayValue?.compactMap { $0["name"]?.stringValue } ?? []
                return line
            }
            if let index = lines.lastIndex(where: { $0.role == "assistant" }),
               let docs = documentsBySession[id], !docs.isEmpty { lines[index].documents = docs }
            if let session = selectedSession,
               let modelID = session.model ?? history.model,
               let endpointID = session.endpointID,
               let model = models.first(where: { $0.modelID == modelID && $0.endpointID == endpointID }) {
                selectedModelID = model.id
            } else if let model = models.first(where: { $0.modelID == history.model }) {
                selectedModelID = model.id
            } else if selectedModel == nil {
                selectedModelID = serverDefaultModelID ?? models.first?.id
            }
            agentMode = selectedSession?.mode == "agent"
            if let live = liveAssistants[id] {
                let baseline = turnBaselines[id] ?? previousLines.compactMap(\.serverID).max() ?? 0
                let replyPersisted = lines.contains { $0.role == "assistant" && ($0.serverID ?? 0) > baseline }
                if replyPersisted {
                    liveAssistants.removeValue(forKey: id)
                    pendingUsers.removeValue(forKey: id)
                    turnBaselines.removeValue(forKey: id)
                } else {
                    if let pending = pendingUsers[id],
                       !lines.contains(where: { $0.role == "user" && $0.text == pending.text && ($0.serverID ?? 0) > baseline }) {
                        lines.append(pending)
                    }
                    lines.append(live)
                }
            }
            saveSnapshot()
        } catch { self.error = error.localizedDescription }
    }

    func reconcileAfterResume() async {
        guard let id = selectedSessionID else { return }
        await select(id)
    }

    func newChat() async {
        selectedSessionID = nil
        selectedModelID = serverDefaultModelID
            ?? UserDefaults.standard.string(forKey: "selectedModelID")
            ?? models.first(where: { $0.category == "local" })?.id
            ?? models.first?.id
        Task { await refreshDefaultForDraft() }
        lines = []
        draft = ""
        pendingAttachments = []
        saveSnapshot()
    }

    private func refreshDefaultForDraft() async {
        guard let prefs = try? await api.preferences() else { return }
        updateServerDefault(from: prefs)
        if selectedSessionID == nil, let id = serverDefaultModelID {
            selectedModelID = id
        }
    }

    private func createSessionForTurn() async {
        guard !isMainJoeBro else { return }
        do {
            let model = selectedModel
            let session = try await api.createSession(name: "New Chat", model: model?.modelID ?? "",
                                                       endpointURL: model?.endpointURL ?? "", endpointID: model?.endpointID ?? "",
                                                       mode: (agentMode || permissionMode == "full") ? "agent" : "chat")
            sessions.insert(session, at: 0)
            selectedSessionID = session.id
            agentMode = session.mode == "agent"
            saveSnapshot()
        } catch { self.error = error.localizedDescription }
    }

    func renameSession(_ id: String, to name: String) async {
        let clean = name.trimmingCharacters(in: .whitespacesAndNewlines)
        guard !clean.isEmpty else { return }
        do {
            try await api.renameSession(id, name: clean)
            if let index = sessions.firstIndex(where: { $0.id == id }) { sessions[index].name = clean }
            saveSnapshot()
        } catch { self.error = error.localizedDescription }
    }

    func deleteSession(_ id: String) async {
        guard !workingSessions.contains(id) else {
            error = "Wait for this reply to finish before deleting the chat."
            return
        }
        do {
            try await api.deleteSession(id)
            sessions.removeAll { $0.id == id }
            documentsBySession.removeValue(forKey: id)
            liveAssistants.removeValue(forKey: id)
            pendingUsers.removeValue(forKey: id)
            turnBaselines.removeValue(forKey: id)
            if selectedSessionID == id {
                selectedSessionID = nil
                lines = []
                pendingAttachments = []
            }
            saveSnapshot()
        } catch { self.error = error.localizedDescription }
    }

    func compactSession(_ id: String) async {
        guard !workingSessions.contains(id) else {
            error = "Wait for this reply to finish before compacting the chat."
            return
        }
        do {
            let result = try await api.compactSession(id)
            if result.compacted { await select(id) }
            else { error = "This chat is still short enough that there is nothing to compact." }
        } catch { self.error = error.localizedDescription }
    }

    func compactJoeBro() async {
        guard isMainJoeBro, !busy, let id = selectedSessionID else { return }
        do {
            let result = try await api.compactJoeBro()
            if result.compacted { await select(id) }
            else { error = "This conversation is still short enough that there is nothing to compact." }
        } catch { self.error = error.localizedDescription }
    }

    func clearJoeBro() async {
        guard isMainJoeBro, !busy else { return }
        do {
            try await api.clearJoeBro()
            lines = []
            pendingAttachments = []
            draft = ""
            if let id = selectedSessionID {
                documentsBySession.removeValue(forKey: id)
                liveAssistants.removeValue(forKey: id)
                pendingUsers.removeValue(forKey: id)
                turnBaselines.removeValue(forKey: id)
            }
            saveSnapshot()
        } catch { self.error = error.localizedDescription }
    }

    func pickModel(_ choice: JBModelChoice) {
        selectedModelID = choice.id
        UserDefaults.standard.set(choice.id, forKey: "selectedModelID")
        guard let id = selectedSessionID else { return }
        Task {
            do {
                try await api.updateSessionModel(id, model: choice.modelID,
                                                 endpointURL: choice.endpointURL, endpointID: choice.endpointID)
                await reloadSessions()
            } catch { self.error = "Model switch: " + error.localizedDescription }
        }
    }

    func setThinking(_ enabled: Bool) {
        thinkingOn = enabled
        UserDefaults.standard.set(enabled, forKey: "thinkingOn")
    }

    func setAgentMode(_ enabled: Bool) {
        agentMode = enabled
        guard let id = selectedSessionID else { return }
        Task {
            do {
                try await api.setSessionMode(id, mode: enabled ? "agent" : "chat")
                await reloadSessions()
            } catch { self.error = "Mode switch: " + error.localizedDescription }
        }
    }

    func stopCurrentTurn() async {
        guard let id = selectedSessionID, busy, !stoppingSessions.contains(id),
              !stopRequestedSessions.contains(id) else { return }
        stoppingSessions.insert(id)
        defer { stoppingSessions.remove(id) }
        do {
            try await api.stopChat(sessionID: id)
            stopRequestedSessions.insert(id)
            // Keep consuming SSE/history: the backend acknowledges cancellation
            // between model/tool calls and may still be completing its current call.
            if permission != nil { permission = nil }
        } catch { self.error = "Could not stop JoeBro: " + error.localizedDescription }
    }

    func send() {
        let message = draft.trimmingCharacters(in: .whitespacesAndNewlines)
        guard !message.isEmpty || !pendingAttachments.isEmpty, !busy, !creatingSession else { return }
        let attachments = pendingAttachments
        draft = ""
        pendingAttachments = []
        if let id = selectedSessionID {
            startTurn(sessionID: id, message: message, attachments: attachments)
        } else {
            creatingSession = true
            Task {
                await createSessionForTurn()
                creatingSession = false
                if let id = selectedSessionID {
                    startTurn(sessionID: id, message: message, attachments: attachments)
                } else {
                    draft = message
                    pendingAttachments = attachments
                }
            }
        }
    }

    private func startTurn(sessionID: String, message: String, attachments: [JBUploadedFile]) {
        guard !workingSessions.contains(sessionID) else { return }
        workingSessions.insert(sessionID)
        stopRequestedSessions.remove(sessionID)
        let activityTitle = sessions.first(where: { $0.id == sessionID })?.name ?? "JoeBro"
        Task { await JoeBroActivityController().chatTurnBegan(sessionID: sessionID, title: activityTitle) }
        let model = selectedModel
        let mode = (agentMode || permissionMode == "full") ? "agent" : "chat"
        let web = useWeb
        let thinking = thinkingOn
        let fileAccess = permissionMode
        error = nil
        var userLine = ChatLine(role: "user", text: message)
        userLine.attachments = attachments.map(\.name)
        turnBaselines[sessionID] = lines.compactMap(\.serverID).max() ?? 0
        pendingUsers[sessionID] = userLine
        lines.append(userLine)
        var assistant = ChatLine(role: "assistant", text: "")
        assistant.streaming = true
        liveAssistants[sessionID] = assistant
        lines.append(assistant)
        saveSnapshot()
        let turn = JBChatTurn(message: message, sessionID: sessionID, mode: mode,
                              model: isMainJoeBro ? nil : model?.modelID,
                              endpointID: isMainJoeBro ? nil : model?.endpointID,
                              endpointURL: isMainJoeBro ? nil : model?.endpointURL, attachmentIDs: attachments.map(\.id),
                              useWeb: web, allowBash: allowBash, thinking: thinking ? nil : false,
                              permissionMode: fileAccess,
                              orchestrator: isMainJoeBro, askPermission: isMainJoeBro)
        Task {
            var streamError: Error?
            do {
                for try await event in api.chatStream(turn) {
                    guard var live = liveAssistants[sessionID] else { continue }
                    switch event {
                    case .delta(let value): live.text += value
                    case .thinking(let value): live.thinking += value
                    case .typed(let name, let json):
                        switch name {
                        case "tool_start":
                            live.toolCalls.append(ChatToolCall(name: json["tool"]?.stringValue ?? "Tool",
                                                               command: json["command"]?.stringValue ?? ""))
                        case "tool_output":
                            let name = json["tool"]?.stringValue ?? "Tool"
                            let index = live.toolCalls.lastIndex(where: { !$0.finished && $0.name == name })
                                ?? live.toolCalls.lastIndex(where: { !$0.finished })
                            if let index {
                                live.toolCalls[index].output = json["output"]?.stringValue ?? ""
                                live.toolCalls[index].exitCode = json["exit_code"]?.intValue
                                live.toolCalls[index].finished = true
                            }
                        case "doc_update":
                            if let id = json["doc_id"]?.stringValue, !id.isEmpty,
                               !live.documents.contains(where: { $0.id == id }) {
                                let document = ChatDocumentRef(id: id,
                                    title: json["title"]?.stringValue ?? "Document",
                                    language: json["language"]?.stringValue ?? "markdown")
                live.documents.append(document)
                documentsBySession[sessionID, default: []].append(document)
                            }
                        case "doc_stream_open":
                            live.toolCalls.append(ChatToolCall(name: "Writing document",
                                command: json["title"]?.stringValue ?? ""))
                        case "permission_request":
                            permission = (json["request_id"]?.stringValue ?? "", json["tool"]?.stringValue ?? "Tool", json["command"]?.stringValue ?? "")
                        default: break
                        }
                    case .done: break
                    }
                    liveAssistants[sessionID] = live
                    if selectedSessionID == sessionID,
                       let index = lines.firstIndex(where: { $0.id == live.id }) { lines[index] = live }
                }
            } catch { streamError = error }
            if var live = liveAssistants[sessionID] {
                // A dropped SSE connection does not necessarily stop the backend's
                // turn. Keep the partial answer visible while checking the
                // durable history; never post the user's message again.
                if streamError == nil { live.streaming = false }
                liveAssistants[sessionID] = live
                if selectedSessionID == sessionID,
                   let index = lines.firstIndex(where: { $0.id == live.id }) { lines[index] = live }
            }
            let interrupted: Bool
            if let streamError {
                if let apiError = streamError as? JoeBroAPIError,
                   case .streamInterrupted = apiError { interrupted = true }
                else { interrupted = streamError is URLError }
            } else { interrupted = false }
            var replyIsDurable = false
            // Model and tool work can continue server-side after the phone
            // loses its stream. Poll GET history long enough to recover it.
            for _ in 0..<(interrupted ? 90 : 10) {
                try? await Task.sleep(for: interrupted ? .seconds(1) : .milliseconds(500))
                if let history = try? await api.history(sessionID),
                   history.history.contains(where: { $0.role == "assistant" && ($0.databaseID ?? 0) > (turnBaselines[sessionID] ?? 0) }) {
                    replyIsDurable = true
                    if selectedSessionID == sessionID { await select(sessionID) }
                    break
                }
            }
            if var live = liveAssistants[sessionID] {
                live.streaming = false
                for index in live.toolCalls.indices where !live.toolCalls[index].finished {
                    live.toolCalls[index].finished = true
                }
                liveAssistants[sessionID] = live
                if selectedSessionID == sessionID,
                   let index = lines.firstIndex(where: { $0.id == live.id }) { lines[index] = live }
            }
            workingSessions.remove(sessionID)
            stopRequestedSessions.remove(sessionID)
            await JoeBroActivityController().chatTurnEnded(sessionID: sessionID, failed: streamError != nil && !replyIsDurable)
            if let streamError, !replyIsDurable {
                self.error = interrupted
                    ? "The connection dropped. JoeBro's partial reply is saved here; the server may still be working. Reopen the chat to check for the finished answer."
                    : streamError.localizedDescription
            }
            await reloadSessions()
            saveSnapshot()
        }
    }

    // MARK: - Folders
    //
    // Mirrors the Mac sidebar. Folders aren't an entity on the backend: the
    // set of folders is just the distinct `folder` strings across sessions,
    // so "new folder" means tagging a chat and a folder disappears with its
    // last member. Collapsed/pinned folder state is local, as it is on the Mac.

    // These must be observable stored values. Reading UserDefaults only through
    // computed properties does not invalidate the SwiftUI folder rows.
    var collapsedFolders = Set(UserDefaults.standard.stringArray(forKey: "collapsedChatFolders") ?? [])
    var pinnedFolders = Set(UserDefaults.standard.stringArray(forKey: "pinnedChatFolders") ?? [])

    /// Distinct folder names, pinned first then case-insensitive, as on the Mac.
    var folderNames: [String] {
        let names = Set(sessions.map(\.folderKey)).subtracting([""])
        return names.sorted { a, b in
            let pa = pinnedFolders.contains(a), pb = pinnedFolders.contains(b)
            if pa != pb { return pa }
            return a.localizedCaseInsensitiveCompare(b) == .orderedAscending
        }
    }

    /// Search-filtered sessions with pinned chats floated up, ordered by sortOrder.
    func visibleSessions(search: String) -> [JBSession] {
        let query = search.trimmingCharacters(in: .whitespacesAndNewlines)
        var base = sessions
        if !query.isEmpty { base = base.filter { $0.name.localizedCaseInsensitiveContains(query) } }
        base.sort { ($0.sortOrder ?? 0) < ($1.sortOrder ?? 0) }
        return base.filter { $0.isImportant == true } + base.filter { $0.isImportant != true }
    }

    func sessions(inFolder folder: String, search: String) -> [JBSession] {
        visibleSessions(search: search).filter { $0.folderKey == folder }
    }

    func toggleCollapsed(_ folder: String) {
        var set = collapsedFolders
        if set.contains(folder) { set.remove(folder) } else { set.insert(folder) }
        collapsedFolders = set
        UserDefaults.standard.set(Array(set), forKey: "collapsedChatFolders")
    }

    func toggleFolderPin(_ folder: String) {
        var set = pinnedFolders
        if set.contains(folder) { set.remove(folder) } else { set.insert(folder) }
        pinnedFolders = set
        UserDefaults.standard.set(Array(set), forKey: "pinnedChatFolders")
    }

    /// Fractional midpoint insertion so a move never renumbers the whole list.
    private func topOrder(of folder: String) -> Double {
        let orders = sessions.filter { $0.folderKey == folder }.compactMap(\.sortOrder)
        return (orders.min() ?? 0) - 1
    }

    func setFolder(_ id: String, to folder: String?) async {
        let key = (folder ?? "").trimmingCharacters(in: .whitespacesAndNewlines)
        guard let index = sessions.firstIndex(where: { $0.id == id }) else { return }
        let previousFolder = sessions[index].folder
        let previousOrder = sessions[index].sortOrder
        let order = topOrder(of: key)
        sessions[index].folder = key.isEmpty ? nil : key
        sessions[index].sortOrder = order
        sessions.sort { ($0.sortOrder ?? 0) < ($1.sortOrder ?? 0) }
        saveSnapshot()
        do { try await api.moveSession(id, folder: key, sortOrder: order) }
        catch {
            // Roll the single row back rather than dropping the user's whole list.
            if let i = sessions.firstIndex(where: { $0.id == id }) {
                sessions[i].folder = previousFolder
                sessions[i].sortOrder = previousOrder
            }
            self.error = error.localizedDescription
        }
    }

    func renameFolder(_ old: String, to new: String) async {
        let clean = new.trimmingCharacters(in: .whitespacesAndNewlines)
        guard !clean.isEmpty, clean != old else { return }
        for index in sessions.indices where sessions[index].folderKey == old { sessions[index].folder = clean }
        var collapsed = collapsedFolders, pinned = pinnedFolders
        if collapsed.remove(old) != nil { collapsed.insert(clean) }
        if pinned.remove(old) != nil { pinned.insert(clean) }
        collapsedFolders = collapsed
        pinnedFolders = pinned
        UserDefaults.standard.set(Array(collapsed), forKey: "collapsedChatFolders")
        UserDefaults.standard.set(Array(pinned), forKey: "pinnedChatFolders")
        saveSnapshot()
        do { try await api.renameFolder(old: old, new: clean) }
        catch { self.error = error.localizedDescription; await reloadSessions() }
    }

    /// Folders aren't an entity on the backend, so "delete folder" means
    /// untagging every chat in it. No conversation is destroyed.
    func removeFolder(_ folder: String) async {
        let ids = sessions.filter { $0.folderKey == folder }.map(\.id)
        for id in ids { await setFolder(id, to: nil) }
        var collapsed = collapsedFolders, pinned = pinnedFolders
        collapsed.remove(folder)
        pinned.remove(folder)
        collapsedFolders = collapsed
        pinnedFolders = pinned
        UserDefaults.standard.set(Array(collapsed), forKey: "collapsedChatFolders")
        UserDefaults.standard.set(Array(pinned), forKey: "pinnedChatFolders")
    }

    func togglePin(_ id: String) async {
        guard let index = sessions.firstIndex(where: { $0.id == id }) else { return }
        let next = !(sessions[index].isImportant ?? false)
        sessions[index].isImportant = next
        saveSnapshot()
        do { try await api.setSessionImportant(id, important: next) }
        catch {
            if let i = sessions.firstIndex(where: { $0.id == id }) { sessions[i].isImportant = !next }
            self.error = error.localizedDescription
        }
    }

    func archiveSession(_ id: String) async {
        do {
            try await api.archiveSession(id)
            sessions.removeAll { $0.id == id }
            documentsBySession.removeValue(forKey: id)
            if selectedSessionID == id { selectedSessionID = nil; lines = [] }
            saveSnapshot()
        } catch { self.error = error.localizedDescription }
    }

    func reloadSessions() async {
        if isMainJoeBro { return }
        if let latest = try? await api.sessions() { sessions = latest.filter { $0.archived != true }; saveSnapshot() }
    }

    func answerPermission(_ choice: String) async {
        guard let permission else { return }
        self.permission = nil
        do { try await api.respondToPermission(id: permission.id, decision: choice) }
        catch { self.error = error.localizedDescription }
    }
}

struct ChatsView: View {
    let store: ChatStore
    @Binding var openSharedDraft: Bool
    var externalSidebar = false
    var onOpenSidebar: (() -> Void)? = nil
    @State private var openSession: JBSession?
    @State private var openDraft = false
    // Capture used to be its own tab; it belongs in the composer, as on the Mac.
    @State private var selectedPhoto: PhotosPickerItem?
    @State private var voice = VoiceCapture()
    @State private var showFiles = false
    @State private var openDocument: ChatDocumentRef?
    @State private var openDocumentSessionID: String?
    @State private var showFilePicker = false
    @State private var renameTargetID: String?
    @State private var renameName = ""
    @State private var deleteTargetID: String?
    @State private var compactTargetID: String?

    var body: some View {
        NavigationStack {
            if externalSidebar {
                chatDetail
            } else {
                SessionListView(store: store, onOpen: { session in openSession = session },
                                onNewChat: { openDraft = true })
                    .navigationDestination(item: $openSession) { session in
                        chatDetail
                            .task { await store.select(session.id) }
                    }
                    .navigationDestination(isPresented: $openDraft) { chatDetail }
            }
        }
        .task { await store.load() }
        .task { showSharedDraftIfNeeded() }
        .onChange(of: openSharedDraft) { _, _ in showSharedDraftIfNeeded() }
        .onChange(of: store.sessions.map(\.id)) { _, ids in
            if let openSession, !ids.contains(openSession.id) {
                self.openSession = nil
                openDraft = false
            }
        }
        .alert("Rename chat", isPresented: Binding(get: { renameTargetID != nil }, set: { if !$0 { renameTargetID = nil } })) {
            TextField("Name", text: $renameName)
            Button("Cancel", role: .cancel) { renameTargetID = nil }
            Button("Save") {
                if let id = renameTargetID { Task { await store.renameSession(id, to: renameName) } }
                renameTargetID = nil
            }
        }
        .alert("Delete \u{201C}\(store.sessions.first { $0.id == deleteTargetID }?.name ?? "this chat")\u{201D}?",
                            isPresented: Binding(get: { deleteTargetID != nil }, set: { if !$0 { deleteTargetID = nil } })) {
            Button("Delete chat", role: .destructive) {
                if let id = deleteTargetID {
                    // Release the detail route before its backing session is removed.
                    if openSession?.id == id { openSession = nil; openDraft = false }
                    Task { await store.deleteSession(id) }
                }
                deleteTargetID = nil
            }
            Button("Cancel", role: .cancel) { deleteTargetID = nil }
        } message: { Text("The conversation and its messages are removed from JoeBro. This cannot be undone.") }
        .alert("JoeBro", isPresented: Binding(get: { store.error != nil }, set: { if !$0 { store.error = nil } })) {
            Button("OK") { store.error = nil }
        } message: { Text(store.error ?? "") }
        .alert("Allow \(store.permission?.tool ?? "tool")?", isPresented: Binding(get: { store.permission != nil }, set: { if !$0 { Task { await store.answerPermission("deny") } } })) {
            Button("Deny", role: .cancel) { Task { await store.answerPermission("deny") } }
            Button("Allow once") { Task { await store.answerPermission("allow") } }
            Button("Always allow this session") { Task { await store.answerPermission("always") } }
        } message: { Text(store.permission?.command ?? "") }
    }

    private func showSharedDraftIfNeeded() {
        guard openSharedDraft else { return }
        openSession = nil
        openDraft = true
        openSharedDraft = false
    }

    /// Toolbar glyphs need an explicit colour: the global tint is accentTint,
    /// not white, so an untinted icon-only button reads as washed out.
    private func toolbarIcon(_ symbol: String) -> some View {
        Image(systemName: symbol)
            .font(.body.weight(.medium))
            .foregroundStyle(.white)
    }

    private var chatDetail: some View {
        Group {
            ChatTranscriptView(store: store, onOpenDocument: { document in
                openDocumentSessionID = store.selectedSessionID
                openDocument = document
            }, composer: {
                ChatComposerView(store: store, selectedPhoto: $selectedPhoto,
                                 showFilePicker: $showFilePicker, voice: voice,
                                 onOpenWorkdir: { showFiles = true })
            })
            .jbWallpaper()
            .navigationTitle(store.selectedSession?.name ?? "JoeBro")
            .navigationBarTitleDisplayMode(.inline)
            .toolbar {
                if externalSidebar, onOpenSidebar != nil {
                    ToolbarItem(placement: .topBarLeading) {
                        Button { onOpenSidebar?() } label: { toolbarIcon("sidebar.left") }
                            .accessibilityLabel("Open sidebar")
                    }
                }
                ToolbarItemGroup(placement: .topBarTrailing) {
                    if let selected = store.selectedSession {
                        Menu {
                            Button("Rename chat", systemImage: "pencil") {
                                renameName = selected.name
                                renameTargetID = selected.id
                            }
                            Button("Compact chat", systemImage: "arrow.down.right.and.arrow.up.left") {
                                compactTargetID = selected.id
                            }
                            Button("Delete chat", systemImage: "trash", role: .destructive) {
                                deleteTargetID = selected.id
                            }
                        } label: { toolbarIcon("ellipsis.circle") }
                            .accessibilityLabel("Chat actions")
                    }
                    Button { showFiles = true } label: {
                        toolbarIcon(store.selectedSession?.workdir?.trimmingCharacters(in: .whitespacesAndNewlines).isEmpty == false
                                    ? "folder" : "folder.badge.plus")
                    }
                    .accessibilityLabel(store.selectedSession?.workdir?.trimmingCharacters(in: .whitespacesAndNewlines).isEmpty == false
                                        ? "Open bound folder" : "Bind a folder")
                }
            }
            .alert("Compact this chat?", isPresented: Binding(
                get: { compactTargetID != nil }, set: { if !$0 { compactTargetID = nil } }
            )) {
                Button("Compact chat") {
                    if let id = compactTargetID { Task { await store.compactSession(id) } }
                    compactTargetID = nil
                }
                Button("Cancel", role: .cancel) { compactTargetID = nil }
            } message: { Text("JoeBro will summarize older turns and keep recent messages. This cannot be undone.") }
            .onChange(of: selectedPhoto) { _, item in
                let targetSessionID = store.selectedSessionID
                Task {
                    guard let data = try? await item?.loadTransferable(type: Data.self) else { return }
                    store.uploadingAttachment = true
                    defer { store.uploadingAttachment = false }
                    do {
                        let type = item?.supportedContentTypes.first
                        let mime = type?.preferredMIMEType ?? "image/jpeg"
                        let ext = type?.preferredFilenameExtension ?? "jpg"
                        let uploaded = try await store.api.upload(data: data, filename: "photo.\(ext)", mimeType: mime)
                        if store.selectedSessionID == targetSessionID {
                            store.pendingAttachments.append(uploaded)
                        } else {
                            store.error = "Photo uploaded, but the chat changed. Attach it again in the intended chat."
                        }
                    } catch { store.error = error.localizedDescription }
                    selectedPhoto = nil
                }
            }
            .fileImporter(isPresented: $showFilePicker, allowedContentTypes: [.item], allowsMultipleSelection: true) { result in
                let targetSessionID = store.selectedSessionID
                Task {
                    do {
                        let urls = try result.get()
                        store.uploadingAttachment = true
                        defer { store.uploadingAttachment = false }
                        for url in urls {
                            let scoped = url.startAccessingSecurityScopedResource()
                            defer { if scoped { url.stopAccessingSecurityScopedResource() } }
                            let data = try Data(contentsOf: url)
                            let type = UTType(filenameExtension: url.pathExtension)
                            let uploaded = try await store.api.upload(data: data, filename: url.lastPathComponent,
                                                                       mimeType: type?.preferredMIMEType ?? "application/octet-stream")
                            if store.selectedSessionID == targetSessionID {
                                store.pendingAttachments.append(uploaded)
                            } else {
                                store.error = "File uploaded, but the chat changed. Attach it again in the intended chat."
                                break
                            }
                        }
                    } catch { store.error = error.localizedDescription }
                }
            }
            .sheet(item: $openDocument) { document in
                NavigationStack {
                    DocumentEditorView(api: store.api,
                        source: document.id.hasPrefix("local-") && openDocumentSessionID != nil
                            ? .workdir(session: openDocumentSessionID!, sub: String(document.id.dropFirst(6)))
                            : .library(id: document.id),
                        fallbackTitle: document.title)
                        .toolbar { ToolbarItem(placement: .cancellationAction) {
                            Button("Done") { openDocument = nil }
                        } }
                }
            }
            .sheet(isPresented: $showFiles) {
                NavigationStack {
                    if let sessionID = store.selectedSessionID {
                        WorkdirView(api: store.api, sessionID: sessionID)
                            .toolbar { ToolbarItem(placement: .cancellationAction) {
                                Button("Done") { showFiles = false }
                            } }
                    } else {
                        Text("Open a chat first.").foregroundStyle(.secondary)
                    }
                }
            }
            .onChange(of: showFiles) { _, visible in
                if !visible { Task { await store.reloadSessions() } }
            }
        }
    }

}
