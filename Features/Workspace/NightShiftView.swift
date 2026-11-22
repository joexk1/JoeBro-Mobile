import SwiftUI

/// Night Shift: queue coding tasks before bed, review the finished work in the morning.
struct NightShiftView: View {
    let ws: WorkspaceAPI
    @Environment(JoeBroTheme.self) private var theme
    @State private var tasks: [NSTask] = []
    @State private var hosts: [NSHost] = []
    @State private var enabled = true
    @State private var composing = false
    @State private var detail: NSTask?
    @State private var followUp: NSTask?
    @State private var followUpText = ""
    @State private var rejecting: NSTask?
    @State private var loading = false
    @State private var error: String?

    #if DEBUG
    /// Demo-only: `-JoeBroQueueOnly` hides review cards so the queue fills the screenshot.
    private var reviews: [NSTask] { DemoMode.option("-JoeBroQueueOnly") != nil ? [] : tasks.filter(\.needsReview) }
    #else
    private var reviews: [NSTask] { tasks.filter(\.needsReview) }
    #endif
    private var queue: [NSTask] { tasks.filter(\.isOpen) }
    private var done: [NSTask] { tasks.filter { !$0.isOpen && !$0.needsReview } }

    var body: some View {
        ScrollViewReader { proxy in
        List {
            HStack {
                JBIcon(.nightShift, size: 15).foregroundStyle(JB.accent)
                Text("Overnight").font(.jb(14)).foregroundStyle(JB.ink)
                Spacer()
                Toggle("", isOn: Binding(get: { enabled }, set: { v in
                    enabled = v
                    Task { try? await ws.nightConfig(enabled: v) }
                })).labelsHidden().toggleStyle(JBSwitchStyle())
            }.jbListRow()
            if !reviews.isEmpty {
                Section {
                    ForEach(reviews) { task in
                        ReviewCard(ws: ws, task: task, hostName: hostName(task), open: { detail = task },
                                   approve: { Task { await decide(task, "approve") } },
                                   reject: { rejecting = task },
                                   followUp: { followUp = task; followUpText = "" })
                        .jbListRow()
                    }
                } header: { JBListHeader(title: "Review", count: reviews.count) }
            }
            Section {
                if queue.isEmpty && !loading { JBEmptyRow(art: .sleep, text: "Nothing queued") }
                ForEach(queue) { task in
                    queueRow(task).jbListRow()
                        .swipeActions(edge: .trailing) {
                            Button("Cancel", systemImage: "xmark") { Task { await act { try await ws.nightCancel(task.id) } } }.tint(JB.danger)
                        }
                        .swipeActions(edge: .leading) {
                            if task.state == "queued" {
                                Button("Run now", systemImage: "play") { Task { await act { try await ws.nightRun(task.id) } } }.tint(JB.accent)
                            }
                        }
                }
                .onMove { from, to in
                    var ids = queue.filter { $0.state == "queued" }.map(\.id)
                    let running = queue.filter { $0.state == "running" }.count
                    let f = IndexSet(from.map { max($0 - running, 0) }), t = max(to - running, 0)
                    ids.move(fromOffsets: f, toOffset: t)
                    Task { await act { try await ws.nightReorder(ids) } }
                }
            } header: { JBListHeader(title: "Queue", count: queue.count) }
            if !done.isEmpty {
                Section {
                    ForEach(done.prefix(8)) { task in
                        HStack(spacing: 10) {
                            JBStatusDot(color: dotColor(task.state), size: 6)
                            Text(task.name).font(.jb(14)).foregroundStyle(JB.ink2).lineLimit(1)
                            Spacer(minLength: 0)
                            Text(task.state).font(.jb(11)).foregroundStyle(JB.ink3)
                        }.jbListRow()
                    }
                } header: { JBListHeader(title: "Earlier") }
            }
        }
        .animation(JB.smooth, value: tasks.map(\.id))
        .jbPlainList()
        .navigationTitle("Night Shift").navigationBarTitleDisplayMode(.inline)
        .refreshable { await load() }.task { await load() }
        .task(id: tasks.count) {
            // Demo/screenshots: `-JoeBroNightScroll N` ends the view on the Nth review card.
            guard let n = DemoMode.option("-JoeBroNightScroll").flatMap(Int.init), reviews.indices.contains(n - 1) else { return }
            try? await Task.sleep(for: .milliseconds(800))
            proxy.scrollTo(reviews[n - 1].id, anchor: .bottom)
        }
        .toolbar {
            ToolbarItem(placement: .topBarTrailing) { EditButton() }
            ToolbarItem(placement: .topBarTrailing) { JBPlusButton(label: "Queue a task") { composing = true } }
        }
        .sheet(isPresented: $composing) { NightComposer(ws: ws, hosts: hosts) { Task { await load() } }.environment(theme) }
        .sheet(item: $detail) { t in NightDiffView(ws: ws, task: t).environment(theme) }
        .alert("Follow-up", isPresented: alertBinding($followUp)) {
            TextField("What should change?", text: $followUpText)
            Button("Send") { if let t = followUp { Task { await decide(t, "followup", followUpText) } }; followUp = nil }
            Button("Cancel", role: .cancel) { followUp = nil }
        }
        .alert("Reject this work?", isPresented: alertBinding($rejecting)) {
            Button("Reject", role: .destructive) { if let t = rejecting { Task { await decide(t, "reject") } }; rejecting = nil }
            Button("Keep reviewing", role: .cancel) { rejecting = nil }
        } message: { Text("The worktree and branch are removed.") }
        .alert("Night Shift", isPresented: alertBinding($error)) { Button("OK") { error = nil } } message: { Text(error ?? "") }
        }
    }

