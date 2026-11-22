import SwiftUI

/// The document library: every doc on the backend, searchable, openable and
/// editable. Reachable from the Workspace tab and from inside a chat.
struct DocsView: View {
    let api: JoeBroAPI
    @State private var store: DocsStore
    @State private var openDoc: JBDocSummary?
    @State private var newDocID: String?
    @State private var deleteTarget: JBDocSummary?

    init(api: JoeBroAPI) {
        self.api = api
        _store = State(initialValue: DocsStore(api: api))
    }

    var body: some View {
        List {
            if store.library.isEmpty {
                if store.loading { loadingState } else { emptyState }
            }
            ForEach(store.library) { doc in
                Button { openDoc = doc } label: { row(doc) }
                    .buttonStyle(.plain)
                    .listRowBackground(JB.panelFill)
                    .swipeActions(edge: .trailing, allowsFullSwipe: false) {
                        Button("Archive", systemImage: "archivebox", role: .destructive) { deleteTarget = doc }
                    }
            }
        }
        .listStyle(.insetGrouped)
        .animation(JB.smooth, value: store.library.map(\.id))
        .jbForm()
        .searchable(text: Bindable(store).search, prompt: "Search")
        .onChange(of: store.search) { _, _ in Task { await store.loadLibrary() } }
        .navigationTitle("Documents")
        .refreshable { await store.loadLibrary() }
        .task { if store.library.isEmpty { await store.loadLibrary() } }
        .toolbar {
            ToolbarItem(placement: .topBarTrailing) {
                Button {
                    Task { if let doc = await store.createDocument() { newDocID = doc.id } }
                } label: {
                    Image(systemName: "square.and.pencil").foregroundStyle(JB.ink)
                }
                .accessibilityLabel("New document")
                .disabled(store.loading)
            }
        }
        .navigationDestination(item: $openDoc) { doc in
            DocumentEditorView(api: api, source: .library(id: doc.id), fallbackTitle: doc.displayTitle)
        }
        .navigationDestination(item: $newDocID) { id in
            DocumentEditorView(api: api, source: .library(id: id),
                               fallbackTitle: "Untitled", mode: .edit)
        }
        .alert(deleteTarget.map { "Archive \"\($0.displayTitle)\"?" } ?? "Archive?",
                            isPresented: Binding(
            get: { deleteTarget != nil }, set: { if !$0 { deleteTarget = nil } })) {
            Button("Archive", role: .destructive) {
                if let id = deleteTarget?.id { Task { await store.delete(id) } }
                deleteTarget = nil
            }
            Button("Cancel", role: .cancel) { deleteTarget = nil }
        } message: {
            Text("The backend keeps the file and its versions.")
        }
        .alert("Documents", isPresented: Binding(
            get: { store.error != nil }, set: { if !$0 { store.error = nil } })) {
            Button("OK") { store.error = nil }
        } message: { Text(store.error ?? "") }
    }

    private func row(_ doc: JBDocSummary) -> some View {
        HStack(spacing: 12) {
            Image(systemName: icon(doc.language))
                .font(.jb(15)).foregroundStyle(JB.ink3).frame(width: 20)
            Text(doc.displayTitle).font(.jb(15)).lineLimit(1).foregroundStyle(JB.ink)
            Spacer(minLength: 6)
            if let updated = doc.updatedAt, !updated.isEmpty {
                Text(updated.prefix(10))
                    .font(.jb(10.5)).foregroundStyle(JB.ink3)
            }
        }
        .frame(minHeight: 44)
        .contentShape(Rectangle())
    }

    private func icon(_ language: String?) -> String {
        switch language {
        case "markdown", "md", nil: "doc.text"
        case "image": "photo"
        case "pdf": "doc.richtext"
        default: "chevron.left.forwardslash.chevron.right"
        }
    }

    private var loadingState: some View {
        JBSpinner()
            .frame(maxWidth: .infinity).padding(.vertical, 40)
            .listRowBackground(Color.clear)
    }

    private var emptyState: some View {
        empty("doc.text", "No documents")
    }
}
