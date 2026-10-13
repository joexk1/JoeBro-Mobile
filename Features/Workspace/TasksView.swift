import SwiftUI

/// Scheduled prompts: create, edit, delete, pause/resume, run now and set the
/// agent's access level — the same set the Mac's right-click menu offers.
struct TasksView: View {
    let ws: WorkspaceAPI
    @Environment(JoeBroTheme.self) private var theme

    @State private var tasks: [WSTask] = []
    @State private var personalTasks: [WSTask] = []
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
                if personalTasks.isEmpty && !loading {
                    Text("No personal tasks yet. They run silently and only notify you when there is news.")
                        .font(.footnote).foregroundStyle(.secondary)
                        .listRowBackground(Color.white.opacity(0.06))
                }
                ForEach(personalTasks) { task in row(task) }
            } header: {
                HStack {
                    Text("JoeBro phone agent")
                    Spacer()
                    Button { creatingPersonal = true } label: {
                        Image(systemName: "plus.circle").foregroundStyle(Color.accentTint)
                    }
                    .accessibilityLabel("New personal task")
                }
            }
            Section("General") {
                if tasks.isEmpty && !loading {
                    empty("clock.arrow.circlepath", "No scheduled tasks",
                          "Add one and JoeBro runs it on a schedule.")
                }
                ForEach(tasks) { task in
                    row(task)
                }
            }
        }
        .listStyle(.insetGrouped)
        .scrollContentBackground(.hidden)
        .jbWallpaper()
        .navigationTitle("Tasks")
        .navigationBarTitleDisplayMode(.inline)
        .overlay { if loading && tasks.isEmpty && personalTasks.isEmpty { ProgressView().controlSize(.large) } }
        .refreshable { await load() }
        .task { await load() }
        .toolbar {
            ToolbarItem(placement: .topBarTrailing) {
                Button { creating = true } label: {
                    Image(systemName: "plus").foregroundStyle(Color.accentTint)
                }
                .accessibilityLabel("New task")
            }
        }
        .sheet(isPresented: $creating) { TaskEditor(ws: ws, task: nil) { Task { await load() } }.environment(theme) }
        .sheet(isPresented: $creatingPersonal) { TaskEditor(ws: ws, task: nil, scope: "personal") { Task { await load() } }.environment(theme) }
        .sheet(item: $editing) { task in TaskEditor(ws: ws, task: task, scope: task.scope ?? "general") { Task { await load() } }.environment(theme) }
        .sheet(item: $runResult) { result in resultSheet(result.text) }
        .alert("Delete this task?", isPresented: alertBinding($deleteTarget)) {
            Button("Delete task", role: .destructive) {
                if let task = deleteTarget { Task { await act { try await ws.deleteTask(id: task.id) } } }
                deleteTarget = nil
            }
            Button("Keep it", role: .cancel) { deleteTarget = nil }
        } message: {
            Text("“\(deleteTarget?.name ?? "")” stops running and is removed from the backend. This can't be undone.")
        }
        .alert("Tasks", isPresented: alertBinding($error)) { Button("OK") { error = nil } } message: { Text(error ?? "") }
    }

    // MARK: Row

    private func row(_ task: WSTask) -> some View {
        Button { editing = task } label: { TaskRow(task: task, running: running == task.id) }
            .buttonStyle(.plain)
            .listRowBackground(Color.white.opacity(0.06))
            .contextMenu { menu(task) }
            .swipeActions(edge: .trailing, allowsFullSwipe: false) {
                Button("Delete", systemImage: "trash") { deleteTarget = task }.tint(.red)
                Button("Edit", systemImage: "pencil") { editing = task }.tint(.gray)
            }
            .swipeActions(edge: .leading, allowsFullSwipe: false) {
                Button(task.isPaused ? "Resume" : "Pause",
                       systemImage: task.isPaused ? "play.fill" : "pause.fill") {
                    Task { await act { try await ws.taskAction(id: task.id, action: task.isPaused ? "resume" : "pause") } }
                }
                .tint(.orange)
                Button("Run now", systemImage: "bolt.fill") { Task { await runNow(task) } }
                    .tint(Color.accentTint)
            }
    }

    @ViewBuilder
    private func menu(_ task: WSTask) -> some View {
        Button("Edit task", systemImage: "pencil") { editing = task }
        Button("Run now", systemImage: "bolt.fill") { Task { await runNow(task) } }
        Button(task.isPaused ? "Resume" : "Pause",
               systemImage: task.isPaused ? "play.fill" : "pause.fill") {
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
                    .foregroundStyle(.white)
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
            WSStatusDot(on: !task.isPaused)
            VStack(alignment: .leading, spacing: 3) {
                HStack(spacing: 6) {
                    Text(task.name).foregroundStyle(.white).lineLimit(1)
                    if task.isPaused {
                        Text("Paused")
                            .font(.caption2)
                            .padding(.horizontal, 7).padding(.vertical, 2)
                            .background(.white.opacity(0.15), in: Capsule())
                            .foregroundStyle(.white.opacity(0.8))
                    }
                    Spacer(minLength: 0)
                    if running { ProgressView().controlSize(.mini).tint(Color.accentTint) }
                }
                Text(subtitle).font(.caption).foregroundStyle(.secondary).lineLimit(1)
            }
        }
        .frame(minHeight: 48)
        .contentShape(Rectangle())
    }

    private var subtitle: String {
        let when = task.schedule.isEmpty ? "Unscheduled" : task.schedule.capitalized
        let time = task.scheduledTime.isEmpty ? "" : " at \(task.scheduledTime)"
        return "\(when)\(time) · \(WSPermissionMode.named(task.permissionMode).label)"
    }
}

