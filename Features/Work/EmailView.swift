import SwiftUI

/// The mailbox: pick a folder, filter to unread, read a message, and mark
/// read/unread, archive or delete it from either the list or the reader.
///
/// Navigation uses `NavigationLink`'s destination-builder form. The value form
/// requires a matching `navigationDestination(for:)`, and declaring one for
/// `String` here — inside a view pushed onto the Workspace hub's stack — clashed
/// with the hub's own destination table and stopped this screen opening at all.
struct EmailView: View {
    let api: JoeBroAPI

    @State private var status: JBEmailStatus?
    @State private var list: JBEmailList?
    @State private var folders: [String] = ["INBOX"]
    @State private var folder = "INBOX"
    @State private var unreadOnly = false
    @State private var loading = false
    @State private var actionUID: String?
    @State private var deleteTarget: JBEmailSummary?
    @State private var showCompose = false
    @State private var error: String?

    private var sender: String { status?.sources.first?.display ?? status?.display ?? "" }

    var body: some View {
        List {
            if status?.configured == false {
                empty("envelope", "No email account connected")
            } else {
                controlsSection
                messagesSection
            }
        }
        .listStyle(.insetGrouped)
        .jbForm()
        .navigationTitle("Email")
        .navigationBarTitleDisplayMode(.inline)
        .toolbar {
            ToolbarItem(placement: .topBarTrailing) {
                Button { showCompose = true } label: {
                    Image(systemName: "square.and.pencil").foregroundStyle(JB.ink)
                }
                .accessibilityLabel("Compose email")
                .disabled(status?.configured != true)
            }
        }
        .overlay { if loading && list == nil && status?.configured != false { JBSpinner(size: 16) } }
        .sheet(isPresented: $showCompose) {
            EmailComposeView(api: api, reply: nil, from: sender) { Task { await refreshList() } }
        }
        .alert("Delete this email?", isPresented: alertBinding($deleteTarget)) {
            Button("Delete email", role: .destructive) {
                if let message = deleteTarget { Task { await delete(message.uid) } }
                deleteTarget = nil
            }
            Button("Keep it", role: .cancel) { deleteTarget = nil }
        } message: {
            Text("“\(deleteTarget?.subject ?? "")” is removed from the mailbox.")
        }
        .alert("Email", isPresented: alertBinding($error)) { Button("OK") { error = nil } } message: { Text(error ?? "") }
        .refreshable { await refresh(force: true) }
        .task { await refresh() }
        .onChange(of: folder) { _, _ in Task { await refreshList() } }
        .onChange(of: unreadOnly) { _, _ in Task { await refreshList() } }
    }

    // MARK: Sections

    private var controlsSection: some View {
        Section {
            Picker("Folder", selection: $folder) {
                ForEach(folders, id: \.self) { name in Text(name).tag(name) }
            }
            .listRowBackground(JB.panelFill)

            Toggle("Unread only", isOn: $unreadOnly)
                .sensoryFeedback(.selection, trigger: unreadOnly)
                .listRowBackground(JB.panelFill)
        }
    }

    @ViewBuilder
    private var messagesSection: some View {
        Section {
            if loading && list == nil {
                HStack(spacing: 8) { JBSpinner(); Text("Connecting").font(.jbMono(11)).foregroundStyle(JB.ink3) }
                    .frame(minHeight: 44)
                    .listRowBackground(Color.clear)
            }
            if let message = list?.error ?? error, !message.isEmpty {
                Text(message)
                    .font(.jbMono(12)).foregroundStyle(JB.warn)
                    .listRowBackground(JB.panelFill)
            }
            if let list, list.emails.isEmpty, !loading, (list.error ?? "").isEmpty {
                empty("tray", unreadOnly ? "No unread mail" : "No messages")
            }
            ForEach(list?.emails ?? []) { message in
                row(message)
            }
        } header: {
            JBSectionHeader(folder, count: list.map { $0.total > $0.emails.count ? $0.total : $0.emails.count })
        }
        .animation(JB.smooth, value: list?.emails.map(\.uid) ?? [])
    }

