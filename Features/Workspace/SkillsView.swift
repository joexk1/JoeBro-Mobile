import SwiftUI
import UniformTypeIdentifiers

/// Learned procedures: add, edit, delete, switch active on and off, or upload
/// a `.md` file straight in as a new skill.
struct SkillsView: View {
    let ws: WorkspaceAPI

    @State private var skills: [WSSkill] = []
    @State private var editing: WSSkill?
    @State private var creating = false
    @State private var importingFile = false
    @State private var deleteTarget: WSSkill?
    @State private var search = ""
    @State private var loading = false
    @State private var error: String?

    var body: some View {
        List {
            if skills.isEmpty && !loading {
                empty("sparkles", "No skills", "Skills are procedures JoeBro has learned. Add or upload one.")
            } else if filtered.isEmpty {
                empty("magnifyingglass", "No matches", "No skill matches “\(search)”.")
            }
            ForEach(filtered) { skill in
                row(skill)
            }
        }
        .listStyle(.insetGrouped)
        .scrollContentBackground(.hidden)
        .jbWallpaper()
        .searchable(text: $search, prompt: "Search skills")
        .navigationTitle("Skills")
        .navigationBarTitleDisplayMode(.inline)
        .overlay { if loading && skills.isEmpty { ProgressView().controlSize(.large) } }
        .refreshable { await load() }
        .task { await load() }
        .toolbar {
            ToolbarItem(placement: .topBarTrailing) {
                Menu {
                    Button("New skill", systemImage: "square.and.pencil") { creating = true }
                    Button("Upload .md file", systemImage: "arrow.up.doc") { importingFile = true }
                } label: {
                    Image(systemName: "plus").foregroundStyle(Color.accentTint)
                }
                .accessibilityLabel("Add skill")
            }
        }
        .sheet(isPresented: $creating) { SkillEditor(ws: ws, skill: nil, seed: nil) { Task { await load() } } }
        .sheet(item: $editing) { skill in SkillEditor(ws: ws, skill: skill, seed: nil) { Task { await load() } } }
        .sheet(item: $uploaded) { seed in SkillEditor(ws: ws, skill: nil, seed: seed) { Task { await load() } } }
        .fileImporter(isPresented: $importingFile,
                      allowedContentTypes: [UTType("net.daringfireball.markdown") ?? .plainText, .plainText, .text],
                      allowsMultipleSelection: false) { result in
            handleImport(result)
        }
        .alert("Delete this skill?", isPresented: alertBinding($deleteTarget)) {
            Button("Delete skill", role: .destructive) {
                if let skill = deleteTarget { Task { await act { try await ws.deleteSkill(id: skill.id) } } }
                deleteTarget = nil
            }
            Button("Keep it", role: .cancel) { deleteTarget = nil }
        } message: {
            Text("“\(deleteTarget?.name ?? "")” is removed from the backend and JoeBro stops using it. This can't be undone.")
        }
        .alert("Skills", isPresented: alertBinding($error)) { Button("OK") { error = nil } } message: { Text(error ?? "") }
    }

    // MARK: Rows

    private func row(_ skill: WSSkill) -> some View {
        SkillRow(skill: skill) { on in
            Task { await act { try await ws.setSkillActive(id: skill.id, active: on) } }
        }
        .listRowBackground(Color.white.opacity(0.06))
        .contentShape(Rectangle())
        .onTapGesture { editing = skill }
        .contextMenu {
            Button("Edit skill", systemImage: "pencil") { editing = skill }
            Button(skill.isActive ? "Turn off" : "Turn on",
                   systemImage: skill.isActive ? "pause.circle" : "play.circle") {
                Task { await act { try await ws.setSkillActive(id: skill.id, active: !skill.isActive) } }
            }
            Divider()
            Button("Delete skill", systemImage: "trash", role: .destructive) { deleteTarget = skill }
        }
        .swipeActions(edge: .trailing, allowsFullSwipe: false) {
            Button("Delete", systemImage: "trash") { deleteTarget = skill }.tint(.red)
            Button("Edit", systemImage: "pencil") { editing = skill }.tint(.gray)
        }
        .swipeActions(edge: .leading, allowsFullSwipe: false) {
            Button(skill.isActive ? "Off" : "On",
                   systemImage: skill.isActive ? "pause.circle" : "play.circle") {
                Task { await act { try await ws.setSkillActive(id: skill.id, active: !skill.isActive) } }
            }
            .tint(Color.accentTint)
        }
    }

    // MARK: Upload

    /// A `.md` file read off disk, handed to the editor so the name and body
    /// can be checked before it is saved.
    struct SkillSeed: Identifiable {
        let id = UUID()
        let name: String
        let content: String
    }
    @State private var uploaded: SkillSeed?