// MARK: - Editor

struct TaskEditor: View {
    let ws: WorkspaceAPI
    let task: WSTask?
    var scope: String = "general"
    var onSave: () -> Void

    @Environment(\.dismiss) private var dismiss
    @State private var name = ""
    @State private var prompt = ""
    @State private var schedule = "daily"
    @State private var time = "08:00"
    @State private var repeatDay = 0
    @State private var permissionMode = "sandbox"
    @State private var saving = false
    @State private var error: String?

    private static let weekdays = ["Monday", "Tuesday", "Wednesday", "Thursday", "Friday", "Saturday", "Sunday"]

    var body: some View {
        NavigationStack {
            Form {
                Section("Task") {
                    TextField("Name", text: $name)
                    TextField("Prompt", text: $prompt, axis: .vertical).lineLimit(3...8)
                }
                .listRowBackground(Color.white.opacity(0.06))
                Section("Schedule") {
                    Picker("Repeats", selection: $schedule) {
                        Text("Daily").tag("daily")
                        Text("Weekly").tag("weekly")
                        Text("Monthly").tag("monthly")
                    }
                    .tint(Color.accentTint)
                    if schedule == "weekly" {
                        Picker("On", selection: $repeatDay) {
                            ForEach(Self.weekdays.indices, id: \.self) { index in
                                Text(Self.weekdays[index]).tag(index)
                            }
                        }
                        .tint(Color.accentTint)
                    } else if schedule == "monthly" {
                        Text("Runs on the first day of each month")
                            .font(.footnote).foregroundStyle(.secondary)
                    }
                    TextField("Time (HH:MM)", text: $time).keyboardType(.numbersAndPunctuation)
                    WSPermissionPicker(title: "Agent access", mode: $permissionMode)
                }
                .listRowBackground(Color.white.opacity(0.06))
            }
            .scrollContentBackground(.hidden)
            .jbWallpaper()
            .navigationTitle((scope == "personal" ? "Personal " : "") + (task == nil ? "new task" : "edit task"))
            .navigationBarTitleDisplayMode(.inline)
            .toolbar {
                ToolbarItem(placement: .topBarLeading) { Button("Cancel") { dismiss() }.disabled(saving) }
                ToolbarItem(placement: .topBarTrailing) {
                    Button("Save") { Task { await save() } }.disabled(!canSave || saving)
                }
            }
            .overlay { if saving { ProgressView().controlSize(.large) } }
            .task { fill() }
            .alert("Task", isPresented: alertBinding($error)) { Button("OK") { error = nil } } message: { Text(error ?? "") }
        }
    }

    private func fill() {
        guard let task else { return }
        name = task.name
        prompt = task.prompt
        schedule = task.schedule.isEmpty ? "daily" : task.schedule
        time = task.scheduledTime.isEmpty ? "08:00" : task.scheduledTime
        repeatDay = min(6, max(0, task.repeatDay))
        permissionMode = task.permissionMode
    }

    private func save() async {
        guard !saving else { return }
        saving = true
        defer { saving = false }
        do {
            try await ws.saveTask(id: task?.id, name: name, prompt: prompt, schedule: schedule,
                                  time: time, repeatDay: repeatDay, permissionMode: permissionMode, scope: scope)
            onSave()
            dismiss()
        } catch { self.error = error.localizedDescription }
    }

    private var canSave: Bool {
        !name.trimmingCharacters(in: .whitespaces).isEmpty &&
        !prompt.trimmingCharacters(in: .whitespaces).isEmpty && validTime
    }

    private var validTime: Bool {
        let parts = time.split(separator: ":", omittingEmptySubsequences: false)
        guard parts.count == 2, parts[0].count == 2, parts[1].count == 2,
              let hour = Int(parts[0]), let minute = Int(parts[1]) else { return false }
        return (0...23).contains(hour) && (0...59).contains(minute)
    }
}
