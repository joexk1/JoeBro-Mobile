import SwiftUI

@MainActor
@Observable final class AgentsStore {
    let api: JoeBroAPI
    let chatStore: ChatStore
    let mainJoeBro: ChatStore
    var agents: [JBAgentRecord] = []
    var sessions: [JBSession] = []
    var sessionsLoaded = false
    var activeOnly = true
    var filter: JBAgentKind?
    var search = ""
    var loading = true
    private var hasLoaded = false
    var error: String?
    private var poll: Task<Void, Never>?
    private let activities = JoeBroActivityController()

    init(api: JoeBroAPI, chatStore: ChatStore, mainJoeBro: ChatStore) {
        self.api = api
        self.chatStore = chatStore
        self.mainJoeBro = mainJoeBro
    }

    /// The backend deduplicates by session. Repeat that rule for older registry
    /// builds where one scheduled task also appears as a working chat.
    var uniqueAgents: [JBAgentRecord] {
        let existingSessions = Set(sessions.map(\.id))
        let validRegistry = agents.filter { agent in
            if agent.kind == .briefing || agent.id == "brf_current" { return false }
            guard sessionsLoaded, let session = agent.sessionID, !session.isEmpty else { return true }
            if existingSessions.contains(session) { return true }
            // A running or queued run is live whether or not the (concurrently
            // fetched) session list has caught up with its chat yet.
            return agent.isLive
        }
        var preferred: [String: JBAgentRecord] = [:]
        for agent in validRegistry {
            guard let session = agent.sessionID?.trimmingCharacters(in: .whitespacesAndNewlines),
                  !session.isEmpty else { continue }
            if let prior = preferred[session] {
                if rank(agent.kind) < rank(prior.kind) { preferred[session] = agent }
            } else { preferred[session] = agent }
        }
        var seenIDs = Set<String>()
        let registry = validRegistry.filter { agent in
            guard seenIDs.insert(agent.id).inserted else { return false }
            guard let session = agent.sessionID?.trimmingCharacters(in: .whitespacesAndNewlines),
                  !session.isEmpty else { return true }
            return preferred[session]?.id == agent.id
        }
        let represented = Set(registry.compactMap(\.sessionID))
        let sessionAgents = sessions.filter { session in
            session.mode == "agent" && session.id != "pulse_agent" && !represented.contains(session.id)
        }.map { session in
            JBAgentRecord(agentModeSession: session,
                          kind: session.id.hasPrefix("task_session_") ? .task : .chat)
        }
        return (registry + sessionAgents).map { agent in
            guard let session = agent.sessionID, chatStore.workingSessions.contains(session),
                  agent.kind == .chat || agent.kind == .task else { return agent }
            return JBAgentRecord(copying: agent, localStatus: "running")
        }.sorted {
            ($0.createdAt ?? "") > ($1.createdAt ?? "")
        }
    }

    var scoped: [JBAgentRecord] { activeOnly ? uniqueAgents.filter(\.isLive) : uniqueAgents }

    var visible: [JBAgentRecord] {
        let byKind = filter.map { kind in scoped.filter { ($0.kind ?? .unknown) == kind } } ?? scoped
        let query = search.trimmingCharacters(in: .whitespacesAndNewlines)
        let list = query.isEmpty ? byKind : byKind.filter { agent in
            [agent.displayTitle, agent.progress ?? "", agent.result ?? "", agent.kind?.label ?? "", agent.status ?? ""]
                .contains { $0.localizedCaseInsensitiveContains(query) }
        }
        return list.filter(\.isLive) + list.filter { !$0.isLive }
    }

    var liveCount: Int { uniqueAgents.filter(\.isLive).count + (mainJoeBro.busy ? 1 : 0) }
    var allCount: Int { uniqueAgents.count + 1 }
    func count(for kind: JBAgentKind?) -> Int {
        guard let kind else { return scoped.count + ((!activeOnly || mainJoeBro.busy) ? 1 : 0) }
        return scoped.filter { ($0.kind ?? .unknown) == kind }.count
    }

    var recentFinished: JBAgentRecord? {
        uniqueAgents.first { !$0.isLive && (filter == nil || ($0.kind ?? .unknown) == filter) }
    }