    private func row(_ message: JBEmailSummary) -> some View {
        NavigationLink {
            EmailMessageView(api: api, uid: message.uid, folder: folder, senderDisplay: sender,
                             canReply: canReply(message.uid),
                             onChanged: { Task { await refreshList() } })
        } label: {
            EmailRow(message: message, busy: actionUID == message.uid)
        }
        .listRowBackground(JB.panelFill)
        .contextMenu {
            Button(message.isRead ? "Mark unread" : "Mark read",
                   systemImage: message.isRead ? "envelope.badge" : "envelope.open") {
                Task { await mark(message, read: !message.isRead) }
            }
            Button("Archive", systemImage: "archivebox") { Task { await archive(message.uid) } }
            Button("Delete", systemImage: "trash", role: .destructive) { deleteTarget = message }
        }
        .swipeActions(edge: .trailing, allowsFullSwipe: false) {
            Button("Delete", systemImage: "trash") { deleteTarget = message }.tint(JB.danger)
            Button("Archive", systemImage: "archivebox") { Task { await archive(message.uid) } }.tint(JB.ink3)
        }
        .swipeActions(edge: .leading, allowsFullSwipe: false) {
            Button(message.isRead ? "Unread" : "Read",
                   systemImage: message.isRead ? "envelope.badge" : "envelope.open") {
                Task { await mark(message, read: !message.isRead) }
            }
            .tint(JB.accent)
        }
        .sensoryFeedback(.selection, trigger: message.isRead)
    }

    private func canReply(_ uid: String) -> Bool {
        guard let sources = status?.sources else { return true }
        return sources.count <= 1 || uid.hasPrefix((sources.first?.id ?? "") + "::")
    }

    // MARK: Work

    private func refresh(force: Bool = false) async {
        guard !loading else { return }
        loading = true
        defer { loading = false }
        do {
            async let incomingStatus = api.emailStatus()
            async let incomingFolders = api.emailFolders()
            async let incomingList = api.emailList(folder: folder, unreadOnly: unreadOnly, refresh: force)
            status = try await incomingStatus
            guard status?.configured == true else { list = nil; error = nil; return }
            list = try await incomingList
            error = nil
            folders = (try? await incomingFolders)?.filter { $0 != "*" } ?? ["INBOX"]
            if !folders.contains(folder) { folders.insert(folder, at: 0) }
        } catch { self.error = error.localizedDescription }
    }

    private func refreshList() async {
        guard status?.configured == true else { return }
        do { list = try await api.emailList(folder: folder, unreadOnly: unreadOnly); error = nil }
        catch { self.error = error.localizedDescription }
    }

    private func mark(_ message: JBEmailSummary, read: Bool) async {
        guard actionUID == nil else { return }
        actionUID = message.uid
        defer { actionUID = nil }
        do { try await api.markEmail(uid: message.uid, folder: folder, read: read); await refreshList() }
        catch { self.error = error.localizedDescription }
    }

    private func archive(_ uid: String) async {
        guard actionUID == nil else { return }
        actionUID = uid
        defer { actionUID = nil }
        do { try await api.archiveEmail(uid: uid, folder: folder); await refreshList() }
        catch { self.error = error.localizedDescription }
    }

    private func delete(_ uid: String) async {
        guard actionUID == nil else { return }
        actionUID = uid
        defer { actionUID = nil }
        do { try await api.deleteEmail(uid: uid, folder: folder); await refreshList() }
        catch { self.error = error.localizedDescription }
    }
}

// MARK: - Rows

private struct EmailRow: View {
    let message: JBEmailSummary
    let busy: Bool

    var body: some View {
        HStack(alignment: .top, spacing: 11) {
            JBStatusDot(color: message.isRead ? .clear : JB.accent, size: 7)
                .padding(.top, 7)
            VStack(alignment: .leading, spacing: 4) {
                HStack(spacing: 6) {
                    Text(from)
                        .font(.jb(15, message.isRead ? .regular : .semibold))
                        .foregroundStyle(JB.ink)
                        .lineLimit(1)
                    Spacer(minLength: 4)
                    if message.isFlagged {
                        Image(systemName: "flag").font(.jbCaption).foregroundStyle(JB.warn)
                            .accessibilityLabel("Flagged")
                    }
                    if busy { JBSpinner(size: 10) }
                }
                Text(message.subject.isEmpty ? "(no subject)" : message.subject)
                    .font(.jb(14)).foregroundStyle(JB.ink2).lineLimit(2)
                if let date = message.date, !date.isEmpty {
                    Text(date).font(.jbMono(10.5)).foregroundStyle(JB.ink3).lineLimit(1)
                }
            }
        }
        .frame(minHeight: 48)
    }

    private var from: String {
        if let name = message.fromName, !name.isEmpty { return name }
        return message.fromAddress ?? "Unknown sender"
    }
}

// MARK: - Reader

private struct EmailMessageView: View {
    let api: JoeBroAPI
    let uid: String
    let folder: String
    let senderDisplay: String
    let canReply: Bool
    var onChanged: () -> Void

