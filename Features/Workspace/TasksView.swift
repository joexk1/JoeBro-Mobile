import SwiftUI

/// Scheduled prompts: create, edit, delete, pause/resume, run now and set the
/// agent's access level — the same set the Mac's right-click menu offers.
struct TasksView: View {
    let ws: WorkspaceAPI
    @Environment(JoeBroTheme.self) private var theme

    @State private var tasks: [WSTask] = []
    @State private var personalTasks: [WSTask] = []
    @State private var hosts: [NSHost] = []
    @State private var editing: WSTask?
    @State private var creating = false
    @State private var creatingPersonal = false
    @State private var deleteTarget: WSTask?
    @State private var running: String?
    @State private var runResult: RunResult?
    @State private var loading = false
    @State private var error: String?

    /// Wrapped so it can drive `.sheet(item:)`.
    private struct RunResult: Identifiable { let id = UUID(); let text: String }

    var body: some View {
        List {
            Section {
                ForEach(personalTasks) { task in row(task) }
            } header: {
                HStack {
                    JBListHeader(title: Flavor.mainAgentTasksHeader, count: personalTasks.isEmpty ? nil : personalTasks.count)
                    Button { creatingPersonal = true } label: { Image(systemName: "plus").foregroundStyle(JB.accent) }
                        .accessibilityLabel("New personal task")
                }
            }
            Section {
                if tasks.isEmpty && !loading { JBEmptyRow(art: .inbox, text: "No tasks") }
                ForEach(tasks) { task in row(task) }
            } header: { JBListHeader(title: "General", count: tasks.isEmpty ? nil : tasks.count) }
        }
        .animation(JB.smooth, value: (tasks + personalTasks).map(\.id))
        .jbPlainList()
        .navigationTitle("Tasks")
        .navigationBarTitleDisplayMode(.inline)
        .overlay { if loading && tasks.isEmpty && personalTasks.isEmpty { JBSpinner() } }
        .refreshable { await load() }
        .task { await load() }
        .toolbar { ToolbarItem(placement: .topBarTrailing) { JBPlusButton(label: "New task") { creating = true } } }
        .sheet(isPresented: $creating) { TaskEditor(ws: ws, task: nil, hosts: hosts) { Task { await load() } }.environment(theme) }
        .sheet(isPresented: $creatingPersonal) { TaskEditor(ws: ws, task: nil, scope: "personal", hosts: hosts) { Task { await load() } }.environment(theme) }
        .sheet(item: $editing) { task in TaskEditor(ws: ws, task: task, scope: task.scope ?? "general", hosts: hosts) { Task { await load() } }.environment(theme) }
        .sheet(item: $runResult) { result in resultSheet(result.text) }
        .alert("Delete this task?", isPresented: alertBinding($deleteTarget)) {
            Button("Delete task", role: .destructive) {
                if let task = deleteTarget { Task { await act { try await ws.deleteTask(id: task.id) } } }
                deleteTarget = nil
            }
            Button("Keep it", role: .cancel) { deleteTarget = nil }
        } message: {
            Text("“\(deleteTarget?.name ?? "")” stops running and is removed.")
        }
        .alert("Tasks", isPresented: alertBinding($error)) { Button("OK") { error = nil } } message: { Text(error ?? "") }
    }

    // MARK: Row

    private func row(_ task: WSTask) -> some View {
        Button { editing = task } label: { TaskRow(task: task, running: running == task.id) }
            .buttonStyle(.plain)
            .jbListRow()
            .contextMenu { menu(task) }
            .swipeActions(edge: .trailing, allowsFullSwipe: false) {
                Button("Delete", systemImage: "trash") { deleteTarget = task }.tint(JB.danger)
                Button("Edit", systemImage: "pencil") { editing = task }.tint(JB.ink3)
            }
            .swipeActions(edge: .leading, allowsFullSwipe: false) {
                Button(task.isPaused ? "Resume" : "Pause",
                       systemImage: task.isPaused ? "play" : "pause") {
                    Task { await act { try await ws.taskAction(id: task.id, action: task.isPaused ? "resume" : "pause") } }
                }
                .tint(JB.warn)
                Button("Run now", systemImage: "play") { Task { await runNow(task) } }
                    .tint(JB.accent)
            }
    }

