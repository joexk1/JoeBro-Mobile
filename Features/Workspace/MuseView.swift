import SwiftUI

/// The personal agent's memory: plain markdown files (about-me, preferences,
/// people, projects, routines). Browse, edit, add and delete them. about-me is
/// always in the agent's prompt; the others are searched per request.
struct MuseView: View {
    let ws: WorkspaceAPI

    @State private var files: [WorkspaceAPI.MuseFile] = []
    @State private var loading = false
    @State private var adding = false
    @State private var newName = ""
    @State private var deleteTarget: WorkspaceAPI.MuseFile?
    @State private var error: String?

    var body: some View {
        List {
            Section {
                ForEach(files) { file in
                    NavigationLink(destination: MuseFileView(ws: ws, name: file.name, onSaved: { Task { await load() } })) {
                        HStack(spacing: 13) {
                            Group {
                                if file.always { JBIcon(.agent, size: 17) } else { Image(systemName: "doc.text").font(.jb(16)) }
                            }
                            .foregroundStyle(JB.ink2).frame(width: 28)
                            VStack(alignment: .leading, spacing: 2) {
                                Text(file.name).font(.jb(15)).foregroundStyle(JB.ink)
                                Text(file.always ? "always on · \(file.lines) lines" : "\(file.lines) lines")
                                    .font(.jbMono(10.5)).foregroundStyle(JB.ink3)
                            }
                        }
                        .frame(minHeight: 48)
                    }
                    .listRowBackground(JB.panelFill)
                    .swipeActions(edge: .trailing, allowsFullSwipe: false) {
                        if !file.always {
                            Button("Delete", systemImage: "trash") { deleteTarget = file }.tint(JB.danger)
                        }
                    }
                }
            }
        }
        .animation(JB.smooth, value: files.map(\.name))
        .listStyle(.insetGrouped)
        .jbForm()
        .navigationTitle(Flavor.memoryTitle)
        .navigationBarTitleDisplayMode(.inline)
        .overlay { if loading && files.isEmpty { JBSpinner(size: 16) } }
        .refreshable { await load() }
        .task { await load() }
        .toolbar {
            ToolbarItem(placement: .topBarTrailing) {
                Button { newName = ""; adding = true } label: {
                    Image(systemName: "plus").foregroundStyle(JB.accent)
                }
                .accessibilityLabel("Add memory file")
            }
        }
        .alert("New memory file", isPresented: $adding) {
            TextField("Name, e.g. health", text: $newName).textInputAutocapitalization(.never)
            Button("Create") { Task { await act { try await ws.museCreate(newName) } } }
            Button("Cancel", role: .cancel) {}
        }
        .alert("Delete this file?", isPresented: alertBinding($deleteTarget)) {
            Button("Delete", role: .destructive) {
                if let f = deleteTarget { Task { await act { try await ws.museDelete(f.name) } } }
                deleteTarget = nil
            }
            Button("Keep it", role: .cancel) { deleteTarget = nil }
        } message: {
            Text("“\(deleteTarget?.name ?? "")” and everything in it will be removed.")
        }
        .alert("Memory", isPresented: alertBinding($error)) { Button("OK") { error = nil } } message: { Text(error ?? "") }
    }

    private func load() async {
        guard !loading else { return }
        loading = true
        defer { loading = false }
        do { files = try await ws.museFiles(); error = nil } catch { self.error = error.localizedDescription }
    }

    private func act(_ work: () async throws -> Void) async {
        do { try await work(); await load() } catch { self.error = error.localizedDescription }
    }
}

private struct MuseFileView: View {
    let ws: WorkspaceAPI
    let name: String
    let onSaved: () -> Void

    @State private var text = ""
    @State private var original = ""
    @State private var loaded = false
    @State private var saving = false
    @State private var error: String?

    var body: some View {
        TextEditor(text: $text)
            .font(.jbMono(14))
            .foregroundStyle(JB.ink)
            .scrollContentBackground(.hidden)
            .padding(12)
            .jbSurface(.panel, radius: JB.rCard)
            .padding(16)
            .jbWallpaper()
            .navigationTitle(name)
            .navigationBarTitleDisplayMode(.inline)
            .overlay { if !loaded { JBSpinner(size: 16) } }
            .toolbar {
                ToolbarItem(placement: .topBarTrailing) {
                    Button("Save") { Task { await save() } }
                        .disabled(saving || !loaded || text == original)
                }
            }
            .task {
                do { original = try await ws.museRead(name); text = original; loaded = true }
                catch { self.error = error.localizedDescription }
            }
            .alert("Memory", isPresented: alertBinding($error)) { Button("OK") { error = nil } } message: { Text(error ?? "") }
    }

    private func save() async {
        saving = true
        defer { saving = false }
        do { try await ws.museWrite(name, content: text); original = text; onSaved() }
        catch { self.error = error.localizedDescription }
    }
}