    private func hostName(_ t: NSTask) -> String? {
        guard hosts.count > 1, let h = t.host, !h.isEmpty else { return nil }
        return hosts.first { $0.id == h }?.label ?? h
    }

    private func queueRow(_ task: NSTask) -> some View {
        HStack(spacing: 12) {
            if task.state == "running" { JBStatusDot(live: true) } else { JBIcon(.nightShift, size: 14).foregroundStyle(JB.ink3).frame(width: 7) }
            VStack(alignment: .leading, spacing: 3) {
                Text(task.name).font(.jb(15)).foregroundStyle(JB.ink).lineLimit(2)
                Text([task.repoName, task.agentLabel, task.model, hostName(task)].compactMap { $0 }.filter { !$0.isEmpty }.joined(separator: " · "))
                    .font(.jb(11)).foregroundStyle(JB.ink3).lineLimit(1)
            }
            Spacer(minLength: 0)
        }
    }

    private func dotColor(_ s: String) -> Color {
        switch s { case "approved": JB.live; case "failed": JB.danger; default: JB.ink3 }
    }

    private func decide(_ t: NSTask, _ d: String, _ text: String? = nil) async {
        await act { try await ws.nightDecide(t.id, decision: d, text: text) }
    }
    private func load() async {
        loading = true; defer { loading = false }
        do { let r = try await ws.nightShift(); tasks = r.tasks; hosts = r.hosts; enabled = r.config?.enabled ?? true; error = nil }
        catch where error.isNotFound { tasks = []; self.error = nil }      // nothing there yet: show the empty state
        catch { self.error = error.localizedDescription }
    }
    private func act(_ work: () async throws -> Void) async {
        do { try await work(); await load() } catch { self.error = error.localizedDescription }
    }
}

/// The morning card: what changed, whether tests passed, the agent's summary, one tap to decide.
struct ReviewCard: View {
    let ws: WorkspaceAPI
    let task: NSTask
    var hostName: String? = nil
    let open: () -> Void
    let approve: () -> Void
    let reject: () -> Void
    let followUp: () -> Void
    @State private var shot: UIImage?

    var body: some View {
        VStack(alignment: .leading, spacing: 10) {
            HStack(alignment: .firstTextBaseline, spacing: 8) {
                JBStatusDot(color: task.state == "failed" ? JB.warn : JB.accent, size: 7)
                Text(task.name).font(.jb(16, .semibold)).foregroundStyle(JB.ink)
                Spacer()
                if let ok = task.result?.tests?.passed { JBChip(text: ok ? "tests ok" : "tests failed", tint: ok ? JB.live : JB.danger) }
            }
            Text([task.repoName, task.agentLabel, task.model, hostName].compactMap { $0 }.filter { !$0.isEmpty }.joined(separator: " · "))
                .font(.jb(11)).foregroundStyle(JB.ink3)
            if let d = task.result?.diff {
                HStack(spacing: 14) {
                    Text("\(d.files ?? 0) files").foregroundStyle(JB.ink2)
                    Text("+\(d.insertions ?? 0)").foregroundStyle(JB.live)
                    Text("-\(d.deletions ?? 0)").foregroundStyle(JB.danger)
                    if let m = task.result?.durationS { Text("\(max(1, Int(m / 60)))m").foregroundStyle(JB.ink3) }
                }.font(.jb(12))
            }
            if let s = task.result?.summary ?? task.error, !s.isEmpty { Text(s).font(.jb(14)).foregroundStyle(JB.ink2).lineLimit(5) }
            if let shot { Image(uiImage: shot).resizable().scaledToFit().clipShape(RoundedRectangle(cornerRadius: JB.rControl)) }
            HStack(spacing: 8) {
                if task.state == "review" { Button("Approve", action: approve).buttonStyle(JBButtonStyle(kind: .primary, compact: true)) }
                Button("Follow-up", action: followUp).buttonStyle(JBButtonStyle(kind: .secondary, compact: true))
                Button("Reject", action: reject).buttonStyle(JBButtonStyle(kind: .danger, compact: true))
                Spacer(minLength: 0)
                Button { open() } label: { Image(systemName: "doc.text.magnifyingglass") }
                    .buttonStyle(JBIconButtonStyle(size: 32)).accessibilityLabel("See the diff")
            }
        }
        .padding(.vertical, 2)
        .task { if task.result?.screenshot == true, let d = try? await ws.nightScreenshot(task.id) { shot = UIImage(data: d) } }
    }
}

