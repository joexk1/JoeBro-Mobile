import SwiftUI
import PhotosUI

/// The composer, laid out like the Mac's ComposerView: a row of icon-only
/// toggles and the model picker, the two segmented switches, then the input
/// line. Split out of ChatsView to keep both bodies type-checkable.
struct ChatComposerView: View {
    let store: ChatStore
    @Binding var selectedPhoto: PhotosPickerItem?
    @Binding var showFilePicker: Bool
    var voice: VoiceCapture
    var mainAgent = false
    var onOpenWorkdir: (() -> Void)? = nil
    @FocusState private var inputFocused: Bool
    @State private var showPhotoPicker = false

    private var canSend: Bool {
        !store.busy && !store.uploadingAttachment
            && (!store.draft.trimmingCharacters(in: .whitespacesAndNewlines).isEmpty || !store.pendingAttachments.isEmpty)
    }

    private var hasBoundFolder: Bool {
        !(store.selectedSession?.workdir?.trimmingCharacters(in: .whitespacesAndNewlines).isEmpty ?? true)
    }

    var body: some View {
        VStack(spacing: 10) {
            if !mainAgent {
                switches
                toolRow
            }
            inputRow
            status
        }
        .padding(12)
        .jbGlass(24)
        .padding(.horizontal, 10)
        .padding(.bottom, 5)
        .photosPicker(isPresented: $showPhotoPicker, selection: $selectedPhoto, matching: .images)
    }

    // MARK: - Switches

    // Thinking/Fast is the same control as Chat/Agent — same style, same
    // metrics, side by side — which is what the Mac does with two SlideSwitches.
    private var switches: some View {
        HStack(spacing: 10) {
            Picker("Mode", selection: Binding(get: { store.agentMode }, set: { store.setAgentMode($0) })) {
                Text("Chat").tag(false)
                Text("Agent").tag(true)
            }
            .pickerStyle(.segmented)
            .accessibilityLabel("Conversation mode")

            Picker("Reasoning", selection: Binding(get: { store.thinkingOn }, set: { store.setThinking($0) })) {
                Text("Think").tag(true)
                Text("Fast").tag(false)
            }
            .pickerStyle(.segmented)
            .accessibilityLabel("Reasoning mode")
        }
    }

    // MARK: - Toggles + model picker

    private var toolRow: some View {
        HStack(spacing: 8) {
            iconToggle(symbol: "magnifyingglass", isOn: store.useWeb,
                       label: "Web search") { store.useWeb.toggle() }
                .disabled(!store.agentMode)
                .opacity(store.agentMode ? 1 : 0.35)
            iconToggle(symbol: "apple.terminal", isOn: store.allowBash,
                       label: "Allow terminal commands") { store.allowBash.toggle() }
                .disabled(!store.agentMode)
                .opacity(store.agentMode ? 1 : 0.35)
            permissionMenu
            Spacer(minLength: 4)
            ChatModelPicker(store: store)
        }
    }

    private func iconToggle(symbol: String, isOn: Bool, label: String, action: @escaping () -> Void) -> some View {
        Button(action: action) {
            Image(systemName: symbol)
                .font(.subheadline.weight(.semibold))
                .foregroundStyle(isOn ? Color.accentTint : Color.white.opacity(0.68))
                .frame(width: 36, height: 44)
                .contentShape(Rectangle())
        }
        .buttonStyle(.plain)
        .accessibilityLabel(label)
        .accessibilityValue(isOn ? "On" : "Off")
        .accessibilityAddTraits(isOn ? [.isButton, .isSelected] : .isButton)
    }

