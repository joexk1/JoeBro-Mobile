import SwiftUI
import PhotosUI
import LocalAuthentication

struct MobileSettingsView: View {
    @State private var push = MobilePushNotifications.shared
    @State private var models: [JBModelChoice] = []
    @State private var defaultModelID = ""
    @State private var subagentModelID = ""
    @State private var subagentAuto = false
    @State private var subagentNote: String?
    @State private var loadingModels = true
    @State private var modelsNote: String?
    let theme: JoeBroTheme
    var onRepaired: () -> Void = {}
    var onForgotten: () -> Void = {}
    @State private var confirmForget = false
    @State private var repairing = false
    @Environment(\.dismiss) private var dismiss
    @State private var selectedPhoto: PhotosPickerItem?
    @State private var connectionStatus = "Not checked"
    @AppStorage("faceIDGate") private var faceIDGate = false
    @AppStorage("hideNotificationPreviews") private var hideNotificationPreviews = true

    var body: some View {
        NavigationStack {
            Form {
                connectionSection
                modelSection
                subagentSection
                joeBroSection
                appearanceSection
                pushSection
                privacySection
            }
            .scrollContentBackground(.hidden)
            .background(WallpaperBackground(theme: theme))
            .navigationTitle("Settings")
            .navigationBarTitleDisplayMode(.inline)
            .toolbar { ToolbarItem(placement: .topBarTrailing) { Button("Done") { dismiss() } } }
        }
    }

    // MARK: Connection

    private var connectionSection: some View {
        Section {
            LabeledContent("Name", value: ServerConfig.name.isEmpty ? "Unnamed" : ServerConfig.name)
            LabeledContent("URL", value: ServerConfig.urlString)
            LabeledContent("Status", value: connectionStatus)
            Button { Task { await testConnection() } } label: {
                Label("Test connection", systemImage: "antenna.radiowaves.left.and.right")
            }
            Button { repairing = true } label: {
                Label("Pair again", systemImage: "qrcode.viewfinder")
            }
            Button(role: .destructive) { confirmForget = true } label: {
                Label("Forget this backend", systemImage: "trash")
            }
        } header: {
            Text("Your backend")
        } footer: {
            Text("The app keeps recent content visible when it cannot connect. Away from home, Tailscale on both devices is the simplest way to stay reachable.")
        }
        .listRowBackground(Color.white.opacity(0.06))
        .task { await testConnection() }
        .fullScreenCover(isPresented: $repairing) {
            OnboardingView(theme: theme, allowCancel: true,
                           onPaired: { repairing = false; onRepaired() },
                           onCancel: { repairing = false })
        }
        .confirmationDialog("Forget this backend?", isPresented: $confirmForget, titleVisibility: .visible) {
            Button("Forget", role: .destructive) { Task { await forget() } }
        } message: {
            Text("This removes the saved URL and token and turns off push for this phone.")
        }
    }

    private func forget() async {
        if push.enabled { await push.disable() }
        ServerConfig.forget()
        onForgotten()
    }

    private func testConnection() async {
        guard let api = ServerConfig.api() else { connectionStatus = "Not paired"; return }
        connectionStatus = "Checking…"
        do { connectionStatus = try await api.ping() ? "Connected" : "Unavailable" }
        catch { connectionStatus = "Unreachable" }
    }

    // MARK: Model

    private var modelSection: some View {
        Section {
            modelRow
            if let note = modelsNote {
                Text(note).font(.caption).foregroundStyle(.secondary)
            }
        } header: {
            Text("Model")
        } footer: {
            Text("Used for new chats and for agents that don't pick their own.")
        }
        .listRowBackground(Color.white.opacity(0.06))
        .task { await loadModels() }
    }

    @ViewBuilder private var modelRow: some View {
        if models.isEmpty {
            LabeledContent("Default model") {
                if loadingModels { ProgressView().controlSize(.small) }
                else { Text("Unavailable") }
            }
        } else {
            HStack(spacing: 10) {
                if let current = models.first(where: { $0.id == defaultModelID }) {
                    ProviderLogoView(model: current.modelID, size: 18)
                        .foregroundStyle(.white)
                }
                Picker("Default model", selection: $defaultModelID) {
                    Text("Not set").tag("")
                    ForEach(models) { choice in
                        Text(choice.display).tag(choice.id)
                    }
                }
                .onChange(of: defaultModelID) { _, id in Task { await saveDefaultModel(id) } }
            }
        }
    }

    // MARK: Subagents

