import SwiftUI

/// Night Shift: queue coding tasks before bed, review the finished work in the morning.
struct NightShiftView: View {
    let ws: WorkspaceAPI
    @Environment(JoeBroTheme.self) private var theme
    @State private var tasks: [NSTask] = []
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
        List {
            Section {
                Toggle("Run overnight", isOn: Binding(get: { enabled }, set: { v in
                    enabled = v
                    Task { try? await ws.nightConfig(enabled: v) }
                })).tint(Color.accentTint)
            } footer: { Text("Queued tasks run in separate git worktrees. Nothing is pushed; you approve or reject each result.") }
            .listRowBackground(Color.joeInk.opacity(0.06))
            if !reviews.isEmpty {
                Section("Ready for review") {
                    ForEach(reviews) { task in
                        ReviewCard(ws: ws, task: task, open: { detail = task },
                                   approve: { Task { await decide(task, "approve") } },
                                   reject: { rejecting = task },
                                   followUp: { followUp = task; followUpText = "" })
                    }
                }
            }
            Section("Queue") {
                if queue.isEmpty && !loading {
                    empty("moon.stars", "Nothing queued", "Add a task and your agents work on it while you sleep.")
                }
                ForEach(queue) { task in
                    queueRow(task)
                        .swipeActions(edge: .trailing) {
                            Button("Cancel", systemImage: "xmark") { Task { await act { try await ws.nightCancel(task.id) } } }.tint(.red)
                        }
                        .swipeActions(edge: .leading) {
                            if task.state == "queued" {
                                Button("Run now", systemImage: "bolt.fill") { Task { await act { try await ws.nightRun(task.id) } } }.tint(Color.accentTint)
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
            }
            if !done.isEmpty {
                Section("Earlier") {
                    ForEach(done.prefix(8)) { task in
                        HStack {
                            Image(systemName: icon(task.state)).foregroundStyle(.secondary).frame(width: 24)
                            VStack(alignment: .leading, spacing: 2) {
                                Text(task.name).foregroundStyle(.joeInk).lineLimit(1)
                                Text("\(task.state.capitalized) · \(task.agentLabel)").font(.caption).foregroundStyle(.secondary)
                            }
                        }.listRowBackground(Color.joeInk.opacity(0.06))
                    }
                }
            }
        }
        .listStyle(.insetGrouped).scrollContentBackground(.hidden).jbWallpaper()
        .navigationTitle("Night Shift").navigationBarTitleDisplayMode(.inline)
        .refreshable { await load() }.task { await load() }
        .toolbar {
            ToolbarItem(placement: .topBarTrailing) { EditButton() }
            ToolbarItem(placement: .topBarTrailing) {
                Button { composing = true } label: { Image(systemName: "plus").foregroundStyle(Color.accentTint) }.accessibilityLabel("Queue a task")
            }
        }
        .sheet(isPresented: $composing) { NightComposer(ws: ws) { Task { await load() } }.environment(theme) }
        .sheet(item: $detail) { t in NightDiffView(ws: ws, task: t).environment(theme) }
        .alert("Ask a follow-up", isPresented: alertBinding($followUp)) {
            TextField("What should change?", text: $followUpText)
            Button("Send") { if let t = followUp { Task { await decide(t, "followup", followUpText) } }; followUp = nil }
            Button("Cancel", role: .cancel) { followUp = nil }
        } message: { Text("The agent continues on the same branch tonight.") }
        .alert("Reject this work?", isPresented: alertBinding($rejecting)) {
            Button("Reject", role: .destructive) { if let t = rejecting { Task { await decide(t, "reject") } }; rejecting = nil }
            Button("Keep reviewing", role: .cancel) { rejecting = nil }
        } message: { Text("The worktree and branch are removed. The commit stays in git until it is garbage collected.") }
        .alert("Night Shift", isPresented: alertBinding($error)) { Button("OK") { error = nil } } message: { Text(error ?? "") }
    }

    private func queueRow(_ task: NSTask) -> some View {
        HStack(spacing: 12) {
            if task.state == "running" { ProgressView().controlSize(.small) }
            else { Image(systemName: "moon.zzz").foregroundStyle(.secondary).frame(width: 20) }
            VStack(alignment: .leading, spacing: 3) {
                Text(task.name).foregroundStyle(.joeInk).lineLimit(2)
                Text([task.repoName, task.agentLabel, task.model].compactMap { $0 }.filter { !$0.isEmpty }.joined(separator: " · "))
                    .font(.caption).foregroundStyle(.secondary).lineLimit(1)
            }
            Spacer(minLength: 0)
            if task.state == "running" { Text("Running").font(.caption2).foregroundStyle(Color.accentTint) }
        }
        .frame(minHeight: 48).listRowBackground(Color.joeInk.opacity(0.06))
    }

    private func icon(_ s: String) -> String {
        switch s { case "approved": "checkmark.circle"; case "rejected": "xmark.circle"; case "failed": "exclamationmark.triangle"; default: "minus.circle" }
    }

    private func decide(_ t: NSTask, _ d: String, _ text: String? = nil) async {
        await act { try await ws.nightDecide(t.id, decision: d, text: text) }
    }
    private func load() async {
        loading = true; defer { loading = false }
        do { let r = try await ws.nightShift(); tasks = r.tasks; enabled = r.config?.enabled ?? true; error = nil }
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
    let open: () -> Void
    let approve: () -> Void
    let reject: () -> Void
    let followUp: () -> Void
    @State private var shot: UIImage?

    var body: some View {
        VStack(alignment: .leading, spacing: 10) {
            HStack(alignment: .firstTextBaseline) {
                Text(task.name).font(.headline).foregroundStyle(.joeInk)
                Spacer()
                if let t = task.result?.tests, let ok = t.passed {
                    Label(ok ? "Tests passed" : "Tests failed", systemImage: ok ? "checkmark.circle.fill" : "xmark.octagon.fill")
                        .font(.caption.weight(.semibold)).foregroundStyle(ok ? .green : .red)
                }
            }
            Text([task.repoName, task.agentLabel, task.model].compactMap { $0 }.filter { !$0.isEmpty }.joined(separator: " · "))
                .font(.caption).foregroundStyle(.secondary)
            if let d = task.result?.diff {
                HStack(spacing: 14) {
                    Text("\(d.files ?? 0) files").font(.subheadline)
                    Text("+\(d.insertions ?? 0)").foregroundStyle(.green).font(.subheadline.monospacedDigit())
                    Text("-\(d.deletions ?? 0)").foregroundStyle(.red).font(.subheadline.monospacedDigit())
                    if let m = task.result?.durationS { Text("\(Int(m / 60)) min").font(.caption).foregroundStyle(.secondary) }
                }
            }
            if let s = task.result?.summary, !s.isEmpty { Text(s).font(.subheadline).foregroundStyle(.joeInk.opacity(0.9)).lineLimit(5) }
            if let shot { Image(uiImage: shot).resizable().scaledToFit().clipShape(RoundedRectangle(cornerRadius: 10)) }
            HStack(spacing: 8) {
                Button("Approve", action: approve).buttonStyle(.borderedProminent).tint(Color.accentTint)
                Button("Reject", role: .destructive, action: reject).buttonStyle(.bordered)
                Button("Follow-up", action: followUp).buttonStyle(.bordered)
                Spacer(minLength: 0)
                Button { open() } label: { Image(systemName: "doc.text.magnifyingglass") }.accessibilityLabel("See the diff")
            }.font(.subheadline)
        }
        .padding(.vertical, 6)
        .listRowBackground(Color.joeInk.opacity(0.06))
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
                        HStack { Text(f.path).font(.footnote.monospaced()); Spacer()
                            Text("+\(f.added ?? 0)").foregroundStyle(.green); Text("-\(f.removed ?? 0)").foregroundStyle(.red) }.font(.caption)
                    }
                    if let out = task.result?.tests?.outputTail, !out.isEmpty {
                        Text(out).font(.caption.monospaced()).padding(8).background(.black.opacity(0.08), in: RoundedRectangle(cornerRadius: 8))
                    }
                    ForEach(task.result?.learned ?? [], id: \.self) { Label($0, systemImage: "brain").font(.footnote) }
                    Text(diff).font(.system(size: 11, design: .monospaced)).textSelection(.enabled)
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
    let saved: () -> Void
    @Environment(\.dismiss) private var dismiss
    @State private var repo = ""
    @State private var prompt = ""
    @State private var title = ""
    @State private var agent = "claude"
    @State private var model = ""
    @State private var tests = ""
    @State private var error: String?

    private static let models = ["claude": ["opus", "sonnet", "haiku"], "codex": ["gpt-5-codex", "gpt-5"],
                                 "opencode": ["qwen3-coder:30b", "llama3.3:70b", "deepseek-v3.2"], "any": []]
    var body: some View {
        NavigationStack {
            Form {
                Section("Task") {
                    TextField("What should the agent do?", text: $prompt, axis: .vertical).lineLimit(3...8)
                    TextField("Title (optional)", text: $title)
                    TextField("Repository path on your computer", text: $repo).textInputAutocapitalization(.never).autocorrectionDisabled()
                }
                Section("Agent") {
                    Picker("Agent", selection: $agent) {
                        Text("Claude Code").tag("claude"); Text("Codex").tag("codex"); Text("OpenCode").tag("opencode"); Text("Any").tag("any")
                    }
                    Picker("Model", selection: $model) {
                        Text("Default").tag("")
                        ForEach(Self.models[agent] ?? [], id: \.self) { Text($0).tag($0) }
                    }
                    TextField("Test command (optional)", text: $tests).textInputAutocapitalization(.never).autocorrectionDisabled()
                }
                if let error { Text(error).foregroundStyle(.red).font(.footnote) }
            }
            .navigationTitle("Queue a task").navigationBarTitleDisplayMode(.inline)
            .onChange(of: agent) { _, _ in model = "" }
            .toolbar {
                ToolbarItem(placement: .cancellationAction) { Button("Cancel") { dismiss() } }
                ToolbarItem(placement: .confirmationAction) {
                    Button("Queue") { Task { await save() } }.disabled(prompt.trimmingCharacters(in: .whitespaces).isEmpty)
                }
            }
        }
    }
    private func save() async {
        var body: [String: Any] = ["prompt": prompt, "agent": agent]
        if !repo.isEmpty { body["repo"] = repo }
        if !title.isEmpty { body["title"] = title }
        if !model.isEmpty { body["model"] = model }
        if !tests.isEmpty { body["test_command"] = tests }
        do { try await ws.nightAdd(body); saved(); dismiss() } catch { self.error = error.localizedDescription }
    }
}