    private func handleImport(_ result: Result<[URL], Error>) {
        switch result {
        case .failure(let failure):
            error = failure.localizedDescription
        case .success(let urls):
            guard let url = urls.first else { return }
            let scoped = url.startAccessingSecurityScopedResource()
            defer { if scoped { url.stopAccessingSecurityScopedResource() } }
            do {
                let text = try String(contentsOf: url, encoding: .utf8)
                uploaded = SkillSeed(name: url.deletingPathExtension().lastPathComponent, content: text)
            } catch {
                self.error = "Couldn't read \(url.lastPathComponent): \(error.localizedDescription)"
            }
        }
    }

    // MARK: Work

    private var filtered: [WSSkill] {
        guard !search.isEmpty else { return skills }
        return skills.filter {
            ($0.name + " " + $0.description + " " + $0.content).localizedCaseInsensitiveContains(search)
        }
    }

    private func load() async {
        guard !loading else { return }
        loading = true
        defer { loading = false }
        do { skills = try await ws.skills(); error = nil } catch { self.error = error.localizedDescription }
    }

    private func act(_ work: () async throws -> Void) async {
        do { try await work(); await load() } catch { self.error = error.localizedDescription }
    }
}

private struct SkillRow: View {
    let skill: WSSkill
    let setActive: (Bool) -> Void

    var body: some View {
        HStack(spacing: 11) {
            WSStatusDot(on: skill.isActive)
            VStack(alignment: .leading, spacing: 3) {
                Text(skill.name).foregroundStyle(.white).lineLimit(1)
                if !skill.description.isEmpty {
                    Text(skill.description).font(.caption).foregroundStyle(.secondary).lineLimit(2)
                }
            }
            Spacer(minLength: 8)
            WSToggle(label: "\(skill.name) active", isOn: skill.isActive, set: setActive)
        }
        .frame(minHeight: 48)
    }
}

// MARK: - Editor

private struct SkillEditor: View {
    let ws: WorkspaceAPI
    let skill: WSSkill?
    let onSave: () -> Void

    @Environment(\.dismiss) private var dismiss
    @State private var name: String
    @State private var description: String
    @State private var whenToUse: String
    @State private var content: String
    @State private var saving = false
    @State private var error: String?

    init(ws: WorkspaceAPI, skill: WSSkill?, seed: SkillsView.SkillSeed?, onSave: @escaping () -> Void) {
        self.ws = ws
        self.skill = skill
        self.onSave = onSave
        _name = State(initialValue: skill?.name ?? seed?.name ?? "")
        _description = State(initialValue: skill?.description ?? "")
        _whenToUse = State(initialValue: skill?.whenToUse ?? "")
        _content = State(initialValue: skill?.content ?? seed?.content ?? "")
    }

    var body: some View {
        NavigationStack {
            Form {
                Section("Skill") {
                    TextField("Name", text: $name)
                    TextField("Description", text: $description, axis: .vertical).lineLimit(2...4)
                    TextField("When to use", text: $whenToUse, axis: .vertical).lineLimit(2...4)
                }
                .listRowBackground(Color.white.opacity(0.06))
                Section("Procedure (markdown)") {
                    TextEditor(text: $content)
                        .frame(minHeight: 220)
                        .scrollContentBackground(.hidden)
                }
                .listRowBackground(Color.white.opacity(0.06))
            }
            .scrollContentBackground(.hidden)
            .jbWallpaper()
            .navigationTitle(skill == nil ? "New skill" : "Edit skill")
            .navigationBarTitleDisplayMode(.inline)
            .toolbar {
                ToolbarItem(placement: .topBarLeading) { Button("Cancel") { dismiss() }.disabled(saving) }
                ToolbarItem(placement: .topBarTrailing) {
                    Button("Save") { Task { await save() } }.disabled(saving || !canSave)
                }
            }
            .overlay { if saving { ProgressView().controlSize(.large) } }
            .alert("Skill", isPresented: alertBinding($error)) { Button("OK") { error = nil } } message: { Text(error ?? "") }
        }
    }

    private var canSave: Bool {
        !name.trimmingCharacters(in: .whitespacesAndNewlines).isEmpty &&
        !content.trimmingCharacters(in: .whitespacesAndNewlines).isEmpty
    }

    private func save() async {
        guard !saving else { return }
        saving = true
        defer { saving = false }
        do {
            try await ws.saveSkill(id: skill?.id, name: name, description: description,
                                   whenToUse: whenToUse, content: content)
            onSave()
            dismiss()
        } catch { self.error = error.localizedDescription }
    }
}