    @ViewBuilder
    private func menu(_ task: WSTask) -> some View {
        Button("Edit task", systemImage: "pencil") { editing = task }
        Button("Run now", systemImage: "play") { Task { await runNow(task) } }
        Button(task.isPaused ? "Resume" : "Pause",
               systemImage: task.isPaused ? "play" : "pause") {
            Task { await act { try await ws.taskAction(id: task.id, action: task.isPaused ? "resume" : "pause") } }
        }
        Menu("Agent access", systemImage: "lock.shield") {
            ForEach(WSPermissionMode.allCases) { mode in
                Button {
                    Task { await act { try await ws.setTaskPermission(id: task.id, mode: mode.rawValue) } }
                } label: {
                    Label(mode.label, systemImage: task.permissionMode == mode.rawValue ? "checkmark" : mode.symbol)
                }
            }
        }
        Divider()
        Button("Delete task", systemImage: "trash", role: .destructive) { deleteTarget = task }
    }

    private func resultSheet(_ text: String) -> some View {
        NavigationStack {
            ScrollView {
                Text(text)
                    .font(.jb(15)).foregroundStyle(JB.ink)
                    .textSelection(.enabled)
                    .frame(maxWidth: .infinity, alignment: .leading)
                    .padding(20)
            }
            .jbWallpaper()
            .navigationTitle("Result")
            .navigationBarTitleDisplayMode(.inline)
            .toolbar {
                ToolbarItem(placement: .topBarTrailing) { Button("Done") { runResult = nil } }
            }
        }
    }

    // MARK: Work

    private func runNow(_ task: WSTask) async {
        guard running == nil else { return }
        running = task.id
        defer { running = nil }
        do { runResult = RunResult(text: try await ws.runTask(id: task.id)) }
        catch { self.error = error.localizedDescription }
    }

    private func load() async {
        guard !loading else { return }
        loading = true
        defer { loading = false }
        do {
            tasks = try await ws.tasks()
            personalTasks = (try? await ws.tasks(scope: "personal")) ?? personalTasks
            if hosts.isEmpty { hosts = await ws.nightHosts() }
            error = nil
        } catch { self.error = error.localizedDescription }
    }

    private func act(_ work: () async throws -> Void) async {
        do { try await work(); await load() } catch { self.error = error.localizedDescription }
    }
}

private struct TaskRow: View {
    let task: WSTask
    let running: Bool

    var body: some View {
        HStack(spacing: 11) {
            Group { if task.isCoding { JBIcon(.coding, size: 15) } else { JBIcon(.tasks, size: 15) } }
                .foregroundStyle(task.isPaused ? JB.ink3 : JB.accent).frame(width: 20)
            VStack(alignment: .leading, spacing: 3) {
                Text(task.name).font(.jb(15)).foregroundStyle(JB.ink).lineLimit(1)
                Text(subtitle).font(.jb(11)).foregroundStyle(JB.ink3).lineLimit(1)
            }
            Spacer(minLength: 0)
            if running { JBSpinner() }
            if let c = task.codingStatus, !c.isEmpty {
                HStack(spacing: 5) {
                    if c == "running" { JBStatusDot(live: true, size: 6) }
                    JBChip(text: c, tint: c == "running" ? JB.live : c == "review" ? JB.accent : c == "failed" ? JB.danger : JB.ink2)
                }
            }
            if task.isPaused { JBChip(text: "paused") }
        }
        .opacity(task.isPaused ? 0.6 : 1)
        .contentShape(Rectangle())
    }

    private var subtitle: String {
        let when = task.schedule.isEmpty ? "unscheduled" : task.schedule
        let time = task.scheduledTime.isEmpty ? "" : " " + task.scheduledTime
        let tail = task.isCoding ? (task.codingAgent == "any" ? "any agent" : task.codingAgent ?? "") : WSPermissionMode.named(task.permissionMode).label.lowercased()
        return "\(when)\(time) · \(tail)"
    }
}

// MARK: - Editor

struct TaskEditor: View {
    let ws: WorkspaceAPI
    let task: WSTask?
    var scope: String = "general"
    var hosts: [NSHost] = []
    var onSave: () -> Void

    @Environment(\.dismiss) private var dismiss
    @State private var name = ""
    @State private var prompt = ""
    @State private var schedule = "daily"
    @State private var time = "08:00"
    @State private var repeatDay = 0
    @State private var permissionMode = "sandbox"
    @State private var coding = false
    @State private var agent = "claude"
    @State private var model = ""
    @State private var host = ""
    @State private var repo = ""
    @State private var saving = false
    @State private var error: String?

    private static let weekdays = ["Monday", "Tuesday", "Wednesday", "Thursday", "Friday", "Saturday", "Sunday"]
    private static let models = ["claude": ["opus", "sonnet", "haiku"], "codex": ["gpt-5-codex", "gpt-5"],
                                 "opencode": ["qwen3-coder:30b", "llama3.3:70b", "deepseek-v3.2"],
                                 "agy": ["gemini-4-neon-high", "gemini-4-carbon-medium", "gemini-3.8-flash-high"], "any": []]