    private var subagentSection: some View {
        Section {
            Toggle(isOn: Binding(get: { subagentAuto },
                                 set: { value in subagentAuto = value; Task { await saveSubagentAuto(value) } })) {
                Label("Let JoeBro choose", systemImage: "wand.and.stars")
            }
            subagentModelRow
                .disabled(subagentAuto)
                .opacity(subagentAuto ? 0.4 : 1)
            if let note = subagentNote {
                Text(note).font(.caption).foregroundStyle(.secondary)
            }
        } header: {
            Text("Subagents")
        } footer: {
            Text("Subagents are helpers JoeBro spawns for side tasks. When JoeBro chooses, it picks a model for each task and the fixed model below is not used.")
        }
        .tint(Color.accentTint)
        .listRowBackground(Color.white.opacity(0.06))
    }

    @ViewBuilder private var subagentModelRow: some View {
        if models.isEmpty {
            LabeledContent("Subagent model") { Text(loadingModels ? "Loading…" : "Unavailable") }
        } else {
            Picker("Subagent model", selection: $subagentModelID) {
                Text("Same as default").tag("")
                ForEach(models) { choice in
                    Text(choice.display).tag(choice.id)
                }
            }
            .onChange(of: subagentModelID) { _, id in Task { await saveSubagentModel(id) } }
        }
    }

    private func saveSubagentAuto(_ on: Bool) async {
        guard let api = client() else { return }
        do {
            try await api.setPreference("subagent_model_auto", value: on ? "true" : "false")
            subagentNote = on ? "JoeBro will choose per task." : "Subagents use the fixed model."
        } catch {
            subagentNote = "Could not save: \(error.localizedDescription)"
        }
    }

    private func saveSubagentModel(_ id: String) async {
        guard let api = client() else { return }
        let choice = models.first { $0.id == id }
        do {
            try await api.setPreference("subagent_model", value: choice?.modelID)
            try await api.setPreference("subagent_endpoint_id", value: choice?.endpointID)
            subagentNote = choice.map { "Subagents use \($0.display)." } ?? "Subagent model cleared."
        } catch {
            subagentNote = "Could not save: \(error.localizedDescription)"
        }
    }

    // MARK: JoeBro

    private var joeBroSection: some View {
        Section {
            NavigationLink {
                JoeBroSoulView(api: client())
            } label: {
                Label("Soul", systemImage: "sparkle")
            }
            LocationToggleRow()
        } header: {
            Text("JoeBro")
        } footer: {
            Text("Soul sets how JoeBro sounds and behaves in every new turn.")
        }
        .listRowBackground(Color.white.opacity(0.06))
    }

    // MARK: Appearance

    private var appearanceSection: some View {
        Section {
            ColorPicker(selection: Binding(get: { theme.joeBroColor },
                                           set: { theme.setJoeBroColor($0) }),
                        supportsOpacity: false) {
                Label("JoeBro colour", systemImage: "paintpalette")
            }
            wallpaperSwatches
            PhotosPicker(selection: $selectedPhoto, matching: .images) {
                Label("Choose photo wallpaper", systemImage: "photo.on.rectangle")
            }
            .onChange(of: selectedPhoto) { _, item in
                Task { if let data = try? await item?.loadTransferable(type: Data.self) { theme.setWallpaper(data: data) } }
            }
            if theme.wallpaperName == "photo" {
                Button { theme.select(BackgroundPreset.purple.rawValue) } label: {
                    Label("Use a colour wallpaper instead", systemImage: "circle.lefthalf.filled")
                }
            }
        } header: {
            Text("Appearance")
        } footer: {
            Text("Pick a colour wallpaper or use one of your own photos.")
        }
        .listRowBackground(Color.white.opacity(0.06))
    }

    private var wallpaperSwatches: some View {
        HStack(spacing: 12) {
            ForEach(BackgroundPreset.allCases) { preset in
                Button { theme.select(preset.rawValue) } label: {
                    Circle()
                        .fill(LinearGradient(colors: preset.colors, startPoint: .topLeading, endPoint: .bottomTrailing))
                        .frame(width: 43, height: 43)
                        .overlay(Circle().stroke(.white, lineWidth: theme.wallpaperName == preset.rawValue ? 3 : 0))
                }
                .buttonStyle(.plain)
                .accessibilityLabel(preset.label + " wallpaper")
            }
        }
    }

