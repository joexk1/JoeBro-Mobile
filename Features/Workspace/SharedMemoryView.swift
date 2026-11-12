import SwiftUI

/// The one memory screen: what you told JoeBro (You), what every agent learned about a
/// project (Projects) and what applies everywhere (Global), each fact with who wrote it.
struct SharedMemoryView: View {
    let ws: WorkspaceAPI
    @Environment(JoeBroTheme.self) private var theme
    private enum Scope: String, CaseIterable { case all = "All", you = "You", projects = "Projects", global = "Global" }
    @State private var scope = Scope.all
    @State private var projects: [SMProject] = []
    @State private var project = "__all"
    @State private var facts: [SMFact] = []
    @State private var search = ""
    @State private var showArchived = false
    @State private var editing: SMFact?
    @State private var adding = false
    @State private var error: String?

    private var shown: [SMFact] {
        facts.filter {
            switch scope {
            case .all: true
            case .you: $0.scope == "user"
            case .global: $0.scope == "global"
            case .projects: $0.scope == "project"
            }
        }.sorted { ($0.isPinned ? 1 : 0, $0.strengthValue) > ($1.isPinned ? 1 : 0, $1.strengthValue) }
    }

    var body: some View {
        List {
            Section {
                Picker("Scope", selection: $scope) { ForEach(Scope.allCases, id: \.self) { Text($0.rawValue).tag($0) } }.pickerStyle(.segmented)
                if scope == .projects || scope == .all {
                    Picker("Project", selection: $project) {
                        Text("Every project").tag("__all")
                        ForEach(projects.filter { $0.key != "global" && $0.key != "user" }) { Text($0.label).tag($0.key) }
                    }
                }
                Toggle("Show archived", isOn: $showArchived).tint(Color.accentTint)
            }.listRowBackground(Color.joeInk.opacity(0.06))
            Section {
                if shown.isEmpty { empty("brain", "Nothing here yet", "Agents add facts as they work. You can add your own with +.") }
                ForEach(shown) { fact in
                    Button { editing = fact } label: { FactRow(fact: fact) }.buttonStyle(.plain)
                        .listRowBackground(Color.joeInk.opacity(0.06))
                        .swipeActions(edge: .leading) {
                            Button(fact.isPinned ? "Unpin" : "Pin", systemImage: "pin") { Task { await act { try await ws.memoryPin(fact.id, pinned: !fact.isPinned) } } }.tint(.orange)
                        }
                        .swipeActions(edge: .trailing) {
                            if fact.isArchived { Button("Restore", systemImage: "arrow.uturn.backward") { Task { await act { try await ws.memoryRestore(fact.id) } } }.tint(.green) }
                            else { Button("Archive", systemImage: "archivebox") { Task { await act { try await ws.memoryArchive(fact.id) } } }.tint(.gray) }
                        }
                }
            }
        }
        .listStyle(.insetGrouped).scrollContentBackground(.hidden).jbWallpaper()
        .navigationTitle("Memory").navigationBarTitleDisplayMode(.inline)
        .searchable(text: $search, prompt: "Search memory")
        .onSubmit(of: .search) { Task { await load() } }
        .onChange(of: search) { _, v in if v.isEmpty { Task { await load() } } }
        .onChange(of: project) { _, _ in Task { await load() } }
        .onChange(of: showArchived) { _, _ in Task { await load() } }
        .refreshable { await load() }.task { await load() }
        .toolbar { ToolbarItem(placement: .topBarTrailing) { Button { adding = true } label: { Image(systemName: "plus").foregroundStyle(Color.accentTint) } } }
        .sheet(item: $editing) { f in FactEditor(ws: ws, fact: f) { Task { await load() } }.environment(theme) }
        .sheet(isPresented: $adding) { FactAdder(ws: ws, projects: projects, current: project) { Task { await load() } }.environment(theme) }
        .alert("Memory", isPresented: alertBinding($error)) { Button("OK") { error = nil } } message: { Text(error ?? "") }
    }