    var body: some View {
        NavigationStack {
            Form {
                if scope != "personal" {
                    Section { JBSegments(options: [(false, "AI task"), (true, "Coding agent")], selection: $coding) }
                        .listRowBackground(Color.clear)
                }
                Section {
                    TextField("Name", text: $name)
                    TextField(coding ? "What should the agent do?" : "Prompt", text: $prompt, axis: .vertical).lineLimit(3...8)
                }.jbFormRow()
                Section {
                    Picker("Repeats", selection: $schedule) {
                        Text("Daily").tag("daily")
                        Text("Weekly").tag("weekly")
                        Text("Monthly").tag("monthly")
                    }
                    .tint(JB.accent)
                    if schedule == "weekly" {
                        Picker("On", selection: $repeatDay) {
                            ForEach(Self.weekdays.indices, id: \.self) { index in
                                Text(Self.weekdays[index]).tag(index)
                            }
                        }
                        .tint(JB.accent)
                    }
                    TextField("Time (HH:MM)", text: $time).font(.jb(15)).keyboardType(.numbersAndPunctuation)
                    if !coding { WSPermissionPicker(title: "Agent access", mode: $permissionMode) }
                }.jbFormRow()
                if coding {
                    Section {
                        Picker("Agent", selection: $agent) {
                            Text("Claude Code").tag("claude"); Text("Codex").tag("codex"); Text("OpenCode").tag("opencode"); Text("Antigravity").tag("agy"); Text("Any").tag("any")
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
                        TextField("Folder", text: $repo).font(.jb(14)).textInputAutocapitalization(.never).autocorrectionDisabled()
                    }.jbFormRow()
                    .transition(.opacity)
                }
            }
            .animation(JB.snap, value: coding)
            .scrollContentBackground(.hidden)
            .jbWallpaper()
            .navigationTitle((scope == "personal" ? "Personal " : "") + (task == nil ? "new task" : "edit task"))
            .navigationBarTitleDisplayMode(.inline)
            .onChange(of: agent) { _, _ in model = "" }
            .toolbar {
                ToolbarItem(placement: .topBarLeading) { Button("Cancel") { dismiss() }.disabled(saving) }
                ToolbarItem(placement: .topBarTrailing) {
                    Button("Save") { Task { await save() } }.disabled(!canSave || saving)
                }
            }
            .overlay { if saving { JBSpinner() } }
            .task { fill() }
            .alert("Task", isPresented: alertBinding($error)) { Button("OK") { error = nil } } message: { Text(error ?? "") }
        }
    }

    private func fill() {
        if host.isEmpty, let l = hosts.first(where: { $0.local == true }) { host = l.id }
        guard let task else { return }
        name = task.name
        prompt = task.prompt
        schedule = task.schedule.isEmpty ? "daily" : task.schedule
        time = task.scheduledTime.isEmpty ? "08:00" : task.scheduledTime
        repeatDay = min(6, max(0, task.repeatDay))
        permissionMode = task.permissionMode
        coding = task.isCoding
        if task.isCoding {
            agent = task.codingAgent ?? "claude"; model = task.codingModel ?? ""; repo = task.codingRepo ?? ""
            if let h = task.codingHost, !h.isEmpty { host = h }
        }
    }

    private func save() async {
        guard !saving else { return }
        saving = true
        defer { saving = false }
        let extra: [String: Any] = scope == "personal" ? [:] : coding
            ? ["coding_agent": agent, "coding_repo": repo, "coding_host": host, "coding_model": model]
            : ["coding_agent": "", "coding_repo": "", "coding_host": "", "coding_model": ""]
        do {
            try await ws.saveTask(id: task?.id, name: name, prompt: prompt, schedule: schedule,
                                  time: time, repeatDay: repeatDay, permissionMode: permissionMode, scope: scope, coding: extra)
            onSave()
            dismiss()
        } catch { self.error = error.localizedDescription }
    }

    private var canSave: Bool {
        !name.trimmingCharacters(in: .whitespaces).isEmpty &&
        !prompt.trimmingCharacters(in: .whitespaces).isEmpty && validTime && (!coding || !repo.trimmingCharacters(in: .whitespaces).isEmpty)
    }

    private var validTime: Bool {
        let parts = time.split(separator: ":", omittingEmptySubsequences: false)
        guard parts.count == 2, parts[0].count == 2, parts[1].count == 2,
              let hour = Int(parts[0]), let minute = Int(parts[1]) else { return false }
        return (0...23).contains(hour) && (0...59).contains(minute)
    }
}