    private var pushSection: some View {
        Section {
            Text(push.status).font(.footnote).foregroundStyle(.secondary)
            if push.enabled {
                Button("Refresh push registration") { Task { await push.refresh() } }
                Button("Disable push notifications", role: .destructive) { Task { await push.disable() } }
            } else {
                Button { Task { await push.enable() } } label: {
                    Label("Enable push notifications", systemImage: "bell.badge")
                }
            }
            Button("Open iPhone notification settings") {
                if let url = URL(string: UIApplication.openNotificationSettingsURLString) { UIApplication.shared.open(url) }
            }
        } header: {
            Text("Push notifications")
        } footer: {
            Text("Ask JoeBro to notify you about reminders, finished tasks, or changes you want watched. Hidden previews keep message text out of the lock screen.")
        }
        .listRowBackground(Color.white.opacity(0.06))
    }

    // MARK: Privacy

    private var privacySection: some View {
        Section {
            Toggle("Require Face ID", isOn: $faceIDGate)
            Toggle("Hide notification previews", isOn: $hideNotificationPreviews)
                .onChange(of: hideNotificationPreviews) { _, _ in Task { await push.syncRegistration() } }
        } header: {
            Text("Privacy & Security")
        } footer: {
            Text("Face ID protects this app's screen. Backend access uses the token you paired with.")
        }
        .listRowBackground(Color.white.opacity(0.06))
    }

    private func client() -> JoeBroAPI? {
        ServerConfig.api()
    }

    private func loadModels() async {
        guard models.isEmpty, let api = client() else { loadingModels = false; return }
        loadingModels = true
        defer { loadingModels = false }
        models = (try? await api.models()) ?? []
        guard let prefs = try? await api.preferences() else { return }
        // The default is only meaningful when both halves are present.
        if let model = prefs["default_model"], let endpoint = prefs["default_endpoint_id"],
           !model.isEmpty, !endpoint.isEmpty {
            defaultModelID = model + "@" + endpoint
        }
        subagentAuto = prefs["subagent_model_auto"] == "true"
        if let model = prefs["subagent_model"], let endpoint = prefs["subagent_endpoint_id"],
           !model.isEmpty, !endpoint.isEmpty {
            subagentModelID = model + "@" + endpoint
        }
    }

    private func saveDefaultModel(_ id: String) async {
        guard let api = client() else { return }
        let choice = models.first { $0.id == id }
        do {
            try await api.setPreference("default_model", value: choice?.modelID)
            try await api.setPreference("default_endpoint_id", value: choice?.endpointID)
            modelsNote = choice.map { "Default is \($0.display)." } ?? "Default cleared."
        } catch {
            modelsNote = "Could not save: \(error.localizedDescription)"
        }
    }

}

private struct JoeBroSoulView: View {
    let api: JoeBroAPI?
    @State private var soul = ""
    @State private var savedSoul = ""
    @State private var loading = true
    @State private var saving = false
    @State private var error: String?
    @State private var saved = false

    var body: some View {
        Form {
            Section {
                if loading {
                    ProgressView("Loading Soul…")
                        .frame(maxWidth: .infinity, alignment: .leading)
                } else {
                    ZStack(alignment: .topLeading) {
                        if soul.isEmpty {
                            Text("How should JoeBro sound and behave with you?")
                                .foregroundStyle(.secondary)
                                .padding(.top, 8)
                                .padding(.leading, 5)
                        }
                        TextEditor(text: $soul)
                            .frame(minHeight: 220)
                            .scrollContentBackground(.hidden)
                    }
                    Text("\(soul.count) / 4,000")
                        .font(.caption.monospacedDigit())
                        .foregroundStyle(soul.count > 4000 ? .red : .secondary)
                        .frame(maxWidth: .infinity, alignment: .trailing)
                }
            } footer: {
                Text("JoeBro uses this voice, these priorities and this working style in every new turn. Tool permissions stay separate.")
            }

            if let error {
                Section { Text(error).foregroundStyle(.red) }
            }
        }
        .scrollContentBackground(.hidden)
        .navigationTitle("Soul")
        .navigationBarTitleDisplayMode(.inline)
        .toolbar {
            ToolbarItem(placement: .topBarTrailing) {
                Button(saved ? "Saved" : "Save") { Task { await save() } }
                    .disabled(loading || saving || soul == savedSoul || soul.count > 4000)
            }
        }
        .onChange(of: soul) { _, _ in saved = false }
        .task { await load() }
    }

    private func load() async {
        defer { loading = false }
        guard let api else { error = "Set a valid backend URL first."; return }
        do {
            soul = try await api.joeBroProfile().soul
            savedSoul = soul
        } catch { self.error = error.localizedDescription }
    }

    private func save() async {
        guard let api else { return }
        saving = true
        defer { saving = false }
        do {
            try await api.saveJoeBroSoul(soul)
            savedSoul = soul
            saved = true
            error = nil
        } catch { self.error = error.localizedDescription }
    }
}