    private func load() async {
        do {
            if projects.isEmpty { projects = try await ws.memoryProjects() }
            facts = try await ws.memoryFacts(project: project, status: showArchived ? "all" : "active", query: search)
            error = nil
        } catch { self.error = error.localizedDescription }
    }
    private func act(_ work: () async throws -> Void) async {
        do { try await work(); await load() } catch { self.error = error.localizedDescription }
    }
}

private struct FactRow: View {
    let fact: SMFact
    var body: some View {
        VStack(alignment: .leading, spacing: 6) {
            HStack(spacing: 6) {
                Image(systemName: fact.kindSymbol).font(.caption).foregroundStyle(Color.accentTint)
                Text(fact.kindLabel).font(.caption.weight(.semibold)).foregroundStyle(.secondary)
                if let t = fact.topic, !t.isEmpty { Text("· " + t).font(.caption).foregroundStyle(.secondary) }
                Spacer()
                if fact.isPinned { Image(systemName: "pin.fill").font(.caption).foregroundStyle(.orange) }
                if fact.isArchived { Text("Archived").font(.caption2).foregroundStyle(.secondary) }
            }
            Text(fact.text).font(.subheadline).foregroundStyle(.joeInk).fixedSize(horizontal: false, vertical: true)
            HStack(spacing: 8) {
                ProgressView(value: fact.strengthValue).tint(fact.strengthValue < 0.3 ? .orange : Color.accentTint).frame(width: 54)
                Text(fact.provenanceLine).font(.caption2).foregroundStyle(.secondary).lineLimit(1)
                Spacer(minLength: 0)
                Text(nsRelative(fact.updatedAt)).font(.caption2).foregroundStyle(.secondary)
            }
            if fact.scope == "project", let n = fact.projectName { Text(n).font(.caption2).foregroundStyle(.tertiary) }
        }.padding(.vertical, 4).contentShape(Rectangle())
    }
}

struct FactEditor: View {
    let ws: WorkspaceAPI
    let fact: SMFact
    let saved: () -> Void
    @Environment(\.dismiss) private var dismiss
    @State private var text = ""
    @State private var topic = ""
    @State private var kind = "fact"
    @State private var history: [SMFact] = []
    @State private var error: String?
    var body: some View {
        NavigationStack {
            Form {
                Section("Fact") { TextField("Fact", text: $text, axis: .vertical).lineLimit(2...10) }
                Section {
                    TextField("Topic", text: $topic)
                    Picker("Kind", selection: $kind) { ForEach(["fact", "decision", "gotcha", "preference", "handoff", "learned"], id: \.self) { Text($0.capitalized).tag($0) } }
                }
                Section("Provenance") {
                    LabeledContent("Written by", value: fact.provenanceLine.isEmpty ? "Unknown" : fact.provenanceLine)
                    LabeledContent("Strength", value: "\(Int(fact.strengthValue * 100))%")
                    LabeledContent("Recalled", value: "\(fact.recalls ?? 0) times")
                }
                if history.count > 1 {
                    Section("Earlier versions") { ForEach(history.dropLast()) { Text($0.text).font(.footnote).foregroundStyle(.secondary) } }
                }
                Section {
                    Button(fact.isPinned ? "Unpin" : "Pin") { Task { await run { try await ws.memoryPin(fact.id, pinned: !fact.isPinned) } } }
                    if fact.isArchived { Button("Restore") { Task { await run { try await ws.memoryRestore(fact.id) } } } }
                    else { Button("Archive", role: .destructive) { Task { await run { try await ws.memoryArchive(fact.id) } } } }
                }
                if let error { Text(error).foregroundStyle(.red).font(.footnote) }
            }
            .navigationTitle("Memory").navigationBarTitleDisplayMode(.inline)
            .toolbar {
                ToolbarItem(placement: .cancellationAction) { Button("Cancel") { dismiss() } }
                ToolbarItem(placement: .confirmationAction) { Button("Save") { Task { await run { try await ws.memoryEdit(fact.id, text: text, topic: topic, kind: kind) } } } }
            }
            .task { text = fact.text; topic = fact.topic ?? ""; kind = fact.kind ?? "fact"; history = (try? await ws.memoryHistory(fact.id)) ?? [] }
        }
    }
    private func run(_ work: () async throws -> Void) async {
        do { try await work(); saved(); dismiss() } catch { self.error = error.localizedDescription }
    }
}