struct NightDiffView: View {
    let ws: WorkspaceAPI
    let task: NSTask
    @State private var diff = ""
    @Environment(\.dismiss) private var dismiss
    var body: some View {
        NavigationStack {
            ScrollView {
                VStack(alignment: .leading, spacing: 12) {
                    ForEach(task.result?.diff?.fileList ?? [], id: \.path) { f in
                        HStack { Text(f.path).font(.jb(12)).foregroundStyle(JB.ink2); Spacer()
                            Text("+\(f.added ?? 0)").foregroundStyle(JB.live); Text("-\(f.removed ?? 0)").foregroundStyle(JB.danger) }.font(.jb(11))
                    }
                    if let out = task.result?.tests?.outputTail, !out.isEmpty {
                        Text(out).font(.jb(11)).foregroundStyle(JB.ink2).padding(8).background(JB.raised, in: RoundedRectangle(cornerRadius: JB.rControl))
                    }
                    ForEach(task.result?.learned ?? [], id: \.self) { l in
                        HStack(alignment: .top, spacing: 6) { JBIcon(.memory, size: 13).foregroundStyle(JB.accent); Text(l).font(.jb(13)).foregroundStyle(JB.ink2) }
                    }
                    Text(diff).font(.jb(11)).foregroundStyle(JB.ink).textSelection(.enabled)
                }.padding(16).frame(maxWidth: .infinity, alignment: .leading)
            }
            .jbWallpaper().navigationTitle(task.name).navigationBarTitleDisplayMode(.inline)
            .toolbar { ToolbarItem(placement: .topBarTrailing) { Button("Done") { dismiss() } } }
            .task { diff = (try? await ws.nightDiff(task.id)) ?? "" }
        }
    }
}

struct NightComposer: View {
    let ws: WorkspaceAPI
    var hosts: [NSHost] = []
    let saved: () -> Void
    @Environment(\.dismiss) private var dismiss
    @State private var repo = ""
    @State private var prompt = ""
    @State private var title = ""
    @State private var agent = "claude"
    @State private var model = ""
    @State private var host = ""
    @State private var tests = ""
    @State private var error: String?

    private static let models = ["claude": ["opus", "sonnet", "haiku"], "codex": ["gpt-5-codex", "gpt-5"],
                                 "opencode": ["qwen3-coder:30b", "llama3.3:70b", "deepseek-v3.2"], "any": []]
    var body: some View {
        NavigationStack {
            Form {
                Section {
                    TextField("What should the agent do?", text: $prompt, axis: .vertical).lineLimit(3...8)
                    TextField("Title", text: $title)
                    TextField("Folder", text: $repo).font(.jb(14)).textInputAutocapitalization(.never).autocorrectionDisabled()
                }.jbFormRow()
                Section {
                    Picker("Agent", selection: $agent) {
                        Text("Claude Code").tag("claude"); Text("Codex").tag("codex"); Text("OpenCode").tag("opencode"); Text("Any").tag("any")
                    }
                    Picker("Model", selection: $model) {
                        Text("Default").tag("")
                        ForEach(Self.models[agent] ?? [], id: \.self) { Text($0).tag($0) }
                    }
                    if hosts.count > 1 {
                        Picker("Runs on", selection: $host) {
                            ForEach(hosts) { h in Text(h.up == false ? h.label + " (offline)" : h.label).tag(h.id) }
                        }
                    }
                    TextField("Test command", text: $tests).font(.jb(14)).textInputAutocapitalization(.never).autocorrectionDisabled()
                }.jbFormRow()
                if let error { Text(error).foregroundStyle(JB.danger).font(.jb(12)).jbFormRow() }
            }
            .scrollContentBackground(.hidden).jbWallpaper()
            .navigationTitle("Queue a task").navigationBarTitleDisplayMode(.inline)
            .onChange(of: agent) { _, _ in model = "" }
            .onAppear { if host.isEmpty, let l = hosts.first(where: { $0.local == true }) { host = l.id } }
            .toolbar {
                ToolbarItem(placement: .cancellationAction) { Button("Cancel") { dismiss() } }
                ToolbarItem(placement: .confirmationAction) {
                    Button("Queue") { Task { await save() } }.disabled(prompt.trimmingCharacters(in: .whitespaces).isEmpty || repo.isEmpty)
                }
            }
        }
    }
    private func save() async {
        var body: [String: Any] = ["prompt": prompt, "agent": agent, "repo": repo]
        if !title.isEmpty { body["title"] = title }
        if !model.isEmpty { body["model"] = model }
        if !host.isEmpty { body["host"] = host }
        if !tests.isEmpty { body["test_command"] = tests }
        do { try await ws.nightAdd(body); saved(); dismiss() } catch { self.error = error.localizedDescription }
    }
}
