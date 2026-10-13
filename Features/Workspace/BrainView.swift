import SwiftUI

/// What JoeBro remembers: add, edit, pin and delete memories, each with a
/// category (the backend's "topic").
struct BrainView: View {
    let api: JoeBroAPI
    let ws: WorkspaceAPI

    @State private var memories: [JBMemory] = []
    @State private var editing: JBMemory?
    @State private var adding = false
    @State private var deleteTarget: JBMemory?
    @State private var search = ""
    @State private var loading = false
    @State private var error: String?

    var body: some View {
        List {
            if memories.isEmpty && !loading {
                empty("brain", "Nothing remembered yet", "Add a fact and JoeBro keeps it in mind.")
            } else if filtered.isEmpty {
                empty("magnifyingglass", "No matches", "Nothing remembered matches “\(search)”.")
            }
            ForEach(filtered) { memory in
                row(memory)
            }
        }
        .listStyle(.insetGrouped)
        .scrollContentBackground(.hidden)
        .jbWallpaper()
        .searchable(text: $search, prompt: "Search memories")
        .navigationTitle("Brain")
        .navigationBarTitleDisplayMode(.inline)
        .overlay { if loading && memories.isEmpty { ProgressView().controlSize(.large) } }
        .refreshable { await load() }
        .task { await load() }
        .toolbar {
            ToolbarItem(placement: .topBarTrailing) {
                Button { adding = true } label: {
                    Image(systemName: "plus").foregroundStyle(Color.accentTint)
                }
                .accessibilityLabel("Add memory")
            }
        }
        .sheet(isPresented: $adding) { MemoryEditor(ws: ws, memory: nil) { Task { await load() } } }
        .sheet(item: $editing) { memory in MemoryEditor(ws: ws, memory: memory) { Task { await load() } } }
        .alert("Forget this memory?", isPresented: alertBinding($deleteTarget)) {
            Button("Forget it", role: .destructive) {
                if let memory = deleteTarget { Task { await act { try await ws.deleteMemory(id: memory.id) } } }
                deleteTarget = nil
            }
            Button("Keep it", role: .cancel) { deleteTarget = nil }
        } message: {
            Text("JoeBro permanently forgets “\(deleteTarget?.displayText.prefix(80) ?? "")”. This can't be undone.")
        }
        .alert("Brain", isPresented: alertBinding($error)) { Button("OK") { error = nil } } message: { Text(error ?? "") }
    }

    private func row(_ memory: JBMemory) -> some View {
        Button { editing = memory } label: { MemoryRow(memory: memory) }
            .buttonStyle(.plain)
            .listRowBackground(Color.white.opacity(0.06))
            .contextMenu {
                Button("Edit memory", systemImage: "pencil") { editing = memory }
                Button(memory.pinned == true ? "Unpin" : "Pin", systemImage: memory.pinned == true ? "pin.slash" : "pin") {
                    Task { await act { try await ws.pinMemory(id: memory.id) } }
                }
                Divider()
                Button("Forget", systemImage: "trash", role: .destructive) { deleteTarget = memory }
            }
            .swipeActions(edge: .trailing, allowsFullSwipe: false) {
                Button("Forget", systemImage: "trash") { deleteTarget = memory }.tint(.red)
                Button("Edit", systemImage: "pencil") { editing = memory }.tint(.gray)
            }
            .swipeActions(edge: .leading, allowsFullSwipe: false) {
                Button(memory.pinned == true ? "Unpin" : "Pin",
                       systemImage: memory.pinned == true ? "pin.slash" : "pin") {
                    Task { await act { try await ws.pinMemory(id: memory.id) } }
                }
                .tint(.orange)
            }
    }

    private var filtered: [JBMemory] {
        guard !search.isEmpty else { return memories }
        return memories.filter {
            $0.displayText.localizedCaseInsensitiveContains(search) ||
            ($0.category ?? "").localizedCaseInsensitiveContains(search)
        }
    }

    private func load() async {
        guard !loading else { return }
        loading = true
        defer { loading = false }
        do {
            let fresh = try await api.memory()
            if memories.isEmpty { memories = fresh }
            else { withAnimation(.smooth(duration: 0.24)) { memories = fresh } }
            error = nil
        } catch { self.error = error.localizedDescription }
    }

    private func act(_ work: () async throws -> Void) async {
        do { try await work(); await load() } catch { self.error = error.localizedDescription }
    }
}

private struct MemoryRow: View {
    let memory: JBMemory

    var body: some View {
        HStack(alignment: .top, spacing: 10) {
            if memory.pinned == true {
                Image(systemName: "pin.fill").font(.caption)
                    .foregroundStyle(.orange).padding(.top, 3)
                    .accessibilityLabel("Pinned")
            }
            VStack(alignment: .leading, spacing: 3) {
                Text(memory.displayText).foregroundStyle(.white).lineLimit(4)
                Text(memory.category ?? "general").font(.caption2).foregroundStyle(.secondary)
            }
            Spacer(minLength: 0)
        }
        .frame(maxWidth: .infinity, minHeight: 48, alignment: .leading)
        .contentShape(Rectangle())
    }
}

// MARK: - Editor

private struct MemoryEditor: View {
    let ws: WorkspaceAPI
    let memory: JBMemory?
    let onSave: () -> Void

    @Environment(\.dismiss) private var dismiss
    @State private var text: String
    @State private var category: String
    @State private var saving = false
    @State private var error: String?

    init(ws: WorkspaceAPI, memory: JBMemory?, onSave: @escaping () -> Void) {
        self.ws = ws
        self.memory = memory
        self.onSave = onSave
        _text = State(initialValue: memory?.displayText ?? "")
        _category = State(initialValue: memory?.category ?? "general")
    }

    var body: some View {
        NavigationStack {
            Form {
                Section("Memory") {
                    TextField("What should JoeBro remember?", text: $text, axis: .vertical).lineLimit(3...10)
                }
                .listRowBackground(Color.white.opacity(0.06))
                Section("Category") {
                    TextField("Topic", text: $category).textInputAutocapitalization(.never)
                }
                .listRowBackground(Color.white.opacity(0.06))
            }
            .scrollContentBackground(.hidden)
            .jbWallpaper()
            .navigationTitle(memory == nil ? "New memory" : "Edit memory")
            .navigationBarTitleDisplayMode(.inline)
            .toolbar {
                ToolbarItem(placement: .topBarLeading) { Button("Cancel") { dismiss() }.disabled(saving) }
                ToolbarItem(placement: .topBarTrailing) {
                    Button("Save") { Task { await save() } }
                        .disabled(saving || text.trimmingCharacters(in: .whitespacesAndNewlines).isEmpty)
                }
            }
            .overlay { if saving { ProgressView().controlSize(.large) } }
            .alert("Memory", isPresented: alertBinding($error)) { Button("OK") { error = nil } } message: { Text(error ?? "") }
        }
    }

    private func save() async {
        guard !saving else { return }
        saving = true
        defer { saving = false }
        let topic = category.trimmingCharacters(in: .whitespacesAndNewlines)
        do {
            if let memory {
                try await ws.updateMemory(id: memory.id, text: text, category: topic.isEmpty ? "general" : topic)
            } else {
                try await ws.addMemory(text: text, category: topic.isEmpty ? "general" : topic)
            }
            onSave()
            dismiss()
        } catch { self.error = error.localizedDescription }
    }
}