    /// Name of the agent or chat session that spawned `agent`, if known.
    func parentName(of agent: JBAgentRecord) -> String? {
        guard let parent = agent.parentID, !parent.isEmpty else { return nil }
        if let match = agents.first(where: { $0.id == parent || $0.sessionID == parent }) {
            return match.displayTitle
        }
        if let session = sessions.first(where: { $0.id == parent }), !session.name.isEmpty {
            return session.name
        }
        return nil
    }

    private func rank(_ kind: JBAgentKind?) -> Int {
        switch kind ?? .unknown {
        case .task: 0
        case .research: 1
        case .chat: 2
        case .subagent, .briefing, .unknown: 3
        }
    }

    func load() async {
        loading = !hasLoaded
        defer { loading = false; hasLoaded = true }
        async let sessionRequest = api.sessions()
        async let registryRequest = api.agentRegistry()
        do {
            sessions = try await sessionRequest
            sessionsLoaded = true
            agents = try await registryRequest
            await activities.reconcileAgents(agents)
            error = nil
        } catch { self.error = error.localizedDescription }
    }

    /// Poll only while this tab is visible. A new job can start elsewhere in
    /// the app while the list is open, so keep checking after the last job ends.
    func startPolling() {
        poll?.cancel()
        poll = Task {
            while !Task.isCancelled {
                await load()
                try? await Task.sleep(for: .seconds(liveCount > 0 ? 5 : 20))
            }
        }
    }

    func stopPolling() { poll?.cancel(); poll = nil }

    func cancel(_ agent: JBAgentRecord) async {
        do {
            if let session = agent.sessionID, chatStore.workingSessions.contains(session) {
                try await api.stopChatAgentSession(id: session)
            } else {
                try await api.cancelAgent(id: agent.id)
            }
            await load()
        }
        catch { self.error = error.localizedDescription }
    }
}

/// JoeBro's research runs, working chats, and background tasks.
struct AgentsTabView: View {
    let api: JoeBroAPI
    let chatStore: ChatStore
    let mainJoeBro: ChatStore
    @State private var store: AgentsStore
    @State private var open: JBAgentRecord?
    @State private var stopTarget: JBAgentRecord?
    @State private var symbolsReady = false
    @Environment(\.accessibilityReduceMotion) private var reduceMotion
    var onOpenSettings: () -> Void = {}
    var onOpenJoeBro: () -> Void = {}

    init(api: JoeBroAPI, chatStore: ChatStore, mainJoeBro: ChatStore,
         onOpenSettings: @escaping () -> Void = {}, onOpenJoeBro: @escaping () -> Void = {}) {
        self.api = api
        self.chatStore = chatStore
        self.mainJoeBro = mainJoeBro
        self.onOpenSettings = onOpenSettings
        self.onOpenJoeBro = onOpenJoeBro
        _store = State(initialValue: AgentsStore(api: api, chatStore: chatStore, mainJoeBro: mainJoeBro))
    }

    private var scroller: some View {
        ScrollView {
            LazyVStack(alignment: .leading, spacing: 14) {
                filters
                content
            }
            .padding(.horizontal, 16)
            .padding(.vertical, 14)
        }
        .scrollIndicators(.hidden)
        .jbWallpaper()
        .searchable(text: Bindable(store).search, prompt: "Search agents")
        .refreshable { await store.load() }
    }

    var body: some View {
        NavigationStack {
            scroller
            .navigationTitle("Agents")
            .navigationBarTitleDisplayMode(.inline)
            .toolbar {
                ToolbarItem(placement: .topBarTrailing) {
                    Button { onOpenSettings() } label: {
                        Image(systemName: "gearshape")
                            .foregroundStyle(Color.accentTint)
                            .frame(width: 44, height: 44)
                    }
                        .accessibilityLabel("Settings")
                }
            }
            .navigationDestination(item: $open) { agent in
                AgentDetailView(api: api, agent: agent, chatStore: chatStore)
            }
            .task {
                if mainJoeBro.selectedSessionID == nil { await mainJoeBro.load() }
                store.startPolling()
            }
            .onAppear { symbolsReady = true }
            .onDisappear { store.stopPolling() }
            .alert("Agents", isPresented: alertBinding(Bindable(store).error)) {
                Button("OK") { store.error = nil }
            } message: { Text(store.error ?? "") }
            .alert("Stop \(stopTarget?.displayTitle ?? "agent")?", isPresented: Binding(
                get: { stopTarget != nil }, set: { if !$0 { stopTarget = nil } }
            )) {
                Button("Keep running", role: .cancel) { stopTarget = nil }
                if let stopTarget {
                    Button("Ask to stop", role: .destructive) {
                        Task { await store.cancel(stopTarget) }
                        self.stopTarget = nil
                    }
                }
            } message: {
                Text("The backend will request cancellation. The run may take a moment to finish.")
            }
        }
    }

