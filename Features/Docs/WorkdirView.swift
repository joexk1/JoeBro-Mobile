import SwiftUI
import QuickLook

/// The files of a chat's bound folder, mirroring the Mac sidebar's file tree.
/// Text files open in the editor; images and PDFs are fetched as raw bytes and
/// shown in QuickLook, since the backend has no preview route.
struct WorkdirView: View {
    let api: JoeBroAPI
    @State private var store: WorkdirStore
    @State private var openFile: String?
    @State private var previewURL: URL?
    @State private var renameTarget: String?
    @State private var renameName = ""
    @State private var deleteTarget: String?
    @State private var showBind = false

    init(api: JoeBroAPI, sessionID: String) {
        self.api = api
        _store = State(initialValue: WorkdirStore(api: api, sessionID: sessionID))
    }

    var body: some View {
        List {
            if store.root?.isEmpty != false {
                if store.loading { loadingState } else { unboundState }
            } else {
                Section {
                    if rows.isEmpty {
                        emptyFolderState
                    } else {
                        ForEach(rows, id: \.path) { item in
                            row(item.entry, path: item.path, depth: item.depth)
                        }
                    }
                } header: {
                    breadcrumb
                }
            }
        }
        .listStyle(.insetGrouped)
        .jbForm()
        .animation(JB.smooth, value: rows.map(\.path))
        .navigationTitle("Files")
        .navigationBarTitleDisplayMode(.inline)
        .refreshable { await store.load() }
        .task { await store.load() }
        .toolbar {
            ToolbarItem(placement: .topBarTrailing) {
                Button {
                    showBind = true
                } label: {
                    Image(systemName: "folder.badge.gearshape")
                        .foregroundStyle(JB.ink)
                }
                .accessibilityLabel("Change bound folder")
            }
        }
        .sheet(isPresented: $showBind) {
            FolderPickerView(api: api) { path in
                Task {
                    do {
                        try await api.bindWorkdir(session: store.sessionID, path: path)
                        await store.load()
                    } catch { store.error = error.localizedDescription }
                }
            }
        }
        .navigationDestination(item: $openFile) { sub in
            DocumentEditorView(api: api,
                               source: .workdir(session: store.sessionID, sub: sub),
                               fallbackTitle: (sub as NSString).lastPathComponent)
        }
        .quickLookPreview($previewURL)
        .onChange(of: previewURL) { oldURL, newURL in
            if newURL == nil, let oldURL { try? FileManager.default.removeItem(at: oldURL) }
        }
        .alert("Rename", isPresented: Binding(
            get: { renameTarget != nil }, set: { if !$0 { renameTarget = nil } })) {
            TextField("Name", text: $renameName)
                .textInputAutocapitalization(.never)
                .autocorrectionDisabled()
            Button("Cancel", role: .cancel) { renameTarget = nil }
            Button("Rename") {
                if let sub = renameTarget { Task { await store.rename(sub, to: renameName) } }
                renameTarget = nil
            }
        } message: {
            Text("Renames the file on the backend host.")
        }
        .alert(deleteTitle, isPresented: Binding(
            get: { deleteTarget != nil }, set: { if !$0 { deleteTarget = nil } })) {
            Button("Delete", role: .destructive) {
                if let sub = deleteTarget { Task { await store.delete(sub) } }
                deleteTarget = nil
            }
            Button("Cancel", role: .cancel) { deleteTarget = nil }
        } message: { Text(deleteMessage) }
        .alert("Files", isPresented: Binding(
            get: { store.error != nil }, set: { if !$0 { store.error = nil } })) {
            Button("OK") { store.error = nil }
        } message: { Text(store.error ?? "") }
    }

    // MARK: Header

    /// Where these files actually live, so the tree is never ambiguous.
    private var breadcrumb: some View {
        VStack(alignment: .leading, spacing: 2) {
            HStack(spacing: 6) {
                Image(systemName: "folder")
                    .font(.jbCaption)
                    .foregroundStyle(JB.ink2)
                Text(rootName)
                    .font(.jb(12, .medium))
                    .foregroundStyle(JB.ink)
                Spacer(minLength: 4)
                Text("\(store.entries(at: "").count)")
                    .font(.jb(10.5))
                    .foregroundStyle(JB.ink3)
            }
            if !rootParent.isEmpty {
                Text(rootParent)
                    .font(.jb(10.5))
                    .foregroundStyle(JB.ink3)
                    .lineLimit(1)
                    .truncationMode(.head)
            }
        }
        .textCase(nil)
        .padding(.bottom, 2)
        .accessibilityElement(children: .combine)
        .accessibilityLabel("Bound folder \(store.root ?? "")")
    }

    private var rootName: String {
        let name = ((store.root ?? "") as NSString).lastPathComponent
        return name.isEmpty ? (store.root ?? "") : name
    }