    private var permissionMenu: some View {
        Menu {
            permissionChoice("sandbox", hasBoundFolder ? "Bound folder" : "No folder bound", "folder.badge.gearshape")
            permissionChoice("readonly", "Read-only", "eye")
            permissionChoice("full", "Full access", "exclamationmark.shield")
            if !hasBoundFolder, let onOpenWorkdir {
                Divider()
                Button("Bind a folder", systemImage: "folder.badge.plus", action: onOpenWorkdir)
            }
        } label: {
            Image(systemName: store.permissionMode == "sandbox" ? "lock.fill" :
                    store.permissionMode == "readonly" ? "eye.fill" : "lock.open.fill")
                .font(.subheadline.weight(.semibold))
                .foregroundStyle(store.permissionMode == "full" ? Color.red :
                                 store.permissionMode == "readonly" ? Color.orange : Color.white.opacity(0.68))
                .frame(width: 36, height: 44)
                .contentShape(Rectangle())
        }
        .accessibilityLabel("Agent file access")
        .accessibilityValue(store.permissionMode == "sandbox" ? (hasBoundFolder ? "Bound folder" : "No folder bound") :
                            store.permissionMode == "readonly" ? "Read-only" : "Full access")
    }

    private func permissionChoice(_ mode: String, _ label: String, _ symbol: String) -> some View {
        Button {
            store.setPermissionMode(mode)
        } label: {
            Label(label, systemImage: store.permissionMode == mode ? "checkmark" : symbol)
        }
    }

    // MARK: - Input

    private var inputRow: some View {
        HStack(alignment: .bottom, spacing: 8) {
            if inputFocused {
                Menu {
                    Button("Attach file", systemImage: "paperclip") { showFilePicker = true }
                    Button("Attach photo", systemImage: "photo") { showPhotoPicker = true }
                    Button("Dictate", systemImage: "mic.fill") { toggleVoice() }
                } label: { composerIcon("plus.circle.fill") }
                    .accessibilityLabel("Add attachment or voice")
            } else {
                Button { showFilePicker = true } label: { composerIcon("paperclip") }
                    .buttonStyle(.plain)
                    .accessibilityLabel("Attach file")

                PhotosPicker(selection: $selectedPhoto, matching: .images) { composerIcon("photo") }
                    .accessibilityLabel("Attach photo")

                Button(action: toggleVoice) {
                    Image(systemName: voice.isRecording ? "stop.circle.fill" : "mic.fill")
                        .font(.headline)
                        .foregroundStyle(voice.isRecording ? Color.red : Color.white.opacity(0.85))
                        .frame(width: 44, height: 44)
                        .contentShape(Rectangle())
                }
                .buttonStyle(.plain)
                .accessibilityLabel(voice.isRecording ? "Stop dictation" : "Dictate")
            }

            TextField("Message JoeBro", text: Bindable(store).draft, axis: .vertical)
                .lineLimit(1...5)
                .focused($inputFocused)
                .foregroundStyle(.white)
                .padding(.horizontal, 14)
                .padding(.vertical, 11)
                .background(.white.opacity(0.09), in: RoundedRectangle(cornerRadius: 18, style: .continuous))
                .overlay(RoundedRectangle(cornerRadius: 18, style: .continuous).strokeBorder(.white.opacity(0.14)))

            Button {
                if store.busy { Task { await store.stopCurrentTurn() } }
                else { store.send() }
            } label: {
                Image(systemName: store.busy ? (store.stopping || store.stopRequested ? "ellipsis" : "stop.fill") : "arrow.up")
                    .font(.headline.bold())
                    .foregroundStyle(.black)
                    .frame(width: 44, height: 44)
                    .background(store.busy || canSend ? Color.accentTint : Color.white.opacity(0.25), in: Circle())
                    .contentShape(Circle())
            }
            .buttonStyle(.plain)
            .disabled(store.busy ? store.stopping || store.stopRequested : !canSend)
            .accessibilityLabel(store.busy ? (store.stopRequested ? "Stop requested" : "Stop response") : "Send message")
        }
    }

    private func composerIcon(_ symbol: String) -> some View {
        Image(systemName: symbol)
            .font(.headline)
            .foregroundStyle(.white.opacity(0.85))
            .frame(width: 44, height: 44)
            .contentShape(Rectangle())
    }