    @ViewBuilder
    private var content: some View {
        if store.loading {
            ProgressView("Loading agents…")
                .tint(.white)
                .frame(maxWidth: .infinity, minHeight: 180)
        } else if store.visible.isEmpty && !showJoeBroCard {
            emptyState
        } else {
            sectionHeader
            if showJoeBroCard { mainAgentCard }
            ForEach(store.visible) { agent in
                agentRow(agent)
            }
        }
    }

    private var showJoeBroCard: Bool {
        mainAgentMatchesSearch &&
        store.filter == nil &&
        (!store.activeOnly || mainJoeBro.busy)
    }

    private var mainAgentMatchesSearch: Bool {
        let query = store.search.trimmingCharacters(in: .whitespacesAndNewlines)
        return query.isEmpty || "JoeBro".localizedCaseInsensitiveContains(query)
    }

    private var mainAgentCard: some View {
        Button(action: onOpenJoeBro) {
            HStack(spacing: 15) {
                ZStack {
                    RoundedRectangle(cornerRadius: 16, style: .continuous)
                        .fill(.white)
                        .frame(width: 49, height: 49)
                    Image(systemName: "face.smiling")
                        .font(.system(size: 29, weight: .light))
                        .foregroundStyle(Color.accentTint)
                        .symbolEffect(.pulse, options: .repeating, isActive: mainJoeBro.busy && !reduceMotion)
                }
                VStack(alignment: .leading, spacing: 5) {
                    Text("JoeBro")
                        .font(.headline)
                        .foregroundStyle(.white)
                    HStack(spacing: 6) {
                        Circle()
                            .fill(mainJoeBro.busy ? Color.yellow :
                                  mainJoeBro.mainConnectionIssue == nil ? Color.green : Color.gray)
                            .frame(width: 7, height: 7)
                        Text(mainJoeBro.busy ? "Working now" :
                             mainJoeBro.mainConnectionIssue == nil ? "Standing by" : "Offline")
                            .font(.caption)
                            .foregroundStyle(.white.opacity(0.72))
                    }
                }
                Spacer(minLength: 4)
                Image(systemName: "chevron.right")
                    .font(.caption2.bold())
                    .foregroundStyle(.white.opacity(0.55))
            }
            .padding(16)
            .frame(maxWidth: .infinity, alignment: .leading)
            .background(Color.accentTint.opacity(0.22), in: RoundedRectangle(cornerRadius: 22))
            .overlay(RoundedRectangle(cornerRadius: 22).strokeBorder(.white.opacity(0.2)))
            .contentShape(Rectangle())
        }
        .buttonStyle(AgentCardPressStyle(reduceMotion: reduceMotion))
        .accessibilityLabel("JoeBro, \(mainJoeBro.busy ? "working now" : mainJoeBro.mainConnectionIssue == nil ? "standing by" : "offline")")
        .accessibilityHint("Opens JoeBro's conversation")
    }

    private var sectionHeader: some View {
        HStack {
            Text(store.activeOnly ? "RUNNING NOW" : "RECENT ACTIVITY")
                .font(.caption2.weight(.bold)).tracking(1.5)
                .foregroundStyle(.white.opacity(0.6))
            Spacer()
            Text("\(store.visible.count + (showJoeBroCard ? 1 : 0))")
                .font(.caption.monospacedDigit())
                .foregroundStyle(.white.opacity(0.55))
                .contentTransition(.numericText())
        }
        .padding(.horizontal, 3)
    }