    private var rootParent: String {
        ((store.root ?? "") as NSString).deletingLastPathComponent
    }

    // MARK: Tree

    /// The backend lists one level at a time, so a folder's children only
    /// exist once it has been expanded. Flattened iteratively rather than with
    /// a recursive ViewBuilder, whose return type cannot be inferred.
    private var rows: [(entry: JBWorkdirEntry, path: String, depth: Int)] {
        var out: [(JBWorkdirEntry, String, Int)] = []
        func walk(_ sub: String, _ depth: Int) {
            for entry in store.entries(at: sub) {
                let path = sub.isEmpty ? entry.name : sub + "/" + entry.name
                out.append((entry, path, depth))
                if entry.isDir && store.expanded.contains(path) { walk(path, depth + 1) }
            }
        }
        walk("", 0)
        return out
    }

    private func row(_ entry: JBWorkdirEntry, path: String, depth: Int) -> some View {
        Button {
            if entry.isDir { Task { await store.toggle(path) } } else { open(path) }
        } label: {
            WorkdirRow(entry: entry,
                       depth: depth,
                       icon: icon(entry, path: path),
                       expanded: store.expanded.contains(path),
                       busy: store.loadingSub == path || store.downloading == path)
        }
        .buttonStyle(.plain)
        .listRowBackground(JB.panelFill)
        .contextMenu {
            if !entry.isDir, case .text = JBFileKind.of(entry.name) {
                Button("Open in editor", systemImage: "square.and.pencil") { openFile = path }
            }
            Button("Rename", systemImage: "pencil") {
                renameName = entry.name
                renameTarget = path
            }
            Button("Delete", systemImage: "trash", role: .destructive) { deleteTarget = path }
        }
        .swipeActions(edge: .trailing, allowsFullSwipe: false) {
            Button("Delete", systemImage: "trash", role: .destructive) { deleteTarget = path }
            Button("Rename", systemImage: "pencil") {
                renameName = entry.name
                renameTarget = path
            }
            .tint(JB.ink3)
        }
    }

    private func icon(_ entry: JBWorkdirEntry, path: String) -> String {
        guard !entry.isDir else {
            return "folder"
        }
        switch JBFileKind.of(entry.name) {
        case .image: return "photo"
        case .pdf: return "doc.richtext"
        case .spreadsheet: return "tablecells"
        case .flashcards: return "rectangle.on.rectangle"
        case .unsupported: return "doc"
        case .text: return "doc.text"
        }
    }

    // MARK: Opening

    /// Text goes to the editor. Everything else is downloaded and handed to
    /// QuickLook — there is no in-app editor for those formats on iOS. The
    /// download reports progress on the row and surfaces its own failure.
    private func open(_ path: String) {
        switch JBFileKind.of((path as NSString).lastPathComponent) {
        case .text:
            openFile = path
        case .image, .pdf, .spreadsheet, .flashcards, .unsupported:
            guard store.downloading == nil else { return }
            Task { previewURL = await store.preview(path) }
        }
    }

    // MARK: Confirmation copy

    private var deleteTitle: String {
        guard let target = deleteTarget else { return "Delete?" }
        return "Delete \"\((target as NSString).lastPathComponent)\"?"
    }

    private var deleteMessage: String {
        guard let target = deleteTarget else { return "" }
        let isDir = rows.first { $0.path == target }?.entry.isDir == true
        return isDir
            ? "Deletes the folder and everything inside it on the backend host."
            : "Deletes the file on the backend host."
    }

    // MARK: States

    private var loadingState: some View {
        JBSpinner()
            .frame(maxWidth: .infinity).padding(.vertical, 36)
            .listRowBackground(Color.clear)
    }

    private var emptyFolderState: some View {
        empty("tray", "Empty folder")
    }

    private var unboundState: some View {
        VStack(spacing: 12) {
            Text(JBEmptyState.drawing(.files)).font(.jb(12)).foregroundStyle(JB.ink3).fixedSize()
            Text("No folder bound").font(.jb(13)).foregroundStyle(JB.ink2)
            Button("Choose folder") { showBind = true }
                .buttonStyle(.jbPrimary)
                .padding(.top, 4)
        }
        .frame(maxWidth: .infinity).padding(.vertical, 36)
        .listRowBackground(Color.clear)
    }
}

/// One line of the tree. Folders carry a rotating disclosure chevron and a
/// tinted folder glyph; files are dimmer and show where tapping leads.
private struct WorkdirRow: View {
    let entry: JBWorkdirEntry
    let depth: Int
    let icon: String
    let expanded: Bool
    let busy: Bool

