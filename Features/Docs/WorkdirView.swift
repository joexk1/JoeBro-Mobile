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
        .scrollContentBackground(.hidden)
        .jbWallpaper()
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
                        .foregroundStyle(Color.accentTint)
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
            Text("Renames the file on the backend host. Anything referring to it by its old name will stop finding it.")
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
                Image(systemName: "folder.fill")
                    .font(.caption)
                    .foregroundStyle(Color.accentTint)
                Text(rootName)
                    .font(.subheadline.weight(.semibold))
                    .foregroundStyle(.white)
                Spacer(minLength: 4)
                Text("\(store.entries(at: "").count) items")
                    .font(.caption2)
                    .foregroundStyle(.secondary)
            }
            if !rootParent.isEmpty {
                Text(rootParent)
                    .font(.caption2)
                    .foregroundStyle(.secondary)
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
        .listRowBackground(Color.white.opacity(0.06))
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
            .tint(Color.accentTint)
        }
    }

    private func icon(_ entry: JBWorkdirEntry, path: String) -> String {
        guard !entry.isDir else {
            return store.expanded.contains(path) ? "folder.fill" : "folder"
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
            ? "Deletes the folder and everything inside it on the backend host. This cannot be undone from the app."
            : "Deletes the file on the backend host. This cannot be undone from the app."
    }

    // MARK: States

    private var loadingState: some View {
        HStack(spacing: 10) {
            ProgressView().tint(.white)
            Text("Reading the bound folder…").font(.footnote).foregroundStyle(.secondary)
        }
        .frame(maxWidth: .infinity).padding(.vertical, 36)
        .listRowBackground(Color.clear)
    }

    private var emptyFolderState: some View {
        VStack(spacing: 6) {
            Image(systemName: "tray").font(.title2).foregroundStyle(.secondary)
            Text("This folder is empty").font(.subheadline).foregroundStyle(.white)
            Text("Ask JoeBro to write a file here, or pull to refresh.")
                .font(.footnote).foregroundStyle(.secondary).multilineTextAlignment(.center)
        }
        .frame(maxWidth: .infinity).padding(.vertical, 28)
        .listRowBackground(Color.clear)
    }

    private var unboundState: some View {
        VStack(spacing: 10) {
            Image(systemName: "folder.badge.questionmark").font(.largeTitle).foregroundStyle(.secondary)
            Text("No folder bound").font(.headline).foregroundStyle(.white)
            Text("Bind a folder on the backend machine and JoeBro's file tools work inside it.")
                .font(.footnote).foregroundStyle(.secondary).multilineTextAlignment(.center)
            Button("Choose folder") { showBind = true }
                .buttonStyle(.borderedProminent)
                .tint(Color.accentTint)
                .foregroundStyle(.black)
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
                        Rectangle().fill(.white.opacity(0.12)).frame(width: 1)
                            .padding(.leading, 7).padding(.trailing, 8)
                    }
                }
                .frame(height: 26)
            }
            disclosure
            glyph
            Text(entry.name)
                .font(entry.isDir ? .body.weight(.medium) : .body)
                .lineLimit(1)
                .truncationMode(.middle)
                .foregroundStyle(entry.isDir ? .white : .white.opacity(0.88))
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
                .font(.system(size: 10, weight: .bold))
                .foregroundStyle(.white.opacity(0.55))
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
            ProgressView().controlSize(.mini).tint(.white).frame(width: 20)
        } else {
            Image(systemName: icon)
                .font(.system(size: 14))
                .foregroundStyle(entry.isDir ? Color.accentTint : .white.opacity(0.5))
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
                    .font(.system(size: 10, weight: .bold)).foregroundStyle(.white.opacity(0.3))
            default:
                Image(systemName: "eye")
                    .font(.system(size: 11)).foregroundStyle(.white.opacity(0.35))
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
                    .listRowBackground(Color.white.opacity(0.06))
                }
                ForEach(entries) { entry in
                    Button {
                        path = path.isEmpty ? entry.name : path + "/" + entry.name
                        Task { await load() }
                    } label: {
                        Label(entry.name, systemImage: "folder.fill")
                            .frame(minHeight: 44)
                    }
                    .buttonStyle(.plain)
                    .listRowBackground(Color.white.opacity(0.06))
                }
                if entries.isEmpty && !loading {
                    Text("No subfolders here.").foregroundStyle(.secondary)
                        .listRowBackground(Color.clear)
                }
            }
            .listStyle(.insetGrouped)
            .scrollContentBackground(.hidden)
            .jbWallpaper()
            .overlay { if loading { ProgressView().tint(.white) } }
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
