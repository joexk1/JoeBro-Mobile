import SwiftUI

/// The one memory surface: what you told JoeBro (You), what every agent learned about a
/// project (Projects) and what applies everywhere (Global), each fact with who wrote it.
/// The plain-text Files the phone agent reads live under it too.
struct SharedMemoryView: View {
    let ws: WorkspaceAPI
    @Environment(JoeBroTheme.self) private var theme
    private enum Scope: String, CaseIterable { case all = "All", you = "You", projects = "Projects", global = "Global" }
    @State private var scope = Scope(rawValue: DemoMode.option("-JoeBroMemScope") ?? "") ?? Scope.all
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
            VStack(alignment: .leading, spacing: 8) {
                JBSegments(options: Scope.allCases.map { ($0, $0.rawValue) }, selection: $scope)
                HStack(spacing: 8) {
                    if (scope == .projects || scope == .all) && projects.count > 2 {
                        Picker("", selection: $project) {
                            Text("Every project").tag("__all")
                            ForEach(projects.filter { $0.key != "global" && $0.key != "user" }) { Text($0.label).tag($0.key) }
                        }.labelsHidden().tint(JB.ink2)
                    }
                    Spacer()
                    Button { showArchived.toggle() } label: { JBChip(text: "archived", tint: showArchived ? JB.accent : nil) }.buttonStyle(.plain)
                    NavigationLink { MuseView(ws: ws) } label: { JBChip(text: "files") }.buttonStyle(.plain)
                }
            }
            .listRowBackground(Color.clear).listRowSeparator(.hidden).listRowInsets(EdgeInsets(top: 4, leading: 14, bottom: 4, trailing: 14))
            if shown.isEmpty { JBEmptyRow(art: .inbox, text: "Nothing here yet") }
            ForEach(Array(shown.prefix(DemoMode.option("-JoeBroMemMax").flatMap(Int.init) ?? .max))) { fact in
                Button { editing = fact } label: { FactRow(fact: fact) }.buttonStyle(.plain)
                    .jbListRow()
                    .swipeActions(edge: .leading) {
                        Button(fact.isPinned ? "Unpin" : "Pin", systemImage: "pin") { Task { await act { try await ws.memoryPin(fact.id, pinned: !fact.isPinned) } } }.tint(JB.accent)
                    }
                    .swipeActions(edge: .trailing) {
                        if fact.isArchived { Button("Restore", systemImage: "arrow.uturn.backward") { Task { await act { try await ws.memoryRestore(fact.id) } } }.tint(JB.live) }
                        else { Button("Archive", systemImage: "archivebox") { Task { await act { try await ws.memoryArchive(fact.id) } } }.tint(JB.ink3) }
                    }
            }
        }
        .animation(JB.smooth, value: shown.map(\.id))
        .jbPlainList()
        .navigationTitle("Memory").navigationBarTitleDisplayMode(.inline)
        .searchable(text: $search, prompt: "Search memory")
        .onSubmit(of: .search) { Task { await load() } }
        .onChange(of: search) { _, v in if v.isEmpty { Task { await load() } } }
        .onChange(of: project) { _, _ in Task { await load() } }
        .onChange(of: showArchived) { _, _ in Task { await load() } }
        .refreshable { await load() }.task { await load() }
        .toolbar { ToolbarItem(placement: .topBarTrailing) { JBPlusButton(label: "Add to memory") { adding = true } } }
        .sheet(item: $editing) { f in FactEditor(ws: ws, fact: f) { Task { await load() } }.environment(theme) }
        .sheet(isPresented: $adding) { FactAdder(ws: ws, projects: projects, current: project) { Task { await load() } }.environment(theme) }
        .alert("Memory", isPresented: alertBinding($error)) { Button("OK") { error = nil } } message: { Text(error ?? "") }
    }

    private func load() async {
        do {
            if projects.isEmpty { projects = try await ws.memoryProjects() }
            facts = try await ws.memoryFacts(project: project, status: showArchived ? "all" : "active", query: search)
            error = nil
        } catch where error.isNotFound { facts = []; self.error = nil       // nothing there yet: empty state
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
                Text(((fact.topic ?? "").isEmpty ? fact.kindLabel : (fact.topic ?? "")).lowercased()).font(.jb(11)).foregroundStyle(JB.ink3)
                Spacer()
                if fact.isPinned { Circle().fill(JB.accent).frame(width: 6, height: 6) }
                Text(nsRelative(fact.updatedAt)).font(.jb(11)).foregroundStyle(JB.ink3)
            }
            Text(fact.text).font(.jb(15)).foregroundStyle(JB.ink).fixedSize(horizontal: false, vertical: true)
            HStack(spacing: 8) {
                Capsule().fill(JB.line).frame(width: 40, height: 2)
                    .overlay(alignment: .leading) { Capsule().fill(fact.strengthValue < 0.3 ? JB.warn : JB.accent).frame(width: 40 * fact.strengthValue, height: 2) }
                Text([fact.provenanceLine, fact.scope == "project" ? fact.projectName ?? "" : ""].filter { !$0.isEmpty }.joined(separator: " · "))
                    .font(.jb(11)).foregroundStyle(JB.ink3).lineLimit(1)
            }
        }.contentShape(Rectangle()).opacity(fact.isArchived ? 0.5 : 1)
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
                Section { TextField("Fact", text: $text, axis: .vertical).lineLimit(2...10) }.jbFormRow()
                Section {
                    TextField("Topic", text: $topic)
                    Picker("Kind", selection: $kind) { ForEach(["fact", "decision", "gotcha", "preference", "handoff", "learned"], id: \.self) { Text($0).tag($0) } }
                }.jbFormRow()
                Section {
                    LabeledContent("By", value: fact.provenanceLine.isEmpty ? "unknown" : fact.provenanceLine)
                    LabeledContent("Strength", value: "\(Int(fact.strengthValue * 100))%")
                    LabeledContent("Recalled", value: "\(fact.recalls ?? 0)x")
                }.font(.jb(13)).jbFormRow()
                if history.count > 1 {
                    Section { ForEach(history.dropLast()) { Text($0.text).font(.jbFootnote).foregroundStyle(JB.ink3) } } header: { JBSectionHeader("Earlier", count: history.count - 1) }.jbFormRow()
                }
                Section {
                    Button(fact.isPinned ? "Unpin" : "Pin") { Task { await run { try await ws.memoryPin(fact.id, pinned: !fact.isPinned) } } }
                    if fact.isArchived { Button("Restore") { Task { await run { try await ws.memoryRestore(fact.id) } } } }
                    else { Button("Archive", role: .destructive) { Task { await run { try await ws.memoryArchive(fact.id) } } } }
                }.jbFormRow()
                if let error { Text(error).foregroundStyle(JB.danger).font(.jb(12)) }
            }
            .scrollContentBackground(.hidden).jbWallpaper()
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
                Picker("Kind", selection: $kind) { ForEach(["fact", "decision", "gotcha", "preference"], id: \.self) { Text($0).tag($0) } }
                if let error { Text(error).foregroundStyle(JB.danger).font(.jb(12)) }
            }
            .scrollContentBackground(.hidden).jbWallpaper()
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
