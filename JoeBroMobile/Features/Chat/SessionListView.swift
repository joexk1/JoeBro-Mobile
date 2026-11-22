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
    var onOpenSettings: () -> Void = {}

    @State private var search = ""
    @State private var renameTargetID: String?
    @State private var renameName = ""
    @State private var deleteTargetID: String?
    @State private var folderRenameTarget: String?
    @State private var folderRenameName = ""
    @State private var folderDeleteTarget: String?
    @State private var newFolderTargetID: String?
    @State private var newFolderName = ""

    private var ungrouped: [JBSession] { store.sessions(inFolder: "", search: search) }

    /// A search collapses nothing — you want to see every hit.
    private func isExpanded(_ folder: String) -> Bool {
        !search.isEmpty || !store.collapsedFolders.contains(folder)
    }

    var body: some View {
        List {
            folderSections
            if !ungrouped.isEmpty {
                Section {
                    ForEach(ungrouped) { session in
                        row(session)
                    }
                } header: {
                    if !store.folderNames.isEmpty {
                        Text("Chats").font(.jb(13, .semibold)).foregroundStyle(JB.ink2)
                            .textCase(nil).padding(.leading, 4)
                    }
                }
            }
        }
        .overlay { if store.sessions.isEmpty { JBEmptyState(art: .inbox, text: "No chats") } }
        .listStyle(.plain)
        .listRowSpacing(0)
        .scrollContentBackground(.hidden)
        .animation(reduceMotion ? nil : JB.smooth,
                   value: store.sessions.map { "\($0.id):\($0.isImportant == true):\($0.folderKey)" })
        .animation(reduceMotion ? nil : JB.smooth, value: store.pinnedFolders)
        // searchable must stay attached to the List itself — attaching it to
        // the wallpaper's ZStack wrapper blanked the whole window.
        .jbWallpaper()
        .refreshable { await store.reloadSessions() }
        .jbTopBar("Chats", search: $search, onAdd: { Task { await store.newChat(); onNewChat() } },
                  addLabel: "New chat", onSettings: onOpenSettings)
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
                        row(session, nested: true)
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
                Image(systemName: collapsed ? "folder" : "folder.fill")
                    .font(.jb(16, .regular))
                    .foregroundStyle(collapsed ? JB.ink2 : JB.accent)
                    .frame(width: 22)
                Text(folder).font(.jb(16, .semibold))
                    .foregroundStyle(JB.ink).lineLimit(1)
                if store.pinnedFolders.contains(folder) {
                    Image(systemName: "pin").font(.jb(11)).foregroundStyle(JB.ink3)
                }
                Spacer(minLength: 6)
                Text("\(count)").font(.jb(13, .medium)).foregroundStyle(JB.ink3).monospacedDigit()
                Image(systemName: "chevron.right")
                    .font(.jb(11, .semibold))
                    .foregroundStyle(JB.ink3)
                    .rotationEffect(.degrees(collapsed ? 0 : 90))
            }
            .padding(.horizontal, 4)
            .frame(minHeight: 46)
            .contentShape(Rectangle())
        }
        .buttonStyle(JBPressStyle())
        .listRowInsets(EdgeInsets(top: 6, leading: 16, bottom: 2, trailing: 16))
        .listRowBackground(Color.clear)
        .listRowSeparator(.hidden)
        .accessibilityLabel("Folder \(folder), \(count) chats")
        .accessibilityValue("\(store.pinnedFolders.contains(folder) ? "Pinned, " : "")\(collapsed ? "collapsed" : "expanded")")
        .accessibilityHint(collapsed ? "Expands the folder" : "Collapses the folder")
        .swipeActions(edge: .leading, allowsFullSwipe: false) {
            Button(store.pinnedFolders.contains(folder) ? "Unpin" : "Pin",
                   systemImage: store.pinnedFolders.contains(folder) ? "pin.slash" : "pin") {
                pinFolderAfterGesture(folder)
            }
            .tint(JB.accent)
        }
        .swipeActions(edge: .trailing, allowsFullSwipe: false) {
            Button("Delete folder", systemImage: "trash", role: .destructive) { folderDeleteTarget = folder }
            Button("Rename", systemImage: "pencil") {
                folderRenameName = folder
                folderRenameTarget = folder
            }
            .tint(JB.ink3)
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

    private func row(_ session: JBSession, nested: Bool = false) -> some View {
        // Chats inside a folder sit indented under it, joined by a guide line.
        let lead: CGFloat = nested ? 44 : 16
        return Button { onOpen(session) } label: {
            HStack(spacing: 10) {
                Text(session.name).font(.jb(15, .medium)).foregroundStyle(JB.ink).lineLimit(1)
                if session.mode == "agent" { JBIcon(.tools, size: 12).foregroundStyle(JB.ink3) }
                Spacer(minLength: 6)
                if session.isImportant == true { Image(systemName: "pin").font(.jb(11)).foregroundStyle(JB.accent) }
                Text(Self.stamp(session.createdAt)).font(.jb(13)).foregroundStyle(JB.ink3)
            }
            .padding(.horizontal, 14)
            .frame(minHeight: 50)
            .contentShape(Rectangle())
        }
        .buttonStyle(JBPressStyle())
        .listRowInsets(EdgeInsets(top: 3, leading: lead, bottom: 3, trailing: 16))
        .listRowBackground(
            ZStack(alignment: .leading) {
                if nested {
                    Rectangle().fill(JB.line).frame(width: 1.5).padding(.leading, 27)
                }
                RoundedRectangle(cornerRadius: 12, style: .continuous)
                    .fill(JB.raised.opacity(0.92))
                    .overlay(RoundedRectangle(cornerRadius: 12, style: .continuous).strokeBorder(JB.line, lineWidth: 1))
                    .padding(.vertical, 3).padding(.leading, lead).padding(.trailing, 16)
            }
        )
        .listRowSeparator(.hidden)
        .swipeActions(edge: .trailing, allowsFullSwipe: false) {
            Button("Delete", systemImage: "trash", role: .destructive) { deleteTargetID = session.id }
            Button("Archive", systemImage: "archivebox") { Task { await store.archiveSession(session.id) } }
                .tint(JB.ink3)
        }
        .swipeActions(edge: .leading, allowsFullSwipe: false) {
            Button(session.isImportant == true ? "Unpin" : "Pin",
                   systemImage: session.isImportant == true ? "pin.slash" : "pin") {
                pinChatAfterGesture(session.id)
            }
            .tint(JB.accent)
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

    /// "14:03" for today, otherwise "Nov 20".
    /// Compact local-time label: now, 5m, 3h, 2d, then a short date. Backend stamps are UTC.
    private static func stamp(_ raw: String?) -> String {
        guard let raw, !raw.isEmpty else { return "" }
        let frac = ISO8601DateFormatter(); frac.formatOptions = [.withInternetDateTime, .withFractionalSeconds]
        let plain = ISO8601DateFormatter()
        let naive = DateFormatter(); naive.locale = Locale(identifier: "en_US_POSIX"); naive.timeZone = TimeZone(identifier: "UTC")
        naive.dateFormat = "yyyy-MM-dd'T'HH:mm:ss"
        guard let date = frac.date(from: raw) ?? plain.date(from: raw) ?? naive.date(from: String(raw.prefix(19))) else { return "" }
        let secs = Date().timeIntervalSince(date)
        if secs < 60 { return "now" }
        if secs < 3600 { return "\(Int(secs / 60))m" }
        if secs < 86400 { return "\(Int(secs / 3600))h" }
        if secs < 86400 * 7 { return "\(Int(secs / 86400))d" }
        return date.formatted(.dateTime.month(.abbreviated).day())
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
