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
    private var loadTask: Task<Void, Never>?
    var error: String?
    private var poll: Task<Void, Never>?

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
            // The main JoeBro has its own card (mainJoeBro); its turns' registry
            // rows would otherwise count it twice.
            if agent.sessionID == Flavor.mainSessionID && mainJoeBro.busy { return false }
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
        let ordered = list.filter(\.isLive) + list.filter { !$0.isLive }
        // Subagents sit directly under the agent that spawned them.
        let ids = Set(ordered.map(\.id))
        let children = Dictionary(grouping: ordered.filter { $0.kind == .subagent && ids.contains($0.parentID ?? "") },
                                  by: { $0.parentID ?? "" })
        let nested = Set(children.values.flatMap { $0 }.map(\.id))
        return ordered.filter { !nested.contains($0.id) }.flatMap { [$0] + (children[$0.id] ?? []) }
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
        case .subagent, .coding, .briefing, .unknown: 3
        }
    }

    func load() async {
        if let loadTask { await loadTask.value; return }
        loading = !hasLoaded
        let task = Task { @MainActor in
            defer { loading = false; loadTask = nil }
            async let sessionRequest = loadSessions()
            do {
                let result = try await api.agentRegistry()
                try Task.checkCancellation()
                agents = result
                loading = false
                hasLoaded = true
                error = nil
                // RootView owns Live Activity updates. Refresh must finish as
                // soon as its data requests finish, independently of WidgetKit.
            } catch {
                if !Task.isCancelled { self.error = error.localizedDescription }
            }
            await sessionRequest
        }
        loadTask = task
        await task.value
    }

    /// A user pull supersedes a poll instead of silently returning or waiting
    /// for a stale request to finish. Keep the last good rows during refresh.
    func refresh() async {
        if let task = loadTask {
            task.cancel()
            await task.value
        }
        guard !Task.isCancelled else { return }
        await load()
    }

    private func loadSessions() async {
        do {
            let result = try await api.sessions()
            try Task.checkCancellation()
            sessions = result
            sessionsLoaded = true
        } catch { /* Registry results remain useful when session lookup fails. */ }
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

    func stopPolling() { poll?.cancel(); poll = nil; loadTask?.cancel() }

    func cancel(_ agent: JBAgentRecord) async {
        do {
            if let session = agent.sessionID, chatStore.workingSessions.contains(session) {
                try await api.stopChatAgentSession(id: session)
            } else {
                try await api.cancelAgent(id: agent.id)
            }
            await refresh()
        }
        catch { self.error = error.localizedDescription }
    }
}

/// JoeBro's research runs, working chats, and background tasks.
private extension JBAgentKind {
    @ViewBuilder func glyph(_ size: CGFloat = 15) -> some View {
        switch self {
        case .coding: JBIcon(.coding, size: size)
        case .research: JBIcon(.research, size: size)
        case .task: JBIcon(.tasks, size: size)
        case .chat, .unknown, .briefing: JBIcon(.agent, size: size)
        case .subagent: Image(systemName: "arrow.triangle.branch").font(.jb(size - 2))
        }
    }
}