    @Environment(\.dismiss) private var dismiss
    @State private var message: JoeBroAPI.EmailMessage?
    @State private var actionBusy = false
    @State private var showReply = false
    @State private var confirmDelete = false
    @State private var error: String?

    var body: some View {
        ScrollView {
            VStack(alignment: .leading, spacing: 16) {
                if let detail = message?.detail {
                    header(detail)
                    Divider().overlay(JB.line)
                    Text(Self.readableBody(detail.body ?? ""))
                        .font(.jb(15)).lineSpacing(4)
                        .foregroundStyle(JB.ink)
                        .textSelection(.enabled)
                        .frame(maxWidth: .infinity, alignment: .leading)
                    attachments(detail)
                } else if let error {
                    empty("envelope", "Couldn't open message")
                } else {
                    JBSpinner(size: 16).frame(maxWidth: .infinity).padding(.vertical, 50)
                }
                if !canReply {
                    Text("Replies send from the first account").font(.jbMono(11)).foregroundStyle(JB.ink3)
                }
            }
            .frame(maxWidth: 760, alignment: .leading)
            .frame(maxWidth: .infinity, alignment: .leading)
            .padding(20)
        }
        .scrollIndicators(.hidden)
        .jbWallpaper()
        .navigationTitle("Message")
        .navigationBarTitleDisplayMode(.inline)
        .toolbar { toolbarItems }
        .sheet(isPresented: $showReply) {
            EmailComposeView(api: api, reply: message, from: senderDisplay) { onChanged() }
        }
        .alert("Delete this email?", isPresented: $confirmDelete) {
            Button("Delete email", role: .destructive) { Task { await delete() } }
            Button("Keep it", role: .cancel) {}
        } message: {
            Text("“\(message?.detail.subject ?? "")” is removed from the mailbox.")
        }
        .alert("Message", isPresented: alertBinding($error)) { Button("OK") { error = nil } } message: { Text(error ?? "") }
        .task(id: uid) { await load() }
    }

    @ToolbarContentBuilder
    private var toolbarItems: some ToolbarContent {
        ToolbarItemGroup(placement: .topBarTrailing) {
            if actionBusy { JBSpinner(size: 10) }
            Button { showReply = true } label: {
                Image(systemName: "arrowshape.turn.up.left").foregroundStyle(JB.ink)
            }
            .accessibilityLabel("Reply")
            .disabled(message == nil || actionBusy || !canReply)
            Menu {
                Button("Mark unread", systemImage: "envelope.badge") { Task { await markUnread() } }
                Button("Archive", systemImage: "archivebox") { Task { await archive() } }
                Button("Delete", systemImage: "trash", role: .destructive) { confirmDelete = true }
            } label: {
                Image(systemName: "ellipsis.circle").foregroundStyle(JB.ink)
            }
            .accessibilityLabel("Email actions")
            .disabled(message == nil || actionBusy)
        }
    }

    private func header(_ detail: JBEmailDetail) -> some View {
        VStack(alignment: .leading, spacing: 6) {
            Text(detail.subject.isEmpty ? "(no subject)" : detail.subject)
                .font(.jb(20, .semibold)).tracking(-0.3).foregroundStyle(JB.ink)
            Text(detail.fromName?.isEmpty == false ? detail.fromName! : (detail.fromAddress ?? "Unknown sender"))
                .font(.jb(14, .medium)).foregroundStyle(JB.ink)
            VStack(alignment: .leading, spacing: 2) {
                if let address = detail.fromAddress, detail.fromName?.isEmpty == false { Text(address) }
                if let to = detail.to, !to.isEmpty { Text("To: \(to)") }
                if let date = detail.date, !date.isEmpty { Text(date) }
            }
            .font(.jbMono(11)).foregroundStyle(JB.ink3)
        }
    }

    @ViewBuilder
    private func attachments(_ detail: JBEmailDetail) -> some View {
        if !detail.attachments.isEmpty {
            Divider().overlay(JB.line)
            JBSectionHeader("Attachments", count: detail.attachments.count)
            ForEach(detail.attachments) { file in
                Label(file.filename ?? "Attachment", systemImage: "paperclip")
                    .font(.jbMono(12)).foregroundStyle(JB.ink2)
            }
        }
    }

    private func load() async {
        // This GET route sets IMAP Seen. Do not prefetch from the list.
        do { message = try await api.emailMessage(uid: uid, folder: folder); error = nil; onChanged() }
        catch { self.error = error.localizedDescription }
    }

    private func markUnread() async { await run { try await api.markEmail(uid: uid, folder: folder, read: false) } }
    private func archive() async { await run { try await api.archiveEmail(uid: uid, folder: folder) } }
    private func delete() async { await run { try await api.deleteEmail(uid: uid, folder: folder) } }

