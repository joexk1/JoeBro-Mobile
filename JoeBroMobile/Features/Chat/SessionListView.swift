import SwiftUI

/// The chat list, grouped into project folders exactly as the Mac sidebar does:
/// pinned folders first, then case-insensitive by name, collapsible, with
/// ungrouped chats last. Moving a chat is a menu action rather than the Mac's
/// drag-and-drop — there is no hover-to-expand on a phone to copy.
struct SessionListView: View {
    @Environment(\.accessibilityReduceMotion) private var reduceMotion
    let store: ChatStore
    /// Called when a chat is chosen, so the container can push the transcript.
    var onOpen: (JBSession) -> Void
    var onNewChat: () -> Void = {}

    @State private var search = ""
    @State private var renameTargetID: String?
    @State private var renameName = ""
    @State private var deleteTargetID: String?
    @State private var folderRenameTarget: String?
    @State private var folderRenameName = ""
    @State private var folderDeleteTarget: String?
    @State private var newFolderTargetID: String?
    @State private var newFolderName = ""
    @State private var symbolsReady = false

    private var ungrouped: [JBSession] { store.sessions(inFolder: "", search: search) }

    /// A search collapses nothing — you want to see every hit.
    private func isExpanded(_ folder: String) -> Bool {
        !search.isEmpty || !store.collapsedFolders.contains(folder)
    }

    var body: some View {
        List {
            folderSections
            if !ungrouped.isEmpty {
                Section(store.folderNames.isEmpty ? "" : "Chats") {
                    ForEach(ungrouped) { session in
                        row(session)
                    }
                }
            }
            if store.sessions.isEmpty { emptyState }
        }
        .listStyle(.insetGrouped)
        .scrollContentBackground(.hidden)
        .animation(reduceMotion ? nil : .easeInOut(duration: 0.24),
                   value: store.sessions.map { "\($0.id):\($0.isImportant == true):\($0.folderKey)" })
        .animation(reduceMotion ? nil : .easeInOut(duration: 0.24), value: store.pinnedFolders)
        // searchable must stay attached to the List itself — attaching it to
        // the wallpaper's ZStack wrapper blanked the whole window.
        .searchable(text: $search, placement: .navigationBarDrawer(displayMode: .always), prompt: "Search chats")
        .jbWallpaper()
        .navigationTitle("Chats")
        .navigationBarTitleDisplayMode(.inline)
        .refreshable { await store.reloadSessions() }
        .onAppear { symbolsReady = true }
        .toolbar {
            ToolbarItem(placement: .topBarTrailing) {
                Button { Task { await store.newChat(); onNewChat() } } label: {
                    Image(systemName: "square.and.pencil")
                        .font(.system(size: 18, weight: .medium))
                        .foregroundStyle(Color.accentTint)
                        .frame(width: 44, height: 44, alignment: .center)
                }
                .accessibilityLabel("New chat")
            }
        }
        .modifier(SessionListDialogs(
            store: store, search: $search,
            renameTargetID: $renameTargetID, renameName: $renameName,
            deleteTargetID: $deleteTargetID,
            folderRenameTarget: $folderRenameTarget, folderRenameName: $folderRenameName,
            folderDeleteTarget: $folderDeleteTarget,
            newFolderTargetID: $newFolderTargetID, newFolderName: $newFolderName))
    }

    // Each folder is one section whose *first row* is the header. A `Button`
    // placed in an inset-grouped Section's `header:` never reliably receives
    // the tap, which is why collapsing appeared to do nothing; as a normal
    // row it is an ordinary, hit-testable control.
    @ViewBuilder
    private var folderSections: some View {
        ForEach(store.folderNames, id: \.self) { folder in
            Section {
                folderHeaderRow(folder)
                if isExpanded(folder) {
                    ForEach(store.sessions(inFolder: folder, search: search)) { session in
                        row(session)
                    }
                }
            }
        }
    }

