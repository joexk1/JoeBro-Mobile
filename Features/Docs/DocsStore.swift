import SwiftUI

/// Backs both document surfaces. The library is global and flat — backend
/// `documents` rows, no session and no folder. A chat's bound folder is real
/// files on the backend host, addressed by path relative to the folder root.
@MainActor
@Observable final class DocsStore {
    let api: JoeBroAPI
    var library: [JBDocSummary] = []
    var search = ""
    var loading = false
    var error: String?

    init(api: JoeBroAPI) { self.api = api }

    func loadLibrary() async {
        loading = true
        defer { loading = false }
        do {
            library = try await api.documents(search: search).filter { $0.archived != true }
            error = nil
        } catch { self.error = error.localizedDescription }
    }

    func createDocument() async -> JBDocDetail? {
        do {
            let doc = try await api.createDocument(title: "Untitled", content: "")
            await loadLibrary()
            return doc
        } catch { self.error = error.localizedDescription; return nil }
    }

    func delete(_ id: String) async {
        do {
            try await api.deleteDocument(id)
            library.removeAll { $0.id == id }
        } catch { self.error = error.localizedDescription }
    }
}

/// One open document. Covers a library row and a bound-folder file, which save
/// through different routes — a workdir file has a synthetic id with no library
/// row, so PUT /api/document would 404 on it.
@MainActor
@Observable final class DocumentEditorStore {
    enum Source: Equatable {
        case library(id: String)
        case workdir(session: String, sub: String)
    }

    let api: JoeBroAPI
    let source: Source
    var title = ""
    var text = ""
    var language = "markdown"
    var loading = true
    var saving = false
    var dirty = false
    var savedAt: Date?
    /// Set only when the initial load failed, so a failed *save* never
    /// replaces the editor (and the buffer in it) with an error screen.
    var loadFailed = false
    var error: String?
    private var autosave: Task<Void, Never>?
    private var lastSavedText = ""
    private var lastSavedTitle = ""

    init(api: JoeBroAPI, source: Source) {
        self.api = api
        self.source = source
    }

    var isLibrary: Bool {
        if case .library = source { return true }
        return false
    }

    var isMarkdown: Bool {
        if case .workdir(_, let sub) = source,
           ["md", "markdown"].contains((sub as NSString).pathExtension.lowercased()) { return true }
        return ["markdown", "md"].contains(language.lowercased())
    }

    var isMonospaced: Bool {
        if case .workdir(_, let sub) = source { return JBFileKind.of(sub).isMonospaced }
        return !["markdown", "md", "text", ""].contains(language)
    }

    func load() async {
        autosave?.cancel()
        loading = true
        defer { loading = false }
        do {
            let doc: JBDocDetail
            switch source {
            case .library(let id): doc = try await api.document(id)
            case .workdir(let session, let sub): doc = try await api.openWorkdirFile(session: session, sub: sub)
            }
            title = doc.title ?? ""
            text = doc.text
            lastSavedText = doc.text
            lastSavedTitle = doc.title ?? ""
            language = doc.language ?? "markdown"
            dirty = false
            loadFailed = false
            error = nil
        } catch {
            self.error = error.localizedDescription
            loadFailed = true
        }
    }

    /// Words and characters for the status bar. Counting is skipped on very
    /// large files so it cannot cost a frame per keystroke.
    var countSummary: String {
        let chars = text.count
        guard chars <= 120_000 else { return "\(chars) characters" }
        let words = text.split(whereSeparator: { $0 == " " || $0.isNewline || $0 == "\t" }).count
        return "\(words) word\(words == 1 ? "" : "s") · \(chars) characters"
    }

    /// Saves now instead of in two seconds. Called when the Edit / View switch
    /// flips and when the editor goes away; the buffer itself survives either
    /// way, since it lives here and not in a view.
    func flush() async {
        autosave?.cancel()
        autosave = nil
        await save()
    }

    /// Debounced so typing doesn't fire a request per keystroke.
    func titleChanged() { textChanged() }

    func textChanged() {
        if text == lastSavedText && title == lastSavedTitle {
            autosave?.cancel()
            dirty = false
            return
        }
        dirty = true
        autosave?.cancel()
        autosave = Task {
            try? await Task.sleep(for: .seconds(2))
            guard !Task.isCancelled else { return }
            await save()
        }
    }