    @ViewBuilder
    private func agentRow(_ agent: JBAgentRecord) -> some View {
        if agent.isLive && agent.cancelRequested != true {
            Button { open = agent } label: { row(agent) }
                .buttonStyle(AgentCardPressStyle(reduceMotion: reduceMotion))
                .contextMenu {
                    Button("Ask to stop", systemImage: "stop.fill", role: .destructive) {
                        stopTarget = agent
                    }
                }
        } else {
            Button { open = agent } label: { row(agent) }
                .buttonStyle(AgentCardPressStyle(reduceMotion: reduceMotion))
        }
    }

    private var filters: some View {
        VStack(alignment: .leading, spacing: 14) {
            Picker("Agent history", selection: Bindable(store).activeOnly) {
                Text("Active \(store.liveCount)").tag(true)
                Text("All \(store.allCount)").tag(false)
            }
            .pickerStyle(.segmented)
            HStack {
                Text("KIND")
                    .font(.caption2.weight(.bold)).tracking(1.5)
                    .foregroundStyle(.white.opacity(0.6))
                Spacer()
                if store.filter != nil {
                    Button("Show all") { withAnimation(reduceMotion ? nil : .easeOut(duration: 0.18)) {
                        store.filter = nil
                    } }
                        .font(.caption.weight(.semibold))
                        .foregroundStyle(.white)
                }
            }
            .padding(.horizontal, 3)
            LazyVGrid(columns: [GridItem(.adaptive(minimum: 145), spacing: 10)], spacing: 10) {
                ForEach([JBAgentKind.chat, .research, .task, .subagent], id: \.self) { kind in
                    kindCard(kind)
                }
            }
        }
        .padding(.bottom, 6)
    }

    private func kindCard(_ kind: JBAgentKind) -> some View {
        let selected = store.filter == kind
        return Button {
            withAnimation(reduceMotion ? nil : .easeOut(duration: 0.18)) {
                store.filter = selected ? nil : kind
            }
        } label: {
            HStack(spacing: 10) {
                Image(systemName: kind.symbol)
                    .font(.system(size: 17, weight: .medium))
                    .frame(width: 28)
                    .foregroundStyle(selected ? .white : .white.opacity(0.72))
                    .scaleEffect(reduceMotion || symbolsReady ? 1 : 0.92)
                    .opacity(reduceMotion || symbolsReady ? 1 : 0.75)
                    .animation(reduceMotion ? nil : .easeOut(duration: 0.18), value: symbolsReady)
                VStack(alignment: .leading, spacing: 2) {
                    Text(kind.label).font(.subheadline.weight(.semibold))
                    Text(store.activeOnly ? "active" : "total")
                        .font(.caption2).foregroundStyle(.white.opacity(0.55))
                }
                Spacer(minLength: 2)
                Text("\(store.count(for: kind))")
                    .font(.subheadline.weight(.semibold).monospacedDigit())
                    .foregroundStyle(.white.opacity(0.78))
                    .contentTransition(.numericText())
            }
            .foregroundStyle(.white)
            .padding(.horizontal, 13)
            .frame(height: 63)
            .background(selected ? .white.opacity(0.22) : .white.opacity(0.085), in: RoundedRectangle(cornerRadius: 17))
            .overlay(RoundedRectangle(cornerRadius: 17).strokeBorder(.white.opacity(selected ? 0.32 : 0.1)))
        }
        .buttonStyle(AgentCardPressStyle(reduceMotion: reduceMotion))
        .accessibilityLabel("\(kind.label), \(store.count(for: kind)) \(store.activeOnly ? "active" : "total")")
    }

    @ViewBuilder private func spawnedByLabel(_ agent: JBAgentRecord) -> some View {
        if agent.kind == .subagent, agent.parentID != nil {
            Label("Spawned by \(store.parentName(of: agent) ?? "another agent")",
                  systemImage: "arrow.turn.down.right")
                .font(.caption)
                .foregroundStyle(.secondary)
                .lineLimit(1)
        }
    }