    private func folderHeaderRow(_ folder: String) -> some View {
        let collapsed = !isExpanded(folder)
        let count = store.sessions(inFolder: folder, search: search).count
        return Button {
            withAnimation(reduceMotion ? nil : .easeInOut(duration: 0.2)) { store.toggleCollapsed(folder) }
        } label: {
            HStack(spacing: 10) {
                Image(systemName: "chevron.right")
                    .font(.caption.bold())
                    .foregroundStyle(.white.opacity(0.65))
                    .rotationEffect(.degrees(collapsed ? 0 : 90))
                    .frame(width: 12)
                Image(systemName: collapsed ? "folder.fill" : "folder")
                    .foregroundStyle(.accentTint)
                    .scaleEffect(reduceMotion || symbolsReady ? 1 : 0.92)
                    .opacity(reduceMotion || symbolsReady ? 1 : 0.75)
                    .animation(reduceMotion ? nil : .easeOut(duration: 0.18), value: symbolsReady)
                Text(folder).lineLimit(1).foregroundStyle(.white)
                if store.pinnedFolders.contains(folder) {
                    Image(systemName: "pin.fill").font(.caption2).foregroundStyle(.orange)
                }
                Spacer(minLength: 6)
                Text("\(count)")
                    .font(.caption.weight(.semibold))
                    .foregroundStyle(.white.opacity(0.7))
                    .padding(.horizontal, 8).padding(.vertical, 2)
                    .background(.white.opacity(0.12), in: Capsule())
            }
            .font(.subheadline.weight(.semibold))
            .frame(minHeight: 44)
            .contentShape(Rectangle())
        }
        .buttonStyle(SessionPressStyle(reduceMotion: reduceMotion))
        .listRowBackground(Color.white.opacity(0.12))
        .accessibilityLabel("Folder \(folder), \(count) chats")
        .accessibilityValue("\(store.pinnedFolders.contains(folder) ? "Pinned, " : "")\(collapsed ? "collapsed" : "expanded")")
        .accessibilityHint(collapsed ? "Expands the folder" : "Collapses the folder")
        .swipeActions(edge: .leading, allowsFullSwipe: false) {
            Button(store.pinnedFolders.contains(folder) ? "Unpin" : "Pin",
                   systemImage: store.pinnedFolders.contains(folder) ? "pin.slash" : "pin.fill") {
                pinFolderAfterGesture(folder)
            }
            .tint(.orange)
        }
        .swipeActions(edge: .trailing, allowsFullSwipe: false) {
            Button("Delete folder", systemImage: "trash", role: .destructive) { folderDeleteTarget = folder }
            Button("Rename", systemImage: "pencil") {
                folderRenameName = folder
                folderRenameTarget = folder
            }
            .tint(.indigo)
        }
        .contextMenu { folderMenu(folder) }
    }

    // Swipe actions and the context menu offer the same things, in the same
    // words, so neither surface is a surprise.
    @ViewBuilder
    private func folderMenu(_ folder: String) -> some View {
        Button(isExpanded(folder) ? "Collapse folder" : "Expand folder",
               systemImage: isExpanded(folder) ? "chevron.up" : "chevron.down") {
            withAnimation(reduceMotion ? nil : .easeInOut(duration: 0.2)) { store.toggleCollapsed(folder) }
        }
        Button("Rename folder", systemImage: "pencil") {
            folderRenameName = folder
            folderRenameTarget = folder
        }
        Button(store.pinnedFolders.contains(folder) ? "Unpin folder" : "Pin folder",
               systemImage: store.pinnedFolders.contains(folder) ? "pin.slash" : "pin") {
            pinFolderAfterGesture(folder)
        }
        Button("Delete folder", systemImage: "trash", role: .destructive) { folderDeleteTarget = folder }
    }

