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
    @AppStorage("backgroundAnimation") private var backgroundAnimation = BackgroundAnimation.off.rawValue

    var body: some View {
        NavigationStack {
            Form {
                connectionSection
                appearanceSection
                notificationsSection
                agentsSection
                personalSection
                privacySection
            }
            .scrollContentBackground(.hidden)
            .foregroundStyle(JB.ink)
            .tint(JB.accent)
            .toggleStyle(JBSwitchStyle())
            .background(WallpaperBackground(theme: theme))
            .navigationTitle("Settings")
            .navigationBarTitleDisplayMode(.inline)
            .toolbar { ToolbarItem(placement: .topBarTrailing) { Button("Done") { dismiss() } } }
        }
    }

    private func group<C: View>(_ title: String, @ViewBuilder _ content: () -> C) -> some View {
        Section {
            content().jbRow()
        } header: {
            JBSectionHeader(title)
        }
    }

    // MARK: Connection

    private var connectionSection: some View {
        group("Connection") {
            LabeledContent("Name") { Text(DemoMode.active ? "Demo" : ServerConfig.name.isEmpty ? "Unnamed" : ServerConfig.name).font(.jb(13)) }
            LabeledContent("URL") { Text(DemoMode.active ? "Sample data" : ServerConfig.urlString).font(.jb(13)).lineLimit(1) }
            LabeledContent("Status") {
                HStack(spacing: 6) {
                    JBStatusDot(color: statusColor, live: connectionStatus == "Connected", size: 6)
                    Text(connectionStatus).font(.jb(13))
                }
            }
            Button("Test connection") { Task { await testConnection() } }
            Button("Pair again") { repairing = true }
            Button(DemoMode.active ? "Leave the demo" : "Forget this backend", role: .destructive) { confirmForget = true }
        }
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

    private var statusColor: Color {
        switch connectionStatus {
        case "Connected": JB.live
        case "Checking…", "Not checked": JB.ink3
        default: JB.danger
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

    // MARK: Appearance

    private var appearance: JBAppearance { .shared }

    private var backdropChoice: JBBackdropKind {
        if theme.wallpaperName == "photo" { return .photo }
        return appearance.backdrop == .scene && backgroundAnimation != BackgroundAnimation.off.rawValue ? .scene : .palette
    }

    private var appearanceSection: some View {
        Group {
            group("Background") {
                paletteSwatches
                PhotosPicker(selection: $selectedPhoto, matching: .images) {
                    HStack {
                        Text(theme.wallpaperName == "photo" ? "Change photo" : "Use a photo")
                        Spacer()
                        if theme.wallpaperName == "photo" { Image(systemName: "checkmark").foregroundStyle(JB.accent) }
                    }
                }
                .onChange(of: selectedPhoto) { _, item in
                    Task {
                        if let data = try? await item?.loadTransferable(type: Data.self) {
                            theme.setWallpaper(data: data)
                            appearance.backdrop = .photo
                        }
                    }
                }
                if theme.wallpaperName == "photo" {
                    Button("Remove photo", role: .destructive) {
                        appearance.backdrop = .palette
                        theme.select(appearance.palette.rawValue)
                    }
                }
                VStack(alignment: .leading, spacing: 6) {
                    HStack {
                        Text("Panel opacity")
                        Spacer()
                        Text("\(Int(appearance.solidity * 100))%").font(.jb(13)).foregroundStyle(JB.ink2)
                    }
                    Slider(value: Binding(get: { appearance.solidity }, set: { appearance.solidity = $0 }), in: 0.35...1)
                }
            }
            group("Banner") {
                Picker("Animation", selection: $backgroundAnimation) {
                    Text("Off").tag(BackgroundAnimation.off.rawValue)
                    ForEach(BackgroundAnimation.allCases.filter { $0 != .off }) { Text($0.label).tag($0.rawValue) }
                }
                .pickerStyle(.menu)
            }
            group("JoeBro") {
                ColorPicker("Colour", selection: Binding(get: { theme.joeBroColor },
                                                         set: { theme.setJoeBroColor($0) }),
                            supportsOpacity: false)
            }
        }
        .sensoryFeedback(.selection, trigger: appearance.palette)
    }

    private func setBackdrop(_ kind: JBBackdropKind) {
        switch kind {
        case .palette:
            appearance.backdrop = .palette
            if theme.wallpaperName == "photo" { theme.select(appearance.palette.rawValue) }
        case .photo:
            appearance.backdrop = .photo
            if theme.wallpaper != nil { theme.select("photo") }
            else { theme.wallpaperName = "photo" }
        case .scene:
            appearance.backdrop = .scene
            if theme.wallpaperName == "photo" { theme.select(appearance.palette.rawValue) }
            if backgroundAnimation == BackgroundAnimation.off.rawValue {
                backgroundAnimation = BackgroundAnimation.allCases.first { $0 != .off }?.rawValue ?? "off"
            }
        }
    }

    private var paletteSwatches: some View {
        ScrollView(.horizontal, showsIndicators: false) {
            HStack(spacing: 12) {
                ForEach(JBPalette.allCases) { p in
                    let on = appearance.palette == p
                    Button {
                        appearance.palette = p
                        if p != .auto {
                            appearance.backdrop = .palette
                            if theme.wallpaperName == "photo" { theme.select(p.rawValue) }
                        }
                    } label: {
                        JBPaletteSwatch(palette: p, size: 30)
                        .overlay(Circle().strokeBorder(JB.lineStrong, lineWidth: 1))
                        .padding(3)
                        .overlay(Circle().strokeBorder(on ? JB.ink : .clear, lineWidth: 1.5))
                    }
                    .buttonStyle(.plain)
                    .accessibilityLabel(p.label)
                    .accessibilityAddTraits(on ? .isSelected : [])
                }
            }
            .padding(.vertical, 2)
        }
    }

    // MARK: Notifications

    private var notificationsSection: some View {
        group("Notifications") {
            LabeledContent("Push") { Text(push.status).font(.jb(12)).foregroundStyle(JB.ink2).multilineTextAlignment(.trailing) }
            if push.enabled {
                Button("Refresh registration") { Task { await push.refresh() } }
                Button("Disable push", role: .destructive) { Task { await push.disable() } }
            } else {
                Button("Enable push") { Task { await push.enable() } }
            }
            Toggle("Hide previews", isOn: $hideNotificationPreviews)
                .onChange(of: hideNotificationPreviews) { _, _ in Task { await push.syncRegistration() } }
            Button("iPhone notification settings") {
                if let url = URL(string: UIApplication.openNotificationSettingsURLString) { UIApplication.shared.open(url) }
            }
        }
        .sensoryFeedback(.selection, trigger: hideNotificationPreviews)
    }

    // MARK: Agents

    private var agentsSection: some View {
        group("Agents") {
            modelRow
            Toggle("Subagents: JoeBro chooses", isOn: Binding(get: { subagentAuto },
                                 set: { value in subagentAuto = value; Task { await saveSubagentAuto(value) } }))
            subagentModelRow
                .disabled(subagentAuto)
                .opacity(subagentAuto ? 0.4 : 1)
            ProactiveRows(api: client())
            NavigationLink {
                JoeBroSoulView(api: client())
            } label: {
                HStack(spacing: 8) { JBIcon(.agent, size: 15); Text("Soul") }
            }
            if let note = modelsNote ?? subagentNote {
                Text(note).font(.jb(11)).foregroundStyle(JB.ink3)
            }
        }
        .sensoryFeedback(.selection, trigger: subagentAuto)
        .task { await loadModels() }
    }

    @ViewBuilder private var modelRow: some View {
        if models.isEmpty {
            LabeledContent("Default model") {
                if loadingModels { JBSpinner() } else { Text("Unavailable").foregroundStyle(JB.ink3) }
            }
        } else {
            HStack(spacing: 10) {
                if let current = models.first(where: { $0.id == defaultModelID }) {
                    ProviderLogoView(model: current.modelID, size: 18)
                        .foregroundStyle(JB.ink)
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

    @ViewBuilder private var subagentModelRow: some View {
        if models.isEmpty {
            LabeledContent("Subagent model") { Text(loadingModels ? "Loading…" : "Unavailable").foregroundStyle(JB.ink3) }
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
            subagentNote = nil
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
            subagentNote = nil
        } catch {
            subagentNote = "Could not save: \(error.localizedDescription)"
        }
    }

    // MARK: Personal

    private var personalSection: some View {
        group("Personal") {
            LocationToggleRow()
            #if PERSONAL
            AppleRemindersRows()
            #endif
            HealthRows(api: client())
        }
    }

    // MARK: Privacy

    private var privacySection: some View {
        group("Privacy") {
            Toggle("Require Face ID", isOn: $faceIDGate)
        }
        .sensoryFeedback(.selection, trigger: faceIDGate)
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
            modelsNote = nil
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
                    JBSpinner().frame(maxWidth: .infinity, alignment: .leading)
                } else {
                    ZStack(alignment: .topLeading) {
                        if soul.isEmpty {
                            Text("How should JoeBro sound and behave with you?")
                                .foregroundStyle(JB.ink3)
                                .padding(.top, 8)
                                .padding(.leading, 5)
                        }
                        TextEditor(text: $soul)
                            .frame(minHeight: 220)
                            .scrollContentBackground(.hidden)
                    }
                    Text("\(soul.count) / 4,000")
                        .font(.jb(11))
                        .foregroundStyle(soul.count > 4000 ? JB.danger : JB.ink3)
                        .frame(maxWidth: .infinity, alignment: .trailing)
                }
            }
            .jbRow()

            if let error {
                Section { Text(error).foregroundStyle(JB.danger) }.jbRow()
            }
        }
        .scrollContentBackground(.hidden)
        .foregroundStyle(JB.ink)
        .tint(JB.accent)
        .navigationTitle("Soul")
        .navigationBarTitleDisplayMode(.inline)
        .toolbar {
            ToolbarItem(placement: .topBarTrailing) {
                Button(saved ? "Saved" : "Save") { Task { await save() } }
                    .disabled(loading || saving || soul == savedSoul || soul.count > 4000)
            }
        }
        .sensoryFeedback(.success, trigger: saved) { _, new in new }
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