    private func row(_ agent: JBAgentRecord) -> some View {
        VStack(alignment: .leading, spacing: 10) {
            HStack(alignment: .top, spacing: 12) {
                Image(systemName: (agent.kind ?? .unknown).symbol)
                    .font(.system(size: 18, weight: .medium))
                    .foregroundStyle(.white)
                    .frame(width: 40, height: 40)
                    .background(.white.opacity(0.13), in: RoundedRectangle(cornerRadius: 12))
                VStack(alignment: .leading, spacing: 5) {
                    Text(agent.displayTitle)
                        .font(.subheadline.weight(.semibold))
                        .foregroundStyle(.white)
                        .lineLimit(2)
                        .multilineTextAlignment(.leading)
                    spawnedByLabel(agent)
                    HStack(spacing: 7) {
                        Circle().fill(statusColor(agent)).frame(width: 7, height: 7)
                        Text(statusLabel(agent))
                        Text("·")
                        Text((agent.kind ?? .unknown).label)
                        if agent.kind == .research, let count = agent.sourceCount, count > 0 {
                            Text("·")
                            Text("\(count) sources")
                        }
                    }
                    .font(.caption)
                    .foregroundStyle(.white.opacity(0.66))
                }
                Spacer(minLength: 5)
                if agent.isLive { ProgressView().controlSize(.small).tint(.white) }
                else { Image(systemName: "chevron.right").font(.caption2.bold()).foregroundStyle(.white.opacity(0.4)) }
            }
            if let preview = agent.isLive ? agent.progress : (agent.failed ? agent.error : agent.result),
               !preview.trimmingCharacters(in: .whitespacesAndNewlines).isEmpty {
                Text(preview.trimmingCharacters(in: .whitespacesAndNewlines))
                    .font(.caption)
                    .foregroundStyle(.white.opacity(0.7))
                    .lineLimit(2)
                    .multilineTextAlignment(.leading)
            }
            if let date = [agent.finishedAt, agent.startedAt, agent.createdAt].compactMap({ $0 }).first(where: { !$0.isEmpty }) {
                Text(agentRelativeDate(date))
                    .font(.caption2)
                    .foregroundStyle(.white.opacity(0.48))
            }
        }
        .frame(maxWidth: .infinity, alignment: .leading)
        .padding(15)
        .background(.ultraThinMaterial, in: RoundedRectangle(cornerRadius: 20))
        .overlay(RoundedRectangle(cornerRadius: 20).strokeBorder(.white.opacity(0.11)))
        .contentShape(Rectangle())
    }

    private var emptyState: some View {
        VStack(alignment: .leading, spacing: 13) {
            Image(systemName: store.activeOnly ? "circle.dotted.circle" : "person.3.sequence")
                .font(.system(size: 30, weight: .light))
                .foregroundStyle(.white.opacity(0.8))
            Text(store.search.isEmpty ? (store.activeOnly ? "Quiet right now" : "No agents yet") : "No matches")
                .font(.title3.weight(.semibold))
                .foregroundStyle(.white)
            if !store.search.isEmpty || !store.activeOnly {
                Text(store.search.isEmpty ? "Completed work will collect here." : "Try another search or kind.")
                    .font(.subheadline)
                    .foregroundStyle(.white.opacity(0.65))
            }
            if store.filter != nil {
                Button("Show all kinds") { store.filter = nil }
                    .font(.subheadline.weight(.semibold))
                    .foregroundStyle(.white)
            }
        }
        .frame(maxWidth: .infinity, alignment: .leading)
        .padding(21)
        .background(.white.opacity(0.075), in: RoundedRectangle(cornerRadius: 22))
        .overlay(RoundedRectangle(cornerRadius: 22).strokeBorder(.white.opacity(0.1)))
    }
}

/// One agent's full result, plus a way into the chat transcript behind it.
struct AgentDetailView: View {
    let api: JoeBroAPI
    let agent: JBAgentRecord
    /// Agents that ran in a chat can be opened in that chat, which is where
    /// their full transcript lives.
    let chatStore: ChatStore
    @State private var full: JBAgentRecord?
    @State private var loading = true
    @State private var error: String?
    @State private var confirmStop = false
    @State private var cancelNote: String?
    @State private var sessionMessages: [JBAgentMessage] = []