    var body: some View {
        HStack(spacing: 8) {
            if depth > 0 {
                HStack(spacing: 0) {
                    ForEach(0..<depth, id: \.self) { _ in
                        Rectangle().fill(JB.line).frame(width: 1)
                            .padding(.leading, 7).padding(.trailing, 8)
                    }
                }
                .frame(height: 26)
            }
            disclosure
            glyph
            Text(entry.name)
                .font(entry.isDir ? .jb(15, .medium) : .jb(13.5))
                .lineLimit(1)
                .truncationMode(.middle)
                .foregroundStyle(entry.isDir ? JB.ink : JB.ink.opacity(0.88))
            Spacer(minLength: 4)
            trailing
        }
        .frame(minHeight: 44)
        .contentShape(Rectangle())
        .accessibilityLabel(entry.isDir
            ? "\(entry.name), folder, \(expanded ? "expanded" : "collapsed")"
            : "\(entry.name), file")
    }

    @ViewBuilder
    private var disclosure: some View {
        if entry.isDir {
            Image(systemName: "chevron.right")
                .font(.jb(10, .bold))
                .foregroundStyle(JB.ink.opacity(0.55))
                .rotationEffect(.degrees(expanded ? 90 : 0))
                .animation(.snappy(duration: 0.2), value: expanded)
                .frame(width: 12)
        } else {
            Spacer().frame(width: 12)
        }
    }

    @ViewBuilder
    private var glyph: some View {
        if busy {
            JBSpinner(size: 10).frame(width: 20)
        } else {
            Image(systemName: icon)
                .font(.jb(14))
                .foregroundStyle(entry.isDir ? JB.ink2 : JB.ink3)
                .frame(width: 20)
        }
    }

    @ViewBuilder
    private var trailing: some View {
        if entry.isDir {
            EmptyView()
        } else {
            switch JBFileKind.of(entry.name) {
            case .text:
                Image(systemName: "chevron.right")
                    .font(.jb(10, .bold)).foregroundStyle(JB.ink.opacity(0.3))
            default:
                Image(systemName: "eye")
                    .font(.jb(11)).foregroundStyle(JB.ink.opacity(0.35))
            }
        }
    }
}

/// Browses directories on the backend host to bind one to a chat. The Mac's
/// "this device" branch is deliberately absent — iOS has no filesystem to offer.
struct FolderPickerView: View {
    let api: JoeBroAPI
    var onPick: (String) -> Void
    @Environment(\.dismiss) private var dismiss
    @State private var path = ""
    @State private var entries: [JBWorkdirEntry] = []
    @State private var loading = false
    @State private var error: String?

    var body: some View {
        NavigationStack {
            List {
                if !path.isEmpty {
                    Button("..", systemImage: "arrow.up.left") {
                        path = (path as NSString).deletingLastPathComponent
                        Task { await load() }
                    }
                    .listRowBackground(JB.panelFill)
                }
                ForEach(entries) { entry in
                    Button {
                        path = path.isEmpty ? entry.name : path + "/" + entry.name
                        Task { await load() }
                    } label: {
                        Label(entry.name, systemImage: "folder")
                            .frame(minHeight: 44)
                    }
                    .buttonStyle(.plain)
                    .listRowBackground(JB.panelFill)
                }
                if entries.isEmpty && !loading {
                    Text("No subfolders").font(.jb(12)).foregroundStyle(JB.ink3)
                        .listRowBackground(Color.clear)
                }
            }
            .listStyle(.insetGrouped)
            .jbForm()
            .overlay { if loading { JBSpinner() } }
            .navigationTitle(path.isEmpty ? "Choose folder" : path)
            .navigationBarTitleDisplayMode(.inline)
            .toolbar {
                ToolbarItem(placement: .topBarLeading) { Button("Cancel") { dismiss() } }
                ToolbarItem(placement: .topBarTrailing) {
                    Button("Bind") { onPick(path); dismiss() }
                        .disabled(path.isEmpty)
                }
            }
            .task { await load() }
            .alert("Browse", isPresented: Binding(
                get: { error != nil }, set: { if !$0 { error = nil } })) {
                Button("OK") { error = nil }
            } message: { Text(error ?? "") }
        }
    }

    private func load() async {
        loading = true
        defer { loading = false }
        do {
            let location = try await api.workspaceBrowseLocation(path: path)
            path = location.path
            entries = location.entries
            error = nil
        }
        catch { self.error = error.localizedDescription }
    }
}

private struct WorkspaceBrowseLocation: Decodable {
    let path: String
    let entries: [JBWorkdirEntry]
}

extension JoeBroAPI {
    func workspaceBrowseLocation(path: String) async throws -> (path: String, entries: [JBWorkdirEntry]) {
        let result = try await fetch(WorkspaceBrowseLocation.self, "api/fs/browse",
                                     query: path.isEmpty ? [] : [URLQueryItem(name: "path", value: path)])
        return (result.path, result.entries)
    }
}