struct AgentsTabView: View {
    let api: JoeBroAPI
    let chatStore: ChatStore
    let mainJoeBro: ChatStore
    @State private var store: AgentsStore
    @State private var open: JBAgentRecord?
    @State private var stopTarget: JBAgentRecord?
    @State private var showNewAgent = false
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
        ScrollViewReader { proxy in
        List {
            Group {
                filters
                content
                if DemoMode.option("-JoeBroAgentsEnd") != nil { Color.clear.frame(height: 1).id("agents-end") }
            }
            .listRowInsets(EdgeInsets(top: 5, leading: 16, bottom: 5, trailing: 16))
            .listRowSeparator(.hidden)
            .listRowBackground(Color.clear)
        }
        .listStyle(.plain)
        .environment(\.defaultMinListRowHeight, 0)
        .scrollContentBackground(.hidden)
        .scrollBounceBehavior(.always, axes: .vertical)
        .scrollIndicators(.hidden)
        .refreshable { await store.refresh() }
        .jbWallpaper()
        .searchable(text: Bindable(store).search, prompt: "Search agents")
        .task(id: store.loading) {
            // Demo/screenshots: `-JoeBroAgentsEnd 1` scrolls to the end of the list.
            guard DemoMode.option("-JoeBroAgentsEnd") != nil, !store.loading else { return }
            try? await Task.sleep(for: .milliseconds(800))
            proxy.scrollTo("agents-end", anchor: .bottom)
        }
        }
    }

    var body: some View {
        NavigationStack {
            scroller
            .navigationTitle("Agents")
            .navigationBarTitleDisplayMode(.inline)
            .sheet(isPresented: $showNewAgent) {
                NewCodingAgentSheet(api: api) { Task { await store.refresh() } }
            }
            .toolbar {
                ToolbarItem(placement: .topBarLeading) {
                    Button { showNewAgent = true } label: {
                        Image(systemName: "plus").font(.jb(18, .regular)).foregroundStyle(JB.ink)
                            .frame(width: 44, height: 44)
                    }
                    .accessibilityLabel("New coding agent")
                }
                ToolbarItem(placement: .topBarTrailing) {
                    Button { onOpenSettings() } label: {
                        JBSettingsGlyph()
                    }
                        .accessibilityLabel("Settings")
                }
            }
            .navigationDestination(item: $open) { agent in
                AgentDetailView(api: api, agent: agent, chatStore: chatStore)
            }
            .task {
                store.startPolling()
                if mainJoeBro.selectedSessionID == nil { await mainJoeBro.load() }
            }
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
            HStack { Spacer(); JBSpinner(size: 14); Spacer() }.frame(minHeight: 180)
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
            HStack(spacing: 12) {
                JBIcon(.agent, size: 22).foregroundStyle(JB.accent)
                    .frame(width: 40, height: 40)
                    .background(JB.accentSoft, in: RoundedRectangle(cornerRadius: JB.rControl, style: .continuous))
                VStack(alignment: .leading, spacing: 4) {
                    Text(Flavor.mainAgentName).font(.jbHeadline).foregroundStyle(JB.ink)
                    HStack(spacing: 6) {
                        JBStatusDot(color: mainJoeBro.busy ? JB.live : (mainJoeBro.mainConnectionIssue == nil ? JB.ink3 : JB.danger),
                                    live: mainJoeBro.busy, size: 6)
                        Text(mainJoeBro.busy ? "working" : mainJoeBro.mainConnectionIssue == nil ? "idle" : "offline")
                            .font(.jb(11)).foregroundStyle(JB.ink2)
                    }
                }
                Spacer(minLength: 4)
                Image(systemName: "chevron.right").font(.jb(11)).foregroundStyle(JB.ink3)
            }
            .padding(14)
            .frame(maxWidth: .infinity, alignment: .leading)
            .jbSurface(.raised, radius: JB.rCard)
            .contentShape(Rectangle())
        }
        .buttonStyle(JBPressStyle())
        .accessibilityLabel("JoeBro, \(mainJoeBro.busy ? "working now" : mainJoeBro.mainConnectionIssue == nil ? "standing by" : "offline")")
        .accessibilityHint("Opens JoeBro's conversation")
    }

    private var sectionHeader: some View {
        HStack {
            Text(store.activeOnly ? "Running" : "Recent").jbEyebrow()
            Spacer()
            JBDotNumber(value: "\(store.visible.count + (showJoeBroCard ? 1 : 0))", dot: 1.6, tint: JB.ink2)
        }
        .padding(.horizontal, 2)
        .padding(.top, 4)
    }

    private func agentRow(_ agent: JBAgentRecord) -> some View {
        VStack(alignment: .leading, spacing: 10) {
            agentRowButton(agent)
            if agent.kind == .coding, agent.status == "waiting" {
                AgentApprovalButtons(api: api, agentID: agent.id) { await store.refresh() }
            }
        }
        .padding(14)
        .frame(maxWidth: .infinity, alignment: .leading)
        .jbSurface(.raised, radius: JB.rCard)
        .overlay(RoundedRectangle(cornerRadius: JB.rCard, style: .continuous)
            .strokeBorder(JB.warn.opacity(agent.status == "waiting" ? 0.5 : 0), lineWidth: 1))
        .padding(.leading, agent.kind == .subagent && agent.parentID != nil ? 22 : 0)
    }

    @ViewBuilder private func agentRowButton(_ agent: JBAgentRecord) -> some View {
        if agent.isLive && agent.cancelRequested != true {
            Button { open = agent } label: { row(agent) }
                .buttonStyle(JBPressStyle())
                .contextMenu {
                    Button("Ask to stop", systemImage: "stop", role: .destructive) { stopTarget = agent }
                }
        } else {
            Button { open = agent } label: { row(agent) }
                .buttonStyle(JBPressStyle())
        }
    }

    private var filters: some View {
        VStack(alignment: .leading, spacing: 12) {
            HStack(spacing: 6) {
                scopeChip("Active", count: store.liveCount, on: store.activeOnly) { store.activeOnly = true }
                scopeChip("All", count: store.allCount, on: !store.activeOnly) { store.activeOnly = false }
                Spacer()
                if store.filter != nil {
                    Button("Clear") { withAnimation(reduceMotion ? nil : JB.snap) { store.filter = nil } }
                        .font(.jb(11, .medium)).foregroundStyle(JB.ink2)
                }
            }
            ScrollView(.horizontal, showsIndicators: false) {
                HStack(spacing: 8) {
                    ForEach([JBAgentKind.chat, .coding, .research, .task, .subagent], id: \.self) { kind in
                        kindChip(kind)
                    }
                }
            }
        }
        .padding(.bottom, 4)
    }

    private func scopeChip(_ label: String, count: Int, on: Bool, action: @escaping () -> Void) -> some View {
        Button(action: action) {
            HStack(spacing: 6) {
                Text(label).font(.jb(12, .medium))
                Text("\(count)").font(.jb(12)).foregroundStyle(on ? JB.accent : JB.ink3).contentTransition(.numericText())
            }
            .foregroundStyle(on ? JB.ink : JB.ink2)
            .padding(.horizontal, 11).padding(.vertical, 7)
            .background(RoundedRectangle(cornerRadius: JB.rControl, style: .continuous).fill(on ? JB.accentSoft : .clear))
        }
        .buttonStyle(.plain)
        .sensoryFeedback(.selection, trigger: on)
    }

    private func kindChip(_ kind: JBAgentKind) -> some View {
        let selected = store.filter == kind
        return Button {
            withAnimation(reduceMotion ? nil : JB.snap) { store.filter = selected ? nil : kind }
        } label: {
            HStack(spacing: 7) {
                kind.glyph(14)
                Text(kind.label).font(.jb(12, .medium))
                Text("\(store.count(for: kind))").font(.jb(12)).foregroundStyle(JB.ink3)
                    .contentTransition(.numericText())
            }
            .foregroundStyle(selected ? JB.ink : JB.ink2)
            .padding(.horizontal, 11).frame(height: 34)
            .jbSurface(selected ? .raised : .panel, radius: JB.rControl)
            .overlay(RoundedRectangle(cornerRadius: JB.rControl, style: .continuous)
                .strokeBorder(selected ? JB.accent.opacity(0.6) : .clear, lineWidth: 1))
        }
        .buttonStyle(.plain)
        .accessibilityLabel("\(kind.label), \(store.count(for: kind)) \(store.activeOnly ? "active" : "total")")
    }

    private func row(_ agent: JBAgentRecord) -> some View {
        VStack(alignment: .leading, spacing: 8) {
            HStack(alignment: .top, spacing: 12) {
                (agent.kind ?? .unknown).glyph(18)
                    .foregroundStyle(JB.ink)
                    .frame(width: 36, height: 36)
                    .background(JB.accentSoft.opacity(agent.isLive ? 1 : 0.5), in: RoundedRectangle(cornerRadius: JB.rControl, style: .continuous))
                VStack(alignment: .leading, spacing: 4) {
                    Text(agent.displayTitle)
                        .font(.jb(15, .semibold)).foregroundStyle(JB.ink)
                        .lineLimit(2).multilineTextAlignment(.leading)
                    if agent.kind == .subagent, agent.parentID != nil {
                        Text("from \(store.parentName(of: agent) ?? "agent")")
                            .font(.jb(11)).foregroundStyle(JB.ink3).lineLimit(1)
                    }
                    HStack(spacing: 7) {
                        JBStatusDot(color: statusColor(agent), live: agent.isLive && agent.status != "waiting" && agent.status != "queued", size: 6)
                        Text(statusLabel(agent).prefix(1).uppercased() + statusLabel(agent).dropFirst())
                        if agent.kind == .research, let count = agent.sourceCount, count > 0 { Text("· \(count) sources") }
                    }
                    .font(.jb(13, agent.isLive ? .medium : .regular))
                    .foregroundStyle(agent.status == "waiting" ? JB.warn : agent.isLive ? JB.live : JB.ink3)
                }
                Spacer(minLength: 5)
                Image(systemName: "chevron.right").font(.jb(11)).foregroundStyle(JB.ink3)
            }
            if let preview = agent.isLive ? agent.progress : (agent.failed ? agent.error : agent.result),
               !preview.trimmingCharacters(in: .whitespacesAndNewlines).isEmpty {
                Text(preview.trimmingCharacters(in: .whitespacesAndNewlines))
                    .font(.jbCaption).foregroundStyle(JB.ink2)
                    .lineLimit(2).multilineTextAlignment(.leading)
            }
            if let date = [agent.finishedAt, agent.startedAt, agent.createdAt].compactMap({ $0 }).first(where: { !$0.isEmpty }) {
                Text(agentRelativeDate(date)).font(.jb(12)).foregroundStyle(JB.ink3)
            }
        }
        .frame(maxWidth: .infinity, alignment: .leading)
        // Live agents carry a phosphor edge so running vs finished reads at a glance.
        .overlay(alignment: .leading) {
            if agent.isLive {
                Capsule().fill(agent.status == "waiting" ? JB.warn : JB.live).frame(width: 3).padding(.vertical, 2).offset(x: -10)
            }
        }
        .contentShape(Rectangle())
    }

    private var emptyState: some View {
        VStack(spacing: 10) {
            JBEmptyState(art: store.search.isEmpty ? (store.activeOnly ? .sleep : .inbox) : .search,
                         text: store.search.isEmpty ? (store.activeOnly ? "Quiet right now" : "No agents yet") : "No matches")
            if store.filter != nil {
                Button("Show all kinds") { store.filter = nil }.buttonStyle(.jbSecondary)
            }
        }
        .frame(maxWidth: .infinity).padding(.vertical, 24)
    }
}