struct FactAdder: View {
    let ws: WorkspaceAPI
    let projects: [SMProject]
    let current: String
    let saved: () -> Void
    @Environment(\.dismiss) private var dismiss
    @State private var text = ""
    @State private var target = "user"
    @State private var kind = "fact"
    @State private var error: String?
    var body: some View {
        NavigationStack {
            Form {
                TextField("What should every agent know?", text: $text, axis: .vertical).lineLimit(2...8)
                Picker("Applies to", selection: $target) {
                    Text("You").tag("user"); Text("Everywhere").tag("global")
                    ForEach(projects.filter { $0.key != "global" && $0.key != "user" }) { Text($0.label).tag($0.key) }
                }
                Picker("Kind", selection: $kind) { ForEach(["fact", "decision", "gotcha", "preference"], id: \.self) { Text($0.capitalized).tag($0) } }
                if let error { Text(error).foregroundStyle(.red).font(.footnote) }
            }
            .navigationTitle("Add to memory").navigationBarTitleDisplayMode(.inline)
            .onAppear { if current != "__all" { target = current } }
            .toolbar {
                ToolbarItem(placement: .cancellationAction) { Button("Cancel") { dismiss() } }
                ToolbarItem(placement: .confirmationAction) {
                    Button("Add") { Task {
                        do { try await ws.memoryAdd(project: target, text: text, kind: kind); saved(); dismiss() } catch { self.error = error.localizedDescription }
                    } }.disabled(text.trimmingCharacters(in: .whitespaces).isEmpty)
                }
            }
        }
    }
}

/// Recent coding sessions from every linked agent, with Resume.
struct CodingSessionsView: View {
    let ws: WorkspaceAPI
    @State private var sessions: [JBAgentRecord] = []
    @State private var note: String?
    var body: some View {
        List {
            if sessions.isEmpty { empty("chevron.left.forwardslash.chevron.right", "No coding sessions yet", "Claude Code, Codex and OpenCode sessions show up here once linked.") }
            ForEach(sessions) { s in
                HStack(spacing: 12) {
                    Image(systemName: (s.kind ?? .coding).symbol).foregroundStyle(Color.accentTint).frame(width: 24)
                    VStack(alignment: .leading, spacing: 2) {
                        Text(s.displayTitle).foregroundStyle(.joeInk).lineLimit(2)
                        Text([s.model, s.isLive ? "running" : (s.status ?? "")].compactMap { $0 }.filter { !$0.isEmpty }.joined(separator: " · "))
                            .font(.caption).foregroundStyle(.secondary)
                    }
                    Spacer(minLength: 0)
                    if !s.isLive {
                        Button("Resume") { Task { do { try await ws.resumeCoding(s); note = "Resuming on your computer." } catch { note = error.localizedDescription } } }
                            .buttonStyle(.bordered).controlSize(.small)
                    }
                }.listRowBackground(Color.joeInk.opacity(0.06))
            }
        }
        .listStyle(.insetGrouped).scrollContentBackground(.hidden).jbWallpaper()
        .navigationTitle("Coding sessions").navigationBarTitleDisplayMode(.inline)
        .refreshable { await load() }.task { await load() }
        .alert("Coding sessions", isPresented: alertBinding($note)) { Button("OK") { note = nil } } message: { Text(note ?? "") }
    }
    private func load() async {
        sessions = ((try? await ws.recentCodingSessions()) ?? []).filter { $0.kind == .coding }
    }
}
