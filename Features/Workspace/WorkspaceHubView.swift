import SwiftUI

/// The Workspace tab: one hub listing everything the Mac app keeps in its
/// sidebar's Workspace section, each row pushing a detail screen.
struct WorkspaceHubView: View {
    let api: JoeBroAPI
    @State private var ws: WorkspaceAPI
    #if DEBUG
    /// `-JoeBroScreen tasks|memory|brain|inbox` opens that screen at launch (screenshots).
    @State private var debugOpen = false
    @ViewBuilder private var debugScreen: some View {
        switch DemoMode.option("-JoeBroScreen") ?? "" {
        case "tasks": TasksView(ws: ws)
        case "memory": MuseView(ws: ws)
        case "brain": BrainView(api: api, ws: ws)
        case "night": NightShiftView(ws: ws)
        case "sharedmemory": SharedMemoryView(ws: ws)
        case "models": DemoModelList(api: api)
        default: MobileNotificationInbox(api: api)
        }
    }
    #endif
    var onOpenSettings: () -> Void = {}

    init(api: JoeBroAPI, onOpenSettings: @escaping () -> Void = {}) {
        self.api = api
        self.onOpenSettings = onOpenSettings
        _ws = State(initialValue: WorkspaceAPI(baseURL: api.baseURL, token: ServerConfig.token))
    }

    var body: some View {
        NavigationStack {
            List {
                Section {
                    row("envelope", "Email") { EmailView(api: api) }
                    row("calendar", "Calendar") { CalendarAgendaView(api: api) }
                    row("cart", "Shopping") { ShoppingListView(api: api) }
                } header: { JBSectionHeader("Mail & calendar") }
                Section {
                    row("bell", "Notifications") { MobileNotificationInbox(api: api) }
                    row(.research, "Research") { ResearchView(api: api, ws: ws) }
                    row(.nightShift, "Night Shift") { NightShiftView(ws: ws) }
                    row(.tasks, "Tasks") { TasksView(ws: ws) }
                } header: { JBSectionHeader("Work") }
                Section {
                    row(.memory, "Memory") { SharedMemoryView(ws: ws) }
                    row(.memory, Flavor.brainTitle) { BrainView(api: api, ws: ws) }
                    row(.agent, Flavor.memoryTitle) { MuseView(ws: ws) }
                    row(.skills, "Skills") { SkillsView(ws: ws) }
                    row(.tools, "Tools") { ToolsView(ws: ws) }
                    row("checkmark.shield", "AI Check") { AICheckView(ws: ws) }
                } header: { JBSectionHeader("Knowledge") }
            }
            .listStyle(.insetGrouped)
        .jbForm()
            .navigationTitle("Workspace")
            .navigationBarTitleDisplayMode(.inline)
            #if DEBUG
            .navigationDestination(isPresented: $debugOpen) { debugScreen }
            .task { if DemoMode.option("-JoeBroScreen") != nil { debugOpen = true } }
            #endif
            .toolbar {
                ToolbarItem(placement: .topBarTrailing) {
                    Button { onOpenSettings() } label: {
                        Image(systemName: "gearshape")
                            .foregroundStyle(JB.ink2)
                            .frame(width: 44, height: 44)
                    }
                    .accessibilityLabel("Settings")
                }
            }
        }
    }

    /// Destination-builder links, not `NavigationLink(value:)`. A pushed screen
    /// that declares its own `navigationDestination(for:)` would otherwise fight
    /// the hub's destination table and the row would simply not open.
    private func row<Destination: View>(_ symbol: String, _ title: String,
                                        @ViewBuilder destination: () -> Destination) -> some View {
        link(title, icon: Image(systemName: symbol).font(.jb(16)), destination: destination)
    }

    private func row<Destination: View>(_ glyph: JBGlyph, _ title: String,
                                        @ViewBuilder destination: () -> Destination) -> some View {
        link(title, icon: JBIcon(glyph, size: 17), destination: destination)
    }

    private func link<Icon: View, Destination: View>(_ title: String, icon: Icon,
                                                     @ViewBuilder destination: () -> Destination) -> some View {
        NavigationLink(destination: destination()) {
            HStack(spacing: 13) {
                icon
                    .foregroundStyle(JB.ink2)
                    .frame(width: 28)
                Text(title).foregroundStyle(JB.ink)
            }
            .frame(minHeight: 44)
        }
        .listRowBackground(JB.panelFill)
        .listRowSeparatorTint(JB.line)
    }
}

// MARK: - Shared helpers

/// `Optional` state doubling as "is a sheet/alert/dialog showing".
func alertBinding<T>(_ source: Binding<T?>) -> Binding<Bool> {
    Binding(get: { source.wrappedValue != nil }, set: { if !$0 { source.wrappedValue = nil } })
}

@ViewBuilder
func empty(_ symbol: String, _ title: String, _ detail: String = "") -> some View {
    VStack(spacing: 12) {
        Text(JBEmptyState.drawing(.inbox)).font(.jbMono(12)).foregroundStyle(JB.ink3).fixedSize()
        Text(title).font(.jb(13)).foregroundStyle(JB.ink2)
    }
    .frame(maxWidth: .infinity).padding(.vertical, 40)
    .listRowBackground(Color.clear)
}

/// The dot every toggleable row leads with, so "on" reads at a glance without
/// relying on the switch alone.
struct WSStatusDot: View {
    let on: Bool
    var body: some View {
        JBStatusDot(color: on ? JB.live : JB.ink3, size: 7)
            .accessibilityLabel(on ? "Enabled" : "Disabled")
    }
}

/// A switch that always has a visible tint and never inherits white.
struct WSToggle: View {
    let label: String
    let isOn: Bool
    let set: (Bool) -> Void

    var body: some View {
        Toggle("", isOn: Binding(get: { isOn }, set: set))
            .labelsHidden()
            .toggleStyle(JBSwitchStyle())
            .sensoryFeedback(.selection, trigger: isOn)
            .accessibilityLabel(label)
    }
}

/// Picker over the three agent access levels, used by tasks, MCP and plugins.
struct WSPermissionPicker: View {
    let title: String
    @Binding var mode: String

    var body: some View {
        Picker(title, selection: $mode) {
            ForEach(WSPermissionMode.allCases) { value in
                Label(value.label, systemImage: value.symbol).tag(value.rawValue)
            }
        }
        .tint(JB.accent)
    }
}

#if DEBUG
/// Demo-only (`-JoeBroScreen models`): the grouped model list the chat picker shows, laid out open for screenshots.
struct DemoModelList: View {
    let api: JoeBroAPI
    @State private var models: [JBModelChoice] = []
    var body: some View {
        List {
            ForEach(Array(Dictionary(grouping: models, by: \.endpointName)).sorted { a, b in
                let la = a.value.first?.category == "local", lb = b.value.first?.category == "local"
                return la != lb ? la : a.key < b.key
            }, id: \.key) { group in
                Section(group.key) {
                    ForEach(group.value) { m in
                        Label { Text(m.display) } icon: { ProviderLogoView(model: m.modelID, size: 18) }
                            .listRowBackground(JB.panelFill)
                    }
                }
            }
        }
        .listStyle(.insetGrouped).scrollContentBackground(.hidden).jbWallpaper()
        .navigationTitle("Choose model").navigationBarTitleDisplayMode(.inline)
        .task { models = (try? await api.models()) ?? [] }
    }
}
#endif
