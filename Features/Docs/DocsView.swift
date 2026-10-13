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
                    .listRowBackground(Color.white.opacity(0.06))
                    .swipeActions(edge: .trailing, allowsFullSwipe: false) {
                        Button("Archive", systemImage: "archivebox", role: .destructive) { deleteTarget = doc }
                    }
            }
        }
        .listStyle(.insetGrouped)
        .scrollContentBackground(.hidden)
        .jbWallpaper()
        .searchable(text: Bindable(store).search, prompt: "Search documents")
        .onChange(of: store.search) { _, _ in Task { await store.loadLibrary() } }
        .navigationTitle("Documents")
        .refreshable { await store.loadLibrary() }
        .task { if store.library.isEmpty { await store.loadLibrary() } }
        .toolbar {
            ToolbarItem(placement: .topBarTrailing) {
                Button {
                    Task { if let doc = await store.createDocument() { newDocID = doc.id } }
                } label: {
                    Image(systemName: "square.and.pencil").foregroundStyle(Color.accentTint)
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
            Text("It leaves this list and JoeBro stops offering it. The backend keeps the file and its versions — nothing is erased.")
        }
        .alert("Documents", isPresented: Binding(
            get: { store.error != nil }, set: { if !$0 { store.error = nil } })) {
            Button("OK") { store.error = nil }
        } message: { Text(store.error ?? "") }
    }

    private func row(_ doc: JBDocSummary) -> some View {
        HStack(spacing: 12) {
            Image(systemName: icon(doc.language))
                .foregroundStyle(.white.opacity(0.6)).frame(width: 20)
            VStack(alignment: .leading, spacing: 2) {
                Text(doc.displayTitle).lineLimit(1).foregroundStyle(.white)
                if let updated = doc.updatedAt, !updated.isEmpty {
                    Text(updated.prefix(16).replacingOccurrences(of: "T", with: " "))
                        .font(.caption2).foregroundStyle(.secondary)
                }
            }
            Spacer(minLength: 6)
            Image(systemName: "chevron.right").font(.caption2.bold()).foregroundStyle(.tertiary)
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
        HStack(spacing: 10) {
            ProgressView().tint(.white)
            Text("Loading documents…").font(.footnote).foregroundStyle(.secondary)
        }
        .frame(maxWidth: .infinity).padding(.vertical, 40)
        .listRowBackground(Color.clear)
    }

    private var emptyState: some View {
        VStack(spacing: 10) {
            Image(systemName: "doc.text").font(.largeTitle).foregroundStyle(.secondary)
            Text("No documents").font(.headline)
            Text("Anything JoeBro writes lands here, or tap the pencil to start one.")
                .font(.footnote).foregroundStyle(.secondary).multilineTextAlignment(.center)
        }
        .frame(maxWidth: .infinity).padding(.vertical, 40)
        .listRowBackground(Color.clear)
    }
}