    private func row(_ session: JBSession) -> some View {
        Button { onOpen(session) } label: {
            HStack(spacing: 12) {
                Image(systemName: session.mode == "agent" ? "hammer.fill" : "bubble.left")
                    .font(.footnote)
                    .foregroundStyle(session.mode == "agent" ? .orange : .white.opacity(0.55))
                    .frame(width: 18)
                    .scaleEffect(reduceMotion || symbolsReady ? 1 : 0.92)
                    .opacity(reduceMotion || symbolsReady ? 1 : 0.75)
                    .animation(reduceMotion ? nil : .easeOut(duration: 0.18), value: symbolsReady)
                VStack(alignment: .leading, spacing: 2) {
                    Text(session.name).lineLimit(1).foregroundStyle(.white)
                    if let model = session.model, !model.isEmpty {
                        Text(model.components(separatedBy: "/").last ?? model)
                            .font(.caption2).foregroundStyle(.secondary).lineLimit(1)
                    }
                }
                Spacer(minLength: 6)
                if session.isImportant == true { Image(systemName: "pin.fill").font(.caption2).foregroundStyle(.orange) }
                Image(systemName: "chevron.right").font(.caption2.bold()).foregroundStyle(.white.opacity(0.35))
            }
            .frame(minHeight: 44)
            .contentShape(Rectangle())
        }
        .buttonStyle(SessionPressStyle(reduceMotion: reduceMotion))
        .listRowBackground(Color.white.opacity(0.06))
        .swipeActions(edge: .trailing, allowsFullSwipe: false) {
            Button("Delete", systemImage: "trash", role: .destructive) { deleteTargetID = session.id }
            Button("Archive", systemImage: "archivebox") { Task { await store.archiveSession(session.id) } }
                .tint(.gray)
        }
        .swipeActions(edge: .leading, allowsFullSwipe: false) {
            Button(session.isImportant == true ? "Unpin" : "Pin",
                   systemImage: session.isImportant == true ? "pin.slash" : "pin.fill") {
                pinChatAfterGesture(session.id)
            }
            .tint(.orange)
        }
        .contextMenu { rowMenu(session) }
    }

    @ViewBuilder
    private func rowMenu(_ session: JBSession) -> some View {
        Button("Rename", systemImage: "pencil") { renameName = session.name; renameTargetID = session.id }
        Button(session.isImportant == true ? "Unpin chat" : "Pin chat", systemImage: "pin") {
            pinChatAfterGesture(session.id)
        }
        Menu {
            ForEach(store.folderNames, id: \.self) { folder in
                Button(folder) { Task { await store.setFolder(session.id, to: folder) } }
            }
            Divider()
            Button("New folder…", systemImage: "folder.badge.plus") {
                newFolderName = ""
                newFolderTargetID = session.id
            }
            if !session.folderKey.isEmpty {
                Button("Remove from folder", systemImage: "folder.badge.minus") {
                    Task { await store.setFolder(session.id, to: nil) }
                }
            }
        } label: { Label("Move to folder", systemImage: "folder") }
        Button("Archive", systemImage: "archivebox") { Task { await store.archiveSession(session.id) } }
        Button("Delete", systemImage: "trash", role: .destructive) { deleteTargetID = session.id }
    }

    private var emptyState: some View {
        VStack(spacing: 10) {
            Image(systemName: "bubble.left.and.bubble.right").font(.largeTitle).foregroundStyle(.secondary)
            Text("No chats yet").font(.headline).foregroundStyle(.white)
            Text("Tap the pencil to start one.").font(.footnote).foregroundStyle(.secondary)
        }
        .frame(maxWidth: .infinity)
        .padding(.vertical, 40)
        .listRowBackground(Color.clear)
    }

    /// Let a swipe or context menu dismiss before moving its source row.
    private func pinChatAfterGesture(_ id: String) {
        Task {
            try? await Task.sleep(for: .milliseconds(180))
            await store.togglePin(id)
        }
    }