    func save() async {
        guard dirty, !saving else { return }
        saving = true
        defer { saving = false }
        while dirty {
            let savingText = text
            let savingTitle = title
            do {
                switch source {
                case .library(let id):
                    _ = try await api.updateDocument(id, content: savingText,
                                                     title: savingTitle.isEmpty ? nil : savingTitle)
                case .workdir(let session, let sub):
                    try await api.saveWorkdirFile(session: session, sub: sub, content: savingText)
                }
                lastSavedText = savingText
                lastSavedTitle = savingTitle
                dirty = text != lastSavedText || title != lastSavedTitle
                if !dirty {
                    savedAt = .now
                    error = nil
                }
            } catch {
                self.error = error.localizedDescription
                return
            }
        }
    }
}

/// The file tree of a chat's bound folder, expanded one level at a time to
/// match the backend's single-level list route.
@MainActor
@Observable final class WorkdirStore {
    let api: JoeBroAPI
    let sessionID: String
    var root: String?
    var children: [String: [JBWorkdirEntry]] = [:]
    var expanded: Set<String> = []
    var loading = false
    /// The folder whose level is being fetched, and the file being downloaded
    /// for QuickLook — each shows a spinner on its own row.
    var loadingSub: String?
    var downloading: String?
    var error: String?

    init(api: JoeBroAPI, sessionID: String) {
        self.api = api
        self.sessionID = sessionID
    }

    func load() async {
        loading = true
        defer { loading = false }
        do {
            root = try await api.workdir(session: sessionID)
            error = nil
            guard root?.isEmpty == false else {
                children = [:]
                expanded = []
                return
            }
            children[""] = try await api.workdirList(session: sessionID)
        } catch { self.error = error.localizedDescription }
    }

    func entries(at sub: String) -> [JBWorkdirEntry] {
        (children[sub] ?? []).sorted {
            $0.isDir == $1.isDir ? $0.name.localizedCaseInsensitiveCompare($1.name) == .orderedAscending : $0.isDir
        }
    }

    /// Expanding a folder has to fetch its level first, so the animation is
    /// applied to the mutation that actually adds rows.
    func toggle(_ sub: String) async {
        if expanded.contains(sub) {
            _ = withAnimation(.snappy(duration: 0.22)) { expanded.remove(sub) }
            return
        }
        guard children[sub] == nil else {
            _ = withAnimation(.snappy(duration: 0.22)) { expanded.insert(sub) }
            return
        }
        loadingSub = sub
        defer { loadingSub = nil }
        do {
            let listing = try await api.workdirList(session: sessionID, sub: sub)
            withAnimation(.snappy(duration: 0.22)) {
                children[sub] = listing
                expanded.insert(sub)
            }
        } catch { self.error = error.localizedDescription }
    }

    /// Non-text files have no preview route, so they are downloaded whole into
    /// a temporary file for QuickLook. `downloading` drives a real spinner on
    /// the row instead of the tap looking like it did nothing.
    func preview(_ sub: String) async -> URL? {
        downloading = sub
        defer { downloading = nil }
        do {
            let data = try await api.workdirRaw(session: sessionID, sub: sub)
            guard !data.isEmpty else {
                self.error = "\((sub as NSString).lastPathComponent) is empty — nothing to preview."
                return nil
            }
            let url = FileManager.default.temporaryDirectory
                .appendingPathComponent(UUID().uuidString + "-" + (sub as NSString).lastPathComponent)
            try data.write(to: url, options: [.atomic, .completeFileProtection])
            return url
        } catch {
            self.error = "Couldn't download \((sub as NSString).lastPathComponent): \(error.localizedDescription)"
            return nil
        }
    }

    func rename(_ sub: String, to newName: String) async {
        let clean = newName.trimmingCharacters(in: .whitespacesAndNewlines)
        guard !clean.isEmpty else { return }
        guard !clean.contains("/") else {
            self.error = "A name can't contain a slash — rename only moves within the same folder."
            return
        }
        do {
            try await api.renameWorkdirFile(session: sessionID, sub: sub, newName: clean)
            await reload(parentOf: sub)
        } catch { self.error = error.localizedDescription }
    }

    func delete(_ sub: String) async {
        do {
            try await api.deleteWorkdirFile(session: sessionID, sub: sub)
            await reload(parentOf: sub)
        } catch { self.error = error.localizedDescription }
    }

    private func reload(parentOf sub: String) async {
        let parent = (sub as NSString).deletingLastPathComponent
        do {
            let listing = try await api.workdirList(session: sessionID, sub: parent)
            withAnimation(.snappy(duration: 0.22)) { children[parent] = listing }
        } catch { self.error = error.localizedDescription }
    }
}