    private var current: JBAgentRecord {
        let record = full ?? agent
        guard let session = record.sessionID else { return record }
        if chatStore.workingSessions.contains(session) {
            return JBAgentRecord(copying: record, localStatus: "running")
        }
        if record.isSessionOnly { return JBAgentRecord(copying: record, localStatus: "idle") }
        return record
    }
    private var displayedMessages: [JBAgentMessage] { current.messages ?? sessionMessages }
    private var displayedResult: String? {
        if let result = current.result, !result.isEmpty { return result }
        if current.isSessionOnly { return sessionMessages.last(where: { $0.role == "assistant" })?.content }
        return nil
    }
    private var displayedReport: String? {
        guard let result = displayedResult else { return nil }
        guard current.kind == .research, current.sources?.isEmpty == false,
              let range = result.range(of: "\n## Sources\n") else { return result }
        return String(result[..<range.lowerBound])
    }

    var body: some View {
        ScrollView {
            VStack(alignment: .leading, spacing: 16) {
                header
                if loading && full == nil {
                    ProgressView().tint(.white).frame(maxWidth: .infinity).padding(.vertical, 30)
                }
                if let error = current.error, !error.isEmpty {
                    Text(error)
                        .font(.footnote)
                        .foregroundStyle(.red)
                        .frame(maxWidth: .infinity, alignment: .leading)
                        .padding(14).jbGlass(16)
                }
                if let cancelNote {
                    Label(cancelNote, systemImage: "stop.circle")
                        .font(.footnote)
                        .foregroundStyle(.secondary)
                        .frame(maxWidth: .infinity, alignment: .leading)
                }
                if let result = displayedReport, !result.isEmpty {
                    MarkdownText(text: result)
                        .textSelection(.enabled)
                        .frame(maxWidth: .infinity, alignment: .leading)
                        .padding(16).jbGlass(20)
                } else if !loading && !current.isLive {
                    Text(current.isSessionOnly ? "No replies in this chat yet." : "This agent finished without a result.")
                        .font(.footnote).foregroundStyle(.secondary)
                }
                if let sources = current.sources, !sources.isEmpty {
                    ResearchSourcesView(sources: sources)
                }
                if !displayedMessages.isEmpty {
                    VStack(alignment: .leading, spacing: 12) {
                        Text("Transcript")
                            .font(.headline)
                            .foregroundStyle(.white)
                        ForEach(Array(displayedMessages.enumerated()), id: \.offset) { index, message in
                            VStack(alignment: .leading, spacing: 4) {
                                Text(message.role.capitalized)
                                    .font(.caption.weight(.semibold))
                                    .foregroundStyle(.white.opacity(0.55))
                                Text(message.content)
                                    .font(.subheadline)
                                    .foregroundStyle(.white.opacity(0.88))
                                    .textSelection(.enabled)
                            }
                            .frame(maxWidth: .infinity, alignment: .leading)
                            if index < displayedMessages.count - 1 { Divider().overlay(.white.opacity(0.1)) }
                        }
                    }
                    .padding(16)
                    .jbGlass(20)
                }
            }
            .padding(16)
        }
        .scrollIndicators(.hidden)
        .navigationTitle(current.displayTitle)
        .navigationBarTitleDisplayMode(.inline)
        .jbWallpaper()
        .toolbar {
            if current.isLive {
                ToolbarItem(placement: .topBarTrailing) {
                    Button("Stop", systemImage: "stop.fill", role: .destructive) { confirmStop = true }
                }
            }
        }
        .task {
            if agent.isSessionOnly {
                if let id = agent.sessionID {
                    repeat {
                        do {
                            let history = try await api.history(id)
                            sessionMessages = history.history.map { JBAgentMessage(role: $0.role, content: $0.content) }
                            error = nil
                        } catch { self.error = error.localizedDescription }
                        loading = false
                        guard chatStore.workingSessions.contains(id) else { break }
                        try? await Task.sleep(for: .seconds(5))
                    } while !Task.isCancelled
                }
                loading = false
                return
            }
            // Keep a running detail open until its final result is available.
            while !Task.isCancelled {
                do { full = try await api.agentDetail(id: agent.id); error = nil }
                catch { self.error = error.localizedDescription }
                loading = false
                guard current.isLive else { break }
                try? await Task.sleep(for: .seconds(5))
            }
        }
        .alert("Agent", isPresented: alertBinding($error)) {
            Button("OK") { error = nil }
        } message: { Text(error ?? "") }
        .alert("Stop \(current.displayTitle)?", isPresented: $confirmStop) {
            Button("Keep running", role: .cancel) { }
            Button("Ask to stop", role: .destructive) {
                Task {
                    do {
                        if let session = agent.sessionID, chatStore.workingSessions.contains(session) {
                            try await api.stopChatAgentSession(id: session)
                        } else {
                            try await api.cancelAgent(id: agent.id)
                        }
                        cancelNote = "Stop requested. The agent may take a moment to finish."
                        if !agent.isSessionOnly { full = try await api.agentDetail(id: agent.id) }
                    } catch { self.error = error.localizedDescription }
                }
            }
        } message: {
            Text("The backend will request cancellation. The run may take a moment to finish.")
        }
    }