    private func toggleVoice() {
        if voice.isRecording {
            voice.stop()
            store.draft = [store.draft, voice.transcript].filter { !$0.isEmpty }.joined(separator: " ")
        } else {
            Task { await voice.start() }
        }
    }

    // MARK: - Status strip

    @ViewBuilder
    private var status: some View {
        if store.uploadingAttachment {
            HStack(spacing: 7) {
                ProgressView().controlSize(.mini).tint(.accentTint)
                Text("Uploading attachment…").font(.caption).foregroundStyle(.secondary)
            }
            .frame(maxWidth: .infinity, alignment: .leading)
        }
        ForEach(store.pendingAttachments) { attachment in
            HStack(spacing: 6) {
                Label(attachment.name, systemImage: "paperclip")
                    .font(.caption).foregroundStyle(.white.opacity(0.8)).lineLimit(1)
                Spacer(minLength: 4)
                Button {
                    store.pendingAttachments.removeAll { $0.id == attachment.id }
                } label: {
                    Image(systemName: "xmark.circle.fill")
                        .foregroundStyle(.white.opacity(0.6))
                        .frame(width: 44, height: 30)
                        .contentShape(Rectangle())
                }
                .buttonStyle(.plain)
                .accessibilityLabel("Remove attachment \(attachment.name)")
            }
            .frame(maxWidth: .infinity, alignment: .leading)
        }
        if voice.isRecording {
            HStack(spacing: 6) {
                Image(systemName: "waveform").symbolEffect(.variableColor.iterative)
                Text("Listening on this iPhone…")
            }
            .font(.caption).foregroundStyle(.mint)
            .frame(maxWidth: .infinity, alignment: .leading)
        }
    }
}

/// Endpoint-grouped model menu, same ordering rule as the Mac's
/// `ModelMenuItems`: local machines first, then by endpoint name.
struct ChatModelPicker: View {
    let store: ChatStore

    private var grouped: [(endpoint: String, models: [JBModelChoice])] {
        var order: [String] = []
        var buckets: [String: [JBModelChoice]] = [:]
        for model in store.models {
            if buckets[model.endpointName] == nil { order.append(model.endpointName) }
            buckets[model.endpointName, default: []].append(model)
        }
        order.sort { a, b in
            let localA = buckets[a]?.first?.category == "local"
            let localB = buckets[b]?.first?.category == "local"
            if localA != localB { return localA }
            return a.localizedCaseInsensitiveCompare(b) == .orderedAscending
        }
        return order.map { ($0, buckets[$0] ?? []) }
    }

    var body: some View {
        Menu {
            ForEach(grouped, id: \.endpoint) { group in
                Section(group.endpoint) {
                    ForEach(group.models) { model in
                        Button { store.pickModel(model) } label: {
                            Label {
                                Text(model.display)
                            } icon: {
                                ProviderLogoView(model: model.modelID, size: 15)
                            }
                        }
                    }
                }
            }
            if store.models.isEmpty {
                Text("No models reachable — check Settings")
            }
            Divider()
            Button("Refresh models", systemImage: "arrow.clockwise") {
                Task { await store.refreshModels() }
            }
        } label: {
            HStack(spacing: 5) {
                ProviderLogoView(model: store.selectedModel?.modelID ?? "", size: 15)
                Text(store.selectedModel?.display ?? (store.models.isEmpty ? "No model" : "Select model"))
                    .lineLimit(1)
                Image(systemName: "chevron.up.chevron.down").font(.system(size: 8, weight: .bold))
            }
            .font(.caption.weight(.semibold))
            .foregroundStyle(.white)
            .padding(.horizontal, 11)
            .frame(height: 44)
            .background(.white.opacity(0.09), in: Capsule())
            .overlay(Capsule().strokeBorder(.white.opacity(0.14)))
            .contentShape(Capsule())
        }
        .accessibilityLabel("Chat model")
        .accessibilityValue(store.selectedModel?.display ?? "None selected")
    }
}