    private func run(_ work: () async throws -> Void) async {
        guard !actionBusy else { return }
        actionBusy = true
        defer { actionBusy = false }
        do { try await work(); onChanged(); dismiss() }
        catch { self.error = error.localizedDescription }
    }

    private static func readableBody(_ body: String) -> String {
        guard body.contains("<") && body.contains(">") else { return body }
        let breaks = body.replacingOccurrences(of: "(?i)<br\\s*/?>|</p>|</div>", with: "\n", options: .regularExpression)
        return breaks.replacingOccurrences(of: "<[^>]+>", with: "", options: .regularExpression)
            .replacingOccurrences(of: "&nbsp;", with: " ")
            .replacingOccurrences(of: "&amp;", with: "&")
            .replacingOccurrences(of: "&lt;", with: "<")
            .replacingOccurrences(of: "&gt;", with: ">")
            .trimmingCharacters(in: .whitespacesAndNewlines)
    }
}

// MARK: - Compose

private struct EmailComposeView: View {
    let api: JoeBroAPI
    let reply: JoeBroAPI.EmailMessage?
    let from: String
    var onSent: () -> Void

    @Environment(\.dismiss) private var dismiss
    @State private var to = ""
    @State private var cc = ""
    @State private var subject = ""
    @State private var bodyText = ""
    @State private var sending = false
    @State private var error: String?

    var body: some View {
        NavigationStack {
            Form {
                Section {
                    if !from.isEmpty { LabeledContent("From") { Text(from).font(.jbMono(12)) } }
                    TextField("To", text: $to)
                        .textContentType(.emailAddress)
                        .keyboardType(.emailAddress)
                        .textInputAutocapitalization(.never)
                    TextField("Cc", text: $cc)
                        .textContentType(.emailAddress)
                        .keyboardType(.emailAddress)
                        .textInputAutocapitalization(.never)
                    TextField("Subject", text: $subject)
                }
                .listRowBackground(JB.panelFill)
                JBSection("Message") {
                    TextEditor(text: $bodyText)
                        .frame(minHeight: 220)
                        .scrollContentBackground(.hidden)
                }
                .listRowBackground(JB.panelFill)
                if let reply {
                    JBSection("Original message") {
                        Text(reply.detail.body ?? "")
                            .font(.jbMono(11)).foregroundStyle(JB.ink3).lineLimit(8)
                    }
                    .listRowBackground(JB.panelFill)
                }
            }
            .jbForm()
            .navigationTitle(reply == nil ? "New email" : "Reply")
            .navigationBarTitleDisplayMode(.inline)
            .toolbar {
                ToolbarItem(placement: .cancellationAction) {
                    Button("Cancel") { dismiss() }.disabled(sending)
                }
                ToolbarItem(placement: .confirmationAction) {
                    Button("Send") { Task { await send() } }.disabled(sending || !canSend)
                }
            }
            .overlay { if sending { JBSpinner(size: 16) } }
            .alert("Couldn't send", isPresented: alertBinding($error)) { Button("OK") { error = nil } } message: { Text(error ?? "") }
        }
        .task {
            guard let reply, to.isEmpty else { return }
            let detail = reply.detail
            to = detail.fromAddress ?? ""
            subject = detail.subject.lowercased().hasPrefix("re:") ? detail.subject : "Re: \(detail.subject)"
        }
    }

    private var canSend: Bool {
        !to.trimmingCharacters(in: .whitespacesAndNewlines).isEmpty &&
        !bodyText.trimmingCharacters(in: .whitespacesAndNewlines).isEmpty
    }

    private func send() async {
        guard !sending else { return }
        sending = true
        defer { sending = false }
        do {
            let messageID = reply?.messageID
            let references = [reply?.references, messageID].compactMap { $0 }.filter { !$0.isEmpty }.joined(separator: " ")
            try await api.sendEmail(to: to.trimmingCharacters(in: .whitespacesAndNewlines),
                                    cc: cc.trimmingCharacters(in: .whitespacesAndNewlines),
                                    subject: subject, body: quoted(),
                                    inReplyTo: messageID,
                                    references: references.isEmpty ? nil : references)
            onSent()
            dismiss()
        } catch { self.error = error.localizedDescription }
    }

    private func quoted() -> String {
        guard let detail = reply?.detail else { return bodyText }
        let head = "From: \(detail.fromName ?? detail.fromAddress ?? "")\nDate: \(detail.date ?? "")\nSubject: \(detail.subject)"
        return bodyText + "\n\n---\n" + head + "\n\n" + (detail.body ?? "")
    }
}
