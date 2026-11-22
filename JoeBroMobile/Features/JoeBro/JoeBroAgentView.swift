import SwiftUI
import PhotosUI
import UniformTypeIdentifiers

private struct HeaderZoneKey: PreferenceKey {
    static var defaultValue: CGFloat = 0
    static func reduce(value: inout CGFloat, nextValue: () -> CGFloat) {
        value = max(value, nextValue())
    }
}

/// JoeBro's persistent conversation. It has its own store so visiting a
/// project chat never changes the main agent's transcript or draft.
struct JoeBroAgentView: View {
    @Environment(JoeBroTheme.self) private var theme

    let store: ChatStore
    let onOpenSettings: () -> Void
    @State private var selectedPhoto: PhotosPickerItem?
    @State private var showFilePicker = false
    @State private var voice = VoiceCapture()
    @State private var openDocument: ChatDocumentRef?
    @State private var conversationAction: ConversationAction?
    @State private var headerZoneHeight: CGFloat = 220

    private enum ConversationAction {
        case compact, clear
    }

    var body: some View {
        ZStack(alignment: .top) {
            // Own the full screen background outside any navigation controller.
            // Native navigation hosting clips child backgrounds at the bar edge.
            GeometryReader { geometry in
                ZStack(alignment: .top) {
                    WallpaperBackground(theme: theme)
                    AsciiTopBarAnimation()
                        .frame(height: max(0, headerZoneHeight - geometry.frame(in: .global).minY))
                        .clipped()
                }
            }
            .ignoresSafeArea()

            VStack(spacing: 0) {
                headerBar
                JoeBroPresence(isWorking: store.busy,
                               isAvailable: store.mainConnectionIssue == nil,
                               isListening: voice.isRecording,
                               needsAttention: store.permission != nil || store.error != nil,
                               isUsingTools: store.busy && (store.lines.last?.toolCalls.contains(where: { !$0.finished }) ?? false),
                               isStreaming: store.busy && store.lines.last?.role == "assistant"
                                   && !(store.lines.last?.text.isEmpty ?? true),
                               onCompact: { conversationAction = .compact },
                               onClear: { conversationAction = .clear })
                    .padding(.horizontal, 12)
                    .padding(.top, 6)
                    .padding(.bottom, 10)
                    .background(
                        GeometryReader { g in
                            Color.clear.preference(key: HeaderZoneKey.self,
                                                   value: g.frame(in: .global).maxY)
                        }
                    )
                Rectangle().fill(JB.line).frame(height: 1)
                if let issue = store.mainConnectionIssue, store.selectedSessionID == nil {
                    VStack(spacing: 8) {
                        JBEmptyState(art: .plug, text: issue)
                        Button("Try again") { Task { await store.load() } }
                            .buttonStyle(.jbSecondary)
                    }
                    .frame(maxWidth: .infinity, maxHeight: .infinity)
                } else {
                    ChatTranscriptView(store: store, onOpenDocument: { openDocument = $0 }) {
                        ChatComposerView(store: store, selectedPhoto: $selectedPhoto,
                                         showFilePicker: $showFilePicker, voice: voice,
                                         mainAgent: true)
                    }
                }
            }
            .onPreferenceChange(HeaderZoneKey.self) { headerZoneHeight = $0 }
            .task { await store.load() }
            .onChange(of: selectedPhoto) { _, item in Task { await uploadPhoto(item) } }
            .fileImporter(isPresented: $showFilePicker, allowedContentTypes: [.item],
                          allowsMultipleSelection: true) { result in
                Task { await uploadFiles(result) }
            }
            .sheet(item: $openDocument) { document in
                NavigationStack {
                    DocumentEditorView(api: store.api,
                        source: documentSource(document),
                        fallbackTitle: document.title)
                        .toolbar { ToolbarItem(placement: .cancellationAction) {
                            Button("Done") { openDocument = nil }
                        } }
                }
            }
            .alert("JoeBro", isPresented: Binding(get: { store.error != nil },
                                                  set: { if !$0 { store.error = nil } })) {
                Button("OK") { store.error = nil }
            } message: { Text(store.error ?? "") }
            .alert(conversationAction == .clear ? "Clear conversation?" : "Compact conversation?",
                   isPresented: Binding(get: { conversationAction != nil },
                                        set: { if !$0 { conversationAction = nil } })) {
                Button("Cancel", role: .cancel) { conversationAction = nil }
                if conversationAction == .clear {
                    Button("Clear conversation", role: .destructive) {
                        conversationAction = nil
                        Task { await store.clearJoeBro() }
                    }
                } else {
                    Button("Compact") {
                        conversationAction = nil
                        Task { await store.compactJoeBro() }
                    }
                }
            } message: {
                Text(conversationAction == .clear
                     ? "Delete this conversation's messages and start fresh. JoeBro's soul and settings stay saved."
                     : "Summarize older messages while keeping the recent conversation.")
            }
            .alert("Allow \(store.permission?.tool ?? "tool")?",
                   isPresented: Binding(get: { store.permission != nil },
                                        set: { if !$0 { Task { await store.answerPermission("deny") } } })) {
                Button("Deny", role: .cancel) { Task { await store.answerPermission("deny") } }
                Button("Allow once") { Task { await store.answerPermission("allow") } }
                Button("Always allow this session") { Task { await store.answerPermission("always") } }
            } message: { Text(store.permission?.command ?? "") }
        }
    }

