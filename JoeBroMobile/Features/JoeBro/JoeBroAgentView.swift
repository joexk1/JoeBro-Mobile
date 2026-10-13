import SwiftUI
import PhotosUI
import UniformTypeIdentifiers

/// JoeBro's persistent conversation. It has its own store so visiting a
/// project chat never changes the main agent's transcript or draft.
struct JoeBroAgentView: View {
    let store: ChatStore
    let onOpenSettings: () -> Void
    @State private var selectedPhoto: PhotosPickerItem?
    @State private var showFilePicker = false
    @State private var voice = VoiceCapture()
    @State private var openDocument: ChatDocumentRef?
    @State private var conversationAction: ConversationAction?

    private enum ConversationAction {
        case compact, clear
    }

    var body: some View {
        NavigationStack {
            VStack(spacing: 0) {
                JoeBroPresence(isWorking: store.busy,
                               isAvailable: store.mainConnectionIssue == nil,
                               isListening: voice.isRecording,
                               isUsingTools: store.busy && (store.lines.last?.toolCalls.contains(where: { !$0.finished }) ?? false),
                               isSpeaking: store.busy && store.lines.last?.role == "assistant"
                                   && !(store.lines.last?.text.isEmpty ?? true),
                               onCompact: { conversationAction = .compact },
                               onClear: { conversationAction = .clear })
                    .padding(.top, 7)
                    .padding(.bottom, 8)
                Rectangle().fill(.white.opacity(0.12)).frame(height: 1)
                    .padding(.horizontal, 16)
                if let issue = store.mainConnectionIssue, store.selectedSessionID == nil {
                    VStack(spacing: 16) {
                        Image(systemName: "wifi.exclamationmark")
                            .font(.title2).foregroundStyle(.white.opacity(0.65))
                        Text(issue).font(.subheadline).foregroundStyle(.white.opacity(0.8))
                            .multilineTextAlignment(.center)
                        Button("Try again") { Task { await store.load() } }
                            .buttonStyle(.bordered)
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
            .jbWallpaper()
            .navigationTitle("JoeBro")
            .navigationBarTitleDisplayMode(.inline)
            .toolbar {
                ToolbarItem(placement: .topBarTrailing) {
                    Button(action: onOpenSettings) {
                        Image(systemName: "gearshape")
                            .foregroundStyle(Color.accentTint)
                            .frame(width: 44, height: 44)
                    }
                    .accessibilityLabel("Settings")
                }
            }
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

private struct JoeBroPresence: View {
    @Environment(JoeBroTheme.self) private var theme
    let isWorking: Bool
    let isAvailable: Bool
    let isListening: Bool
    let isUsingTools: Bool
    let isSpeaking: Bool
    let onCompact: () -> Void
    let onClear: () -> Void
    @Environment(\.accessibilityReduceMotion) private var reduceMotion
    @State private var breathing = false
    @State private var blinking = false
    @State private var glance: CGFloat = 0
    @State private var activityStep = 0
    @State private var speakingBeat = false

    private var expression: JoeBroExpression {
        if !isAvailable { return .offline }
        if isListening { return .listening }
        if isUsingTools { return .usingTools }
        if isSpeaking { return .speaking }
        return isWorking ? .thinking : .idle
    }

    private var eyeDirection: CGFloat {
        if expression == .usingTools || expression == .thinking {
            return [-2.5, 0, 2.5][activityStep % 3]
        }
        return glance
    }

    var body: some View {
        HStack(spacing: 15) {
            Menu {
                Button("Compact conversation", systemImage: "square.compress") { onCompact() }
                    .disabled(isWorking)
                Button("Clear conversation", systemImage: "trash", role: .destructive) { onClear() }
                    .disabled(isWorking)
            } label: {
              ZStack {
                RoundedRectangle(cornerRadius: 31, style: .continuous)
                    .fill(.white.opacity(0.09))
                    .frame(width: 94, height: 94)
                    .overlay {
                        RoundedRectangle(cornerRadius: 31, style: .continuous)
                            .strokeBorder(.white.opacity(isWorking ? 0.14 : 0), lineWidth: 1)
                    }
                JoeBroFigure(expression: expression, eyesClosed: blinking,
                             color: theme.joeBroColor,
                             glance: eyeDirection, mouthOpen: speakingBeat && !reduceMotion)
                    .frame(width: 72, height: 72)
                    .scaleEffect(breathing && !reduceMotion ? 1.035 : 1)
                    .offset(y: breathing && !reduceMotion ? -2 : 1)
              }
            }
            .buttonStyle(.plain)
            .accessibilityLabel("JoeBro conversation actions")
            VStack(alignment: .leading, spacing: 5) {
                HStack(spacing: 7) {
                    Circle().fill(!isAvailable ? Color.gray : isListening ? Color.red : isWorking ? Color.accentTint : .mint)
                        .frame(width: 6, height: 6)
                    Text(!isAvailable ? "Offline" : isListening ? "Listening" : isUsingTools ? "Working on it" : isWorking ? "On it" : "Standing by")
                        .font(.subheadline).foregroundStyle(.white.opacity(0.69))
                }
            }
            Spacer(minLength: 0)
        }
        .padding(.horizontal, 18)
        .task(id: reduceMotion) {
            guard !reduceMotion else { breathing = false; blinking = false; glance = 0; activityStep = 0; speakingBeat = false; return }
            withAnimation(.easeInOut(duration: 2.4).repeatForever(autoreverses: true)) {
                breathing = true
            }
            while !Task.isCancelled {
                try? await Task.sleep(for: .seconds(3.6))
                guard !Task.isCancelled else { break }
                withAnimation(.easeInOut(duration: 0.16)) { glance = [-1.5, 0, 1.5].randomElement() ?? 0 }
                withAnimation(.easeInOut(duration: 0.09)) { blinking = true }
                try? await Task.sleep(for: .milliseconds(145))
                guard !Task.isCancelled else { break }
                withAnimation(.easeOut(duration: 0.13)) { blinking = false }
            }
        }
        .task(id: expression) {
            guard !reduceMotion else { return }
            activityStep = 0
            speakingBeat = false
            while !Task.isCancelled {
                let interval: Duration
                switch expression {
                case .speaking: interval = .milliseconds(420)
                case .thinking, .usingTools: interval = .milliseconds(900)
                default: return
                }
                try? await Task.sleep(for: interval)
                guard !Task.isCancelled else { break }
                withAnimation(.easeInOut(duration: 0.24)) {
                    activityStep += 1
                    speakingBeat.toggle()
                }
            }
        }
    }
}

private enum JoeBroExpression {
    case idle, thinking, usingTools, speaking, listening, offline
}

private struct JoeBroFigure: View {
    let expression: JoeBroExpression
    let eyesClosed: Bool
    let color: Color
    let glance: CGFloat
    let mouthOpen: Bool

    private var ink: Color {
        let uiColor = UIColor(color)
        var red: CGFloat = 0
        var green: CGFloat = 0
        var blue: CGFloat = 0
        var alpha: CGFloat = 0
        guard uiColor.getRed(&red, green: &green, blue: &blue, alpha: &alpha) else { return .black }
        return red * 0.299 + green * 0.587 + blue * 0.114 < 0.5 ? .white : .black
    }

    var body: some View {
        ZStack {
            RoundedRectangle(cornerRadius: 22, style: .continuous)
                .fill(color)
                .shadow(color: color.opacity(0.25), radius: expression == .thinking || expression == .usingTools ? 17 : 9)
            HStack(spacing: 13) {
                brow(left: true)
                brow(left: false)
            }
            .offset(y: -14)
            HStack(spacing: 16) {
                eye(left: true)
                eye(left: false)
            }
            .offset(x: glance, y: -5)
            mouth
        }
        .animation(.easeInOut(duration: 0.25), value: expression)
        .animation(.easeInOut(duration: 0.25), value: color)
        .accessibilityHidden(true)
    }

    private func brow(left: Bool) -> some View {
        Capsule()
            .fill(ink.opacity(expression == .offline ? 0.35 : 0.74))
            .frame(width: 8, height: 1.7)
            .rotationEffect(.degrees(expression == .thinking ? (left ? -14 : 7)
                                    : expression == .usingTools ? (left ? -7 : 12)
                                    : expression == .listening ? (left ? -8 : 8) : 0))
            .offset(y: expression == .listening || expression == .usingTools ? -2 : 0)
    }

    private func eye(left: Bool) -> some View {
        Capsule()
            .fill(ink.opacity(expression == .offline ? 0.4 : 0.83))
            .frame(width: expression == .listening ? 5.5 : 4.5,
                   height: eyesClosed ? 1.5 : expression == .listening ? 10
                     : expression == .thinking && !left ? 6 : 8)
    }

    private var mouth: some View {
        ZStack {
            Path { path in
                path.move(to: CGPoint(x: 28, y: 43))
                path.addQuadCurve(to: CGPoint(x: 44, y: 43),
                                  control: CGPoint(x: 36, y: expression == .listening ? 47 : 49))
            }
            .stroke(ink.opacity(0.77), style: StrokeStyle(lineWidth: 2.1, lineCap: .round))
            .opacity(expression == .idle || expression == .listening ? 1 : 0)

            Capsule()
                .fill(ink.opacity(0.75))
                .frame(width: expression == .thinking ? 9 : 11, height: 2)
                .offset(x: expression == .thinking ? 2 : 0, y: 10)
                .opacity(expression == .thinking || expression == .offline ? 1 : 0)

            Path { path in
                path.move(to: CGPoint(x: 31, y: 44))
                path.addQuadCurve(to: CGPoint(x: 43, y: 43),
                                  control: CGPoint(x: 37, y: 48))
            }
            .stroke(ink.opacity(0.77), style: StrokeStyle(lineWidth: 2, lineCap: .round))
            .opacity(expression == .usingTools ? 1 : 0)

            Ellipse()
                .fill(ink.opacity(0.8))
                .frame(width: mouthOpen ? 9 : 11, height: mouthOpen ? 8 : 3)
                .offset(y: 10)
                .opacity(expression == .speaking ? 1 : 0)
        }
    }
}