    private func pinFolderAfterGesture(_ folder: String) {
        Task {
            try? await Task.sleep(for: .milliseconds(180))
            withAnimation(reduceMotion ? nil : .easeInOut(duration: 0.24)) {
                store.toggleFolderPin(folder)
            }
        }
    }
}

private struct SessionPressStyle: ButtonStyle {
    let reduceMotion: Bool

    func makeBody(configuration: Configuration) -> some View {
        configuration.label
            .scaleEffect(configuration.isPressed && !reduceMotion ? 0.99 : 1)
            .opacity(configuration.isPressed ? 0.86 : 1)
            .animation(reduceMotion ? nil : .easeOut(duration: 0.14), value: configuration.isPressed)
    }
}

/// Every alert and confirmation for the list, lifted out so the list's own body
/// stays inside the type checker's patience.
private struct SessionListDialogs: ViewModifier {
    let store: ChatStore
    @Binding var search: String
    @Binding var renameTargetID: String?
    @Binding var renameName: String
    @Binding var deleteTargetID: String?
    @Binding var folderRenameTarget: String?
    @Binding var folderRenameName: String
    @Binding var folderDeleteTarget: String?
    @Binding var newFolderTargetID: String?
    @Binding var newFolderName: String

    private func presenting<T>(_ source: Binding<T?>) -> Binding<Bool> {
        Binding(get: { source.wrappedValue != nil }, set: { if !$0 { source.wrappedValue = nil } })
    }

    private var deleteName: String {
        store.sessions.first { $0.id == deleteTargetID }?.name ?? "this chat"
    }

    private var folderDeleteCount: Int {
        guard let folder = folderDeleteTarget else { return 0 }
        return store.sessions(inFolder: folder, search: "").count
    }

    func body(content: Content) -> some View {
        content
            .alert("Rename chat", isPresented: presenting($renameTargetID)) {
                TextField("Name", text: $renameName)
                Button("Cancel", role: .cancel) { renameTargetID = nil }
                Button("Save") {
                    if let id = renameTargetID { Task { await store.renameSession(id, to: renameName) } }
                    renameTargetID = nil
                }
            }
            .alert("Rename folder", isPresented: presenting($folderRenameTarget)) {
                TextField("Folder", text: $folderRenameName)
                Button("Cancel", role: .cancel) { folderRenameTarget = nil }
                Button("Save") {
                    if let old = folderRenameTarget { Task { await store.renameFolder(old, to: folderRenameName) } }
                    folderRenameTarget = nil
                }
            }
            .alert("New folder", isPresented: presenting($newFolderTargetID)) {
                TextField("Folder name", text: $newFolderName)
                Button("Cancel", role: .cancel) { newFolderTargetID = nil }
                Button("Create") {
                    if let id = newFolderTargetID { Task { await store.setFolder(id, to: newFolderName) } }
                    newFolderName = ""
                    newFolderTargetID = nil
                }
            } message: { Text("This chat moves into the new folder.") }
            .alert("Delete “\(deleteName)”?", isPresented: presenting($deleteTargetID)) {
                Button("Delete chat", role: .destructive) {
                    if let id = deleteTargetID { Task { await store.deleteSession(id) } }
                    deleteTargetID = nil
                }
                Button("Cancel", role: .cancel) { deleteTargetID = nil }
            } message: {
                Text("The conversation and its messages are removed from JoeBro. This cannot be undone.")
            }
            .alert("Delete the folder “\(folderDeleteTarget ?? "")”?",
                   isPresented: presenting($folderDeleteTarget)) {
                Button("Delete folder", role: .destructive) {
                    if let folder = folderDeleteTarget { Task { await store.removeFolder(folder) } }
                    folderDeleteTarget = nil
                }
                Button("Cancel", role: .cancel) { folderDeleteTarget = nil }
            } message: {
                Text("The folder disappears and its \(folderDeleteCount) chat\(folderDeleteCount == 1 ? "" : "s") move back to Chats. No chat is deleted.")
            }
    }
}