    private var headerBar: some View {
        ZStack {
            headerTitle
            HStack {
                Spacer()
                settingsControl
            }
            .padding(.horizontal, 16)
        }
        .frame(height: 44)
    }

    private var headerTitle: some View {
        Text("JoeBro")
            .font(.jb(15, .semibold))
            .tracking(-0.2)
            .foregroundStyle(JB.ink)
            .padding(.horizontal, 16)
            .frame(height: 32)
            .jbSurface(.chrome, radius: 16)
            .accessibilityAddTraits(.isHeader)
    }

    private var settingsControl: some View {
        Button(action: onOpenSettings) {
            Image(systemName: "gearshape")
                .font(.jb(16, .regular))
                .foregroundStyle(JB.ink)
                .frame(width: 32, height: 32)
                .jbSurface(.chrome, radius: 16)
                .frame(width: 44, height: 44)
                .contentShape(Rectangle())
        }
        .buttonStyle(JBPressStyle())
        .accessibilityLabel("Settings")
    }

    private func documentSource(_ document: ChatDocumentRef) -> DocumentEditorStore.Source {
        if document.id.hasPrefix("local-"), let session = store.selectedSessionID {
            return .workdir(session: session, sub: String(document.id.dropFirst(6)))
        }
        return .library(id: document.id)
    }

    private func uploadPhoto(_ item: PhotosPickerItem?) async {
        guard let item, let data = try? await item.loadTransferable(type: Data.self) else { return }
        store.uploadingAttachment = true
        defer { store.uploadingAttachment = false; selectedPhoto = nil }
        do {
            let type = item.supportedContentTypes.first
            let uploaded = try await store.api.upload(data: data,
                filename: "photo.\(type?.preferredFilenameExtension ?? "jpg")",
                mimeType: type?.preferredMIMEType ?? "image/jpeg")
            store.pendingAttachments.append(uploaded)
        } catch { store.error = error.localizedDescription }
    }

    private func uploadFiles(_ result: Result<[URL], Error>) async {
        store.uploadingAttachment = true
        defer { store.uploadingAttachment = false }
        do {
            for url in try result.get() {
                let scoped = url.startAccessingSecurityScopedResource()
                defer { if scoped { url.stopAccessingSecurityScopedResource() } }
                let data = try Data(contentsOf: url)
                let type = UTType(filenameExtension: url.pathExtension)
                let uploaded = try await store.api.upload(data: data, filename: url.lastPathComponent,
                    mimeType: type?.preferredMIMEType ?? "application/octet-stream")
                store.pendingAttachments.append(uploaded)
            }
        } catch { store.error = error.localizedDescription }
    }
}

/// JoeBro's face, driven by what the agent is actually doing.
private struct JoeBroPresence: View {
    let isWorking: Bool
    let isAvailable: Bool
    let isListening: Bool
    let needsAttention: Bool
    let isUsingTools: Bool
    let isStreaming: Bool
    let onCompact: () -> Void
    let onClear: () -> Void
    @State private var justFinished = false
    @State private var drowsy = false

    private var night: Bool { (0..<6).contains(Calendar.current.component(.hour, from: Date())) }

    private var mood: JBFace.Mood {
        if !isAvailable || needsAttention || isListening { return .alert }
        if isStreaming { return .talking }
        if isWorking { return .thinking }
        if justFinished { return .happy }
        return (drowsy || night) ? .sleeping : .idle
    }

    private var label: String {
        if !isAvailable { return "offline" }
        if needsAttention { return "needs you" }
        if isListening { return "listening" }
        if isUsingTools { return "working" }
        if isStreaming { return "replying" }
        if isWorking { return "thinking" }
        return mood == .sleeping ? "asleep" : "ready"
    }

    private var dot: Color {
        if !isAvailable { return JB.ink3 }
        if needsAttention || isListening { return JB.warn }
        return isWorking ? JB.live : JB.ink3
    }

    var body: some View {
        HStack(spacing: 14) {
            Menu {
                Button("Compact conversation", systemImage: "arrow.down.right.and.arrow.up.left") { onCompact() }
                    .disabled(isWorking)
                Button("Clear conversation", systemImage: "trash", role: .destructive) { onClear() }
                    .disabled(isWorking)
            } label: {
                JBFace(mood: mood, size: 13, tint: isAvailable ? JB.ink : JB.ink3)
                    .padding(.horizontal, 14)
                    .padding(.vertical, 12)
                    .jbSurface(.raised, radius: JB.rCard)
                    .animation(JB.snap, value: mood)
            }
            .buttonStyle(JBPressStyle())
            .accessibilityLabel("JoeBro conversation actions")
            HStack(spacing: 7) {
                JBStatusDot(color: dot, live: isWorking, size: 6)
                Text(label).font(.jbMono(12)).foregroundStyle(JB.ink3)
            }
            Spacer(minLength: 0)
        }
        .padding(10)
        .jbSurface(.panel, radius: JB.rPanel)
        .onChange(of: isWorking) { was, now in
            guard was, !now else { drowsy = false; return }
            justFinished = true
            drowsy = false
        }
        .task(id: justFinished) {
            guard justFinished else { return }
            try? await Task.sleep(for: .seconds(2.5))
            justFinished = false
        }
        .task(id: isWorking || justFinished || isListening) {
            // Doze off after ten idle minutes.
            guard !isWorking, !justFinished, !isListening else { return }
            try? await Task.sleep(for: .seconds(600))
            if !Task.isCancelled { drowsy = true }
        }
    }
}