    private var header: some View {
        VStack(alignment: .leading, spacing: 8) {
            Text(current.displayTitle)
                .font(.title2.weight(.bold))
                .foregroundStyle(.white)
            HStack(spacing: 8) {
                Image(systemName: (current.kind ?? .unknown).symbol)
                Text((current.kind ?? .unknown).label)
                Text("·")
                Circle().fill(statusColor(current)).frame(width: 7, height: 7)
                Text(statusLabel(current))
            }
            .font(.subheadline.weight(.medium)).foregroundStyle(.secondary)
            if let model = current.model, !model.isEmpty {
                Text(model.components(separatedBy: "/").last ?? model)
                    .font(.caption).foregroundStyle(.secondary)
            }
            if let started = [current.startedAt, current.createdAt].compactMap({ $0 }).first(where: { !$0.isEmpty }) {
                Text("Started \(agentRelativeDate(started))")
                    .font(.caption).foregroundStyle(.secondary)
            }
            if current.isLive, let progress = current.progress, !progress.isEmpty {
                Text(progress).font(.subheadline).foregroundStyle(.white.opacity(0.8))
            }
        }
        .frame(maxWidth: .infinity, alignment: .leading)
        .padding(16)
        .jbGlass(20)
    }
}

private func statusLabel(_ agent: JBAgentRecord) -> String {
    if agent.cancelRequested == true && agent.isLive { return "Stopping" }
    switch agent.status ?? "" {
    case "done", "completed": return "Done"
    case "failed", "error": return "Failed"
    case "cancelled": return "Stopped"
    case "queued": return "Queued"
    case "running", "working": return "Running"
    default: return (agent.status ?? "Unknown").capitalized
    }
}

private func statusColor(_ agent: JBAgentRecord) -> Color {
    if agent.failed { return .red }
    if agent.isLive { return agent.status == "queued" ? .orange : .yellow }
    if agent.status == "cancelled" { return .gray }
    return .green
}

private func agentRelativeDate(_ value: String) -> String {
    let iso = ISO8601DateFormatter()
    iso.formatOptions = [.withInternetDateTime, .withFractionalSeconds]
    var date = iso.date(from: value)
    if date == nil {
        iso.formatOptions = [.withInternetDateTime]
        date = iso.date(from: value)
    }
    if date == nil {
        let fallback = DateFormatter()
        fallback.locale = Locale(identifier: "en_US_POSIX")
        fallback.timeZone = .current
        fallback.dateFormat = "yyyy-MM-dd HH:mm:ss"
        date = fallback.date(from: value.replacingOccurrences(of: "T", with: " "))
    }
    guard let date else { return String(value.prefix(16)).replacingOccurrences(of: "T", with: " ") }
    return date.formatted(.relative(presentation: .named))
}

private struct AgentCardPressStyle: ButtonStyle {
    let reduceMotion: Bool

    func makeBody(configuration: Configuration) -> some View {
        configuration.label
            .scaleEffect(configuration.isPressed && !reduceMotion ? 0.985 : 1)
            .opacity(configuration.isPressed ? 0.88 : 1)
            .animation(reduceMotion ? nil : .easeOut(duration: 0.16), value: configuration.isPressed)
    }
}