/// One agent's full result, plus a way into the chat transcript behind it.
/// Coding agents open as a chat: transcript, approvals and a composer.
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
        Group {
            if current.kind == .coding {
                AgentChatThread(api: api, agent: current, header: AnyView(header)) { await reloadDetail() }
            } else {
                reportBody
            }
        }
        .navigationTitle(current.displayTitle)
        .navigationBarTitleDisplayMode(.inline)
        .jbWallpaper()
        .toolbar {
            if current.isLive {
                ToolbarItem(placement: .topBarTrailing) {
                    Button("Stop", systemImage: "stop", role: .destructive) { confirmStop = true }
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
            // Keep a running detail open until its final result is available; coding agents stay
            // open (they take new instructions any time) at a faster pace.
            while !Task.isCancelled {
                do { full = try await api.agentDetail(id: agent.id); error = nil }
                catch { self.error = error.localizedDescription }
                loading = false
                guard current.isLive || (current.kind == .coding && current.status != "ended") else { break }
                try? await Task.sleep(for: .seconds(current.kind == .coding ? 2.5 : 5))
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
                        cancelNote = "Stop requested"
                        if !agent.isSessionOnly { full = try await api.agentDetail(id: agent.id) }
                    } catch { self.error = error.localizedDescription }
                }
            }
        } message: {
            Text("The backend will request cancellation. The run may take a moment to finish.")
        }
    }

    private func reloadDetail() async {
        if let d = try? await api.agentDetail(id: agent.id) { full = d }
    }

    private var reportBody: some View {
        ScrollView {
            VStack(alignment: .leading, spacing: 16) {
                header
                if loading && full == nil {
                    HStack { Spacer(); JBSpinner(size: 14); Spacer() }.padding(.vertical, 30)
                }
                if let error = current.error, !error.isEmpty {
                    Text(error).font(.jb(12)).foregroundStyle(JB.danger)
                        .frame(maxWidth: .infinity, alignment: .leading).jbCard()
                }
                if let cancelNote {
                    Text(cancelNote).font(.jb(11)).foregroundStyle(JB.ink2)
                        .frame(maxWidth: .infinity, alignment: .leading)
                }
                if let result = displayedReport, !result.isEmpty {
                    MarkdownText(text: result)
                        .textSelection(.enabled)
                        .frame(maxWidth: .infinity, alignment: .leading)
                        .jbCard(padding: 16)
                } else if !loading && !current.isLive {
                    Text(current.isSessionOnly ? "No replies in this chat yet" : "No result")
                        .font(.jb(11)).foregroundStyle(JB.ink3)
                } else if current.isLive {
                    HStack(spacing: 6) { JBSpinner(); JBStreamCursor() }
                }
                if let sources = current.sources, !sources.isEmpty {
                    ResearchSourcesView(sources: sources)
                }
                if !displayedMessages.isEmpty {
                    VStack(alignment: .leading, spacing: 12) {
                        Text("Transcript").jbEyebrow()
                        ForEach(Array(displayedMessages.enumerated()), id: \.offset) { _, message in
                            if message.role == "user" {
                                Text(message.content).font(.jbBody).foregroundStyle(JB.ink)
                                    .textSelection(.enabled).jbCard(padding: 12)
                            } else {
                                Text(message.content).font(.jbBody).foregroundStyle(JB.ink)
                                    .textSelection(.enabled)
                                    .frame(maxWidth: .infinity, alignment: .leading)
                            }
                        }
                    }
                }
            }
            .padding(16)
        }
        .scrollIndicators(.hidden)
    }

    private var header: some View {
        VStack(alignment: .leading, spacing: 8) {
            HStack(spacing: 8) {
                (current.kind ?? .unknown).glyph(15)
                Text((current.kind ?? .unknown).label).font(.jb(11, .medium))
                JBStatusDot(color: statusColor(current), live: current.isLive && current.status != "waiting" && current.status != "queued", size: 6)
                Text(statusLabel(current).lowercased()).font(.jb(11))
            }
            .foregroundStyle(current.status == "waiting" ? JB.warn : JB.ink2)
            if let model = current.model, !model.isEmpty {
                Text(model.components(separatedBy: "/").last ?? model).font(.jb(11)).foregroundStyle(JB.ink3)
            }
            if let started = [current.startedAt, current.createdAt].compactMap({ $0 }).first(where: { !$0.isEmpty }) {
                Text(agentRelativeDate(started)).font(.jb(11)).foregroundStyle(JB.ink3)
            }
            if current.isLive, let progress = current.progress, !progress.isEmpty, current.kind != .coding {
                Text(progress).font(.jbSubheadline).foregroundStyle(JB.ink2)
            }
        }
        .frame(maxWidth: .infinity, alignment: .leading)
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
    case "waiting": return "Needs you"
    case "stale": return "Went quiet"
    default: return (agent.status ?? "Unknown").capitalized
    }
}

private func statusColor(_ agent: JBAgentRecord) -> Color {
    if agent.failed { return JB.danger }
    if agent.isLive { return agent.status == "queued" ? JB.ink3 : agent.status == "waiting" ? JB.warn : JB.live }
    return JB.ink3
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
