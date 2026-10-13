import SwiftUI

/// The Workspace tab: one hub listing everything the Mac app keeps in its
/// sidebar's Workspace section, each row pushing a detail screen.
struct WorkspaceHubView: View {
    let api: JoeBroAPI
    @State private var ws: WorkspaceAPI
    @State private var hasEntered = false
    @Environment(\.accessibilityReduceMotion) private var reduceMotion
    var onOpenSettings: () -> Void = {}

    init(api: JoeBroAPI, onOpenSettings: @escaping () -> Void = {}) {
        self.api = api
        self.onOpenSettings = onOpenSettings
        _ws = State(initialValue: WorkspaceAPI(baseURL: api.baseURL, token: ServerConfig.token))
    }

    var body: some View {
        NavigationStack {
            List {
                Section("Mail & calendar") {
                    row("envelope", "Email", "Read your inbox") { EmailView(api: api) }
                    row("calendar", "Calendar", "Today and what's coming") { CalendarAgendaView(api: api) }
                }
                Section("Work") {
                    row("bell", "Notifications", "Reminders and updates from JoeBro") { MobileNotificationInbox(api: api) }
                    row("magnifyingglass", "Research", "Deep research runs and reports") { ResearchView(api: api, ws: ws) }
                    row("clock.arrow.circlepath", "Tasks", "Prompts on a schedule") { TasksView(ws: ws) }
                }
                Section("Knowledge") {
                    row("brain", "Brain", "What JoeBro remembers") { BrainView(api: api, ws: ws) }
                    row("person.text.rectangle", "Memory", "Notes JoeBro keeps about you") { MuseView(ws: ws) }
                    row("sparkles", "Skills", "Learned procedures") { SkillsView(ws: ws) }
                    row("wrench.and.screwdriver", "Tools", "APIs, MCP servers, plugins") { ToolsView(ws: ws) }
                    row("checkmark.shield", "AI Check", "Score text for AI likelihood") { AICheckView(ws: ws) }
                }
            }
            .listStyle(.insetGrouped)
            .scrollContentBackground(.hidden)
            .jbWallpaper()
            .navigationTitle("Workspace")
            .navigationBarTitleDisplayMode(.inline)
            .onAppear { hasEntered = true }
            .toolbar {
                ToolbarItem(placement: .topBarTrailing) {
                    Button { onOpenSettings() } label: {
                        Image(systemName: "gearshape")
                            .foregroundStyle(Color.accentTint)
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
    private func row<Destination: View>(_ symbol: String, _ title: String, _ subtitle: String,
                                        @ViewBuilder destination: () -> Destination) -> some View {
        NavigationLink(destination: destination()) {
            HStack(spacing: 13) {
                Image(systemName: symbol)
                    .font(.system(size: 17))
                    .foregroundStyle(.white.opacity(0.85))
                    .frame(width: 28)
                    .scaleEffect(reduceMotion || hasEntered ? 1 : 0.92)
                    .opacity(reduceMotion || hasEntered ? 1 : 0.75)
                    .animation(reduceMotion ? nil : .easeOut(duration: 0.18), value: hasEntered)
                VStack(alignment: .leading, spacing: 2) {
                    Text(title).foregroundStyle(.white)
                    Text(subtitle).font(.caption).foregroundStyle(.secondary).lineLimit(1)
                }
            }
            .frame(minHeight: 48)
        }
        .listRowBackground(Color.white.opacity(0.06))
    }
}

// MARK: - Shared helpers

/// `Optional` state doubling as "is a sheet/alert/dialog showing".
func alertBinding<T>(_ source: Binding<T?>) -> Binding<Bool> {
    Binding(get: { source.wrappedValue != nil }, set: { if !$0 { source.wrappedValue = nil } })
}

@ViewBuilder
func empty(_ symbol: String, _ title: String, _ detail: String) -> some View {
    VStack(spacing: 10) {
        Image(systemName: symbol).font(.largeTitle).foregroundStyle(.secondary)
        Text(title).font(.headline).foregroundStyle(.white)
        Text(detail).font(.footnote).foregroundStyle(.secondary).multilineTextAlignment(.center)
    }
    .frame(maxWidth: .infinity).padding(.vertical, 40)
    .listRowBackground(Color.clear)
}

/// The dot every toggleable row leads with, so "on" reads at a glance without
/// relying on the switch alone.
struct WSStatusDot: View {
    let on: Bool
    var body: some View {
        Circle()
            .fill(on ? Color.green : Color.white.opacity(0.25))
            .frame(width: 8, height: 8)
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
            .tint(Color.accentTint)
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
        .tint(Color.accentTint)
    }
}
