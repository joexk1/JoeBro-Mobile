import SwiftUI

/// Everything JoeBro can reach out with: custom API tools, MCP servers and
/// plugins. Each section supports add, edit, enable/disable and delete.
struct ToolsView: View {
    let ws: WorkspaceAPI

    @State private var tools: [WSTool] = []
    @State private var servers: [WSMCPServer] = []
    @State private var plugins: [WSPlugin] = []

    @State private var editingTool: WSTool?
    @State private var editingServer: WSMCPServer?
    @State private var editingPlugin: WSPlugin?
    @State private var creating: Creating?
    @State private var deleting: Deleting?
    @State private var loading = false
    @State private var error: String?

    private enum Creating: String, Identifiable { case tool, server, plugin; var id: String { rawValue } }
    private struct Deleting: Identifiable {
        enum Kind { case tool, server, plugin }
        let id: String
        let kind: Kind
        let name: String
        let consequence: String
    }

    var body: some View {
        List {
            toolsSection
            serversSection
            pluginsSection
        }
        .listStyle(.insetGrouped)
        .scrollContentBackground(.hidden)
        .jbWallpaper()
        .navigationTitle("Tools")
        .navigationBarTitleDisplayMode(.inline)
        .overlay { if loading && tools.isEmpty && servers.isEmpty && plugins.isEmpty { ProgressView().controlSize(.large) } }
        .refreshable { await load() }
        .task { await load() }
        .toolbar {
            ToolbarItem(placement: .topBarTrailing) {
                Menu {
                    Button("New API tool", systemImage: "link") { creating = .tool }
                    Button("New MCP server", systemImage: "server.rack") { creating = .server }
                    Button("New plugin", systemImage: "puzzlepiece.extension") { creating = .plugin }
                } label: {
                    Image(systemName: "plus").foregroundStyle(Color.accentTint)
                }
                .accessibilityLabel("Add tool")
            }
        }
        .sheet(item: $creating) { which in newSheet(which) }
        .sheet(item: $editingTool) { tool in APIToolEditor(ws: ws, tool: tool) { Task { await load() } } }
        .sheet(item: $editingServer) { server in MCPServerEditor(ws: ws, server: server) { Task { await load() } } }
        .sheet(item: $editingPlugin) { plugin in PluginEditor(ws: ws, plugin: plugin) { Task { await load() } } }
        .alert("Delete “\(deleting?.name ?? "")”?",
               isPresented: alertBinding($deleting)) {
            Button("Delete", role: .destructive) {
                if let target = deleting { Task { await remove(target) } }
                deleting = nil
            }
            Button("Keep it", role: .cancel) { deleting = nil }
        } message: {
            Text(deleting?.consequence ?? "")
        }
        .alert("Tools", isPresented: alertBinding($error)) { Button("OK") { error = nil } } message: { Text(error ?? "") }
    }

    @ViewBuilder
    private func newSheet(_ which: Creating) -> some View {
        switch which {
        case .tool: APIToolEditor(ws: ws, tool: nil) { Task { await load() } }
        case .server: MCPServerEditor(ws: ws, server: nil) { Task { await load() } }
        case .plugin: PluginEditor(ws: ws, plugin: nil) { Task { await load() } }
        }
    }

    // MARK: API tools

    private var toolsSection: some View {
        Section("API tools") {
            if tools.isEmpty && !loading {
                empty("link", "No API tools", "Point JoeBro at an HTTP endpoint it can call.")
            }
            ForEach(tools) { tool in
                ToolRow(title: tool.name,
                        subtitle: tool.description.isEmpty ? "\(tool.method) \(tool.baseURL)" : tool.description,
                        detail: tool.hasKey ? "API key saved" : nil,
                        on: tool.isEnabled,
                        toggleLabel: "\(tool.name) enabled") { on in
                    Task { await act { try await ws.setToolEnabled(id: tool.id, on: on) } }
                }
                .listRowBackground(Color.white.opacity(0.06))
                .contentShape(Rectangle())
                .onTapGesture { editingTool = tool }
                .contextMenu {
                    Button("Edit tool", systemImage: "pencil") { editingTool = tool }
                    Button(tool.isEnabled ? "Disable" : "Enable",
                           systemImage: tool.isEnabled ? "pause.circle" : "play.circle") {
                        Task { await act { try await ws.setToolEnabled(id: tool.id, on: !tool.isEnabled) } }
                    }
                    Divider()
                    Button("Delete tool", systemImage: "trash", role: .destructive) {
                        deleting = Deleting(id: tool.id, kind: .tool, name: tool.name,
                                            consequence: "JoeBro loses this API tool permanently. This can't be undone.")
                    }
                }
                .swipeActions(edge: .trailing, allowsFullSwipe: false) {
                    Button("Delete", systemImage: "trash") {
                        deleting = Deleting(id: tool.id, kind: .tool, name: tool.name,
                                            consequence: "JoeBro loses this API tool permanently. This can't be undone.")
                    }.tint(.red)
                    Button("Edit", systemImage: "pencil") { editingTool = tool }.tint(.gray)
                }
            }
        }
    }

    // MARK: MCP servers

    private var serversSection: some View {
        Section("MCP servers") {
            if servers.isEmpty && !loading {
                empty("server.rack", "No MCP servers", "Add a command and JoeBro discovers its tools.")
            }
            ForEach(servers) { server in
                MCPRow(server: server) { on in
                    Task { await act { try await ws.setMCPEnabled(id: server.id, on: on) } }
                }
                .listRowBackground(Color.white.opacity(0.06))
                .contentShape(Rectangle())
                .onTapGesture { editingServer = server }
                .contextMenu {
                    Button("Edit server", systemImage: "pencil") { editingServer = server }
                    Button(server.enabled ? "Disable" : "Enable",
                           systemImage: server.enabled ? "pause.circle" : "play.circle") {
                        Task { await act { try await ws.setMCPEnabled(id: server.id, on: !server.enabled) } }
                    }
                    Divider()
                    Button("Delete server", systemImage: "trash", role: .destructive) {
                        deleting = Deleting(id: server.id, kind: .server, name: server.name,
                                            consequence: "The server and its discovered tools are removed. This can't be undone.")
                    }
                }
                .swipeActions(edge: .trailing, allowsFullSwipe: false) {
                    Button("Delete", systemImage: "trash") {
                        deleting = Deleting(id: server.id, kind: .server, name: server.name,
                                            consequence: "The server and its discovered tools are removed. This can't be undone.")
                    }.tint(.red)
                    Button("Edit", systemImage: "pencil") { editingServer = server }.tint(.gray)
                }
            }
        }
    }

    // MARK: Plugins

    private var pluginsSection: some View {
        Section("Plugins") {
            if plugins.isEmpty && !loading {
                empty("puzzlepiece.extension", "No plugins", "Plugins add tools or guardrails to every turn.")
            }
            ForEach(plugins) { plugin in
                ToolRow(title: plugin.name,
                        subtitle: plugin.description.isEmpty ? plugin.repoPath : plugin.description,
                        detail: "\(plugin.kind.capitalized) · \(WSPermissionMode.named(plugin.permissionMode).label)",
                        on: plugin.isEnabled,
                        toggleLabel: "\(plugin.name) enabled") { on in
                    Task { await act { try await ws.setPluginEnabled(id: plugin.id, on: on) } }
                }
                .listRowBackground(Color.white.opacity(0.06))
                .contentShape(Rectangle())
                .onTapGesture { editingPlugin = plugin }
                .contextMenu { pluginMenu(plugin) }
                .swipeActions(edge: .trailing, allowsFullSwipe: false) {
                    if !plugin.isBundled {
                        Button("Delete", systemImage: "trash") {
                            deleting = Deleting(id: plugin.id, kind: .plugin, name: plugin.name,
                                                consequence: "The plugin is uninstalled from JoeBro. This can't be undone.")
                        }.tint(.red)
                    }
                    Button("Edit", systemImage: "pencil") { editingPlugin = plugin }.tint(.gray)
                }
            }
        }
    }

    @ViewBuilder
    private func pluginMenu(_ plugin: WSPlugin) -> some View {
        Button("Edit plugin", systemImage: "pencil") { editingPlugin = plugin }
        Button(plugin.isEnabled ? "Disable" : "Enable",
               systemImage: plugin.isEnabled ? "pause.circle" : "play.circle") {
            Task { await act { try await ws.setPluginEnabled(id: plugin.id, on: !plugin.isEnabled) } }
        }
        Menu("Agent access", systemImage: "lock.shield") {
            ForEach(WSPermissionMode.allCases) { mode in
                Button {
                    Task { await act { try await ws.setPluginPermission(id: plugin.id, mode: mode.rawValue) } }
                } label: {
                    Label(mode.label, systemImage: plugin.permissionMode == mode.rawValue ? "checkmark" : mode.symbol)
                }
            }
        }
        if !plugin.isBundled {
            Divider()
            Button("Delete plugin", systemImage: "trash", role: .destructive) {
                deleting = Deleting(id: plugin.id, kind: .plugin, name: plugin.name,
                                    consequence: "The plugin is uninstalled from JoeBro. This can't be undone.")
            }
        }
    }

    // MARK: Work

    private func remove(_ target: Deleting) async {
        await act {
            switch target.kind {
            case .tool: try await ws.deleteTool(id: target.id)
            case .server: try await ws.deleteMCPServer(id: target.id)
            case .plugin: try await ws.deletePlugin(id: target.id)
            }
        }
    }

    private func act(_ work: () async throws -> Void) async {
        do { try await work(); await load() } catch { self.error = error.localizedDescription }
    }

    private func load() async {
        guard !loading else { return }
        loading = true
        defer { loading = false }
        // Each list is configured independently, so one failing must not blank the others.
        var failures: [String] = []
        do { tools = try await ws.tools() } catch { failures.append("API tools (\(error.localizedDescription))") }
        do { servers = try await ws.mcpServers() } catch { failures.append("MCP servers (\(error.localizedDescription))") }
        do { plugins = try await ws.plugins() } catch { failures.append("plugins (\(error.localizedDescription))") }
        error = failures.isEmpty ? nil : "Couldn't load " + failures.joined(separator: "; ")
    }
}

// MARK: - Rows

private struct ToolRow: View {
    let title: String
    let subtitle: String
    let detail: String?
    let on: Bool
    let toggleLabel: String
    let setOn: (Bool) -> Void

    var body: some View {
        HStack(spacing: 11) {
            WSStatusDot(on: on)
            VStack(alignment: .leading, spacing: 3) {
                Text(title).foregroundStyle(.white).lineLimit(1)
                if !subtitle.isEmpty {
                    Text(subtitle).font(.caption).foregroundStyle(.secondary).lineLimit(2)
                }
                if let detail, !detail.isEmpty {
                    Text(detail).font(.caption2).foregroundStyle(.secondary.opacity(0.8)).lineLimit(1)
                }
            }
            Spacer(minLength: 8)
            WSToggle(label: toggleLabel, isOn: on, set: setOn)
        }
        .frame(minHeight: 48)
    }
}

private struct MCPRow: View {
    let server: WSMCPServer
    let setOn: (Bool) -> Void

    var body: some View {
        VStack(alignment: .leading, spacing: 7) {
            HStack(spacing: 11) {
                WSStatusDot(on: server.enabled)
                VStack(alignment: .leading, spacing: 3) {
                    Text(server.name).foregroundStyle(.white).lineLimit(1)
                    Text(server.command.isEmpty ? "No command set" : server.command)
                        .font(.caption).foregroundStyle(.secondary).lineLimit(1)
                }
                Spacer(minLength: 8)
                WSToggle(label: "\(server.name) enabled", isOn: server.enabled, set: setOn)
            }
            if !server.error.isEmpty {
                Label(server.error, systemImage: "exclamationmark.triangle")
                    .font(.caption2).foregroundStyle(.orange).lineLimit(3)
            } else if server.tools.isEmpty {
                Text(server.enabled ? "No tools discovered yet." : "Disabled.")
                    .font(.caption2).foregroundStyle(.secondary)
            } else {
                Text("\(server.tools.count) tools · " + server.tools.prefix(4).joined(separator: ", ")
                     + (server.tools.count > 4 ? "…" : ""))
                    .font(.caption2).foregroundStyle(.secondary).lineLimit(2)
            }
        }
        .frame(minHeight: 48)
    }
}

// MARK: - Editors

private struct APIToolEditor: View {
    let ws: WorkspaceAPI
    let tool: WSTool?
    let onSave: () -> Void

    @Environment(\.dismiss) private var dismiss
    @State private var name: String
    @State private var baseURL: String
    @State private var method: String
    @State private var description: String
    @State private var apiKey = ""
    @State private var saving = false
    @State private var error: String?

    init(ws: WorkspaceAPI, tool: WSTool?, onSave: @escaping () -> Void) {
        self.ws = ws; self.tool = tool; self.onSave = onSave
        _name = State(initialValue: tool?.name ?? "")
        _baseURL = State(initialValue: tool?.baseURL ?? "")
        _method = State(initialValue: tool?.method ?? "GET")
        _description = State(initialValue: tool?.description ?? "")
    }

    var body: some View {
        EditorShell(title: tool == nil ? "New API tool" : "Edit API tool",
                    saving: saving, canSave: canSave, error: $error,
                    save: { await save() }) {
            Section("Tool") {
                TextField("Name", text: $name)
                TextField("Base URL", text: $baseURL)
                    .keyboardType(.URL).textInputAutocapitalization(.never).autocorrectionDisabled()
                Picker("Method", selection: $method) {
                    Text("GET").tag("GET")
                    Text("POST").tag("POST")
                }
                .tint(Color.accentTint)
            }
            .listRowBackground(Color.white.opacity(0.06))
            Section("Description") {
                TextField("What this tool does", text: $description, axis: .vertical).lineLimit(2...5)
            }
            .listRowBackground(Color.white.opacity(0.06))
            Section {
                SecureField(tool?.hasKey == true ? "Replace saved API key" : "API key (optional)", text: $apiKey)
            } header: {
                Text("Authentication")
            } footer: {
                Text(tool?.hasKey == true
                     ? "A key is already saved. Leave this blank to keep it."
                     : "Sent by the backend; never stored on this phone.")
            }
            .listRowBackground(Color.white.opacity(0.06))
        }
    }

    private var canSave: Bool { !name.trimmingCharacters(in: .whitespaces).isEmpty && !baseURL.trimmingCharacters(in: .whitespaces).isEmpty }

    private func save() async {
        saving = true
        defer { saving = false }
        do {
            try await ws.saveTool(id: tool?.id, name: name, baseURL: baseURL, method: method,
                                  description: description, apiKey: apiKey.isEmpty ? nil : apiKey)
            onSave(); dismiss()
        } catch { self.error = error.localizedDescription }
    }
}

private struct MCPServerEditor: View {
    let ws: WorkspaceAPI
    let server: WSMCPServer?
    let onSave: () -> Void

    @Environment(\.dismiss) private var dismiss
    @State private var name: String
    @State private var command: String
    @State private var args: String
    @State private var permissionMode: String
    @State private var saving = false
    @State private var error: String?

    init(ws: WorkspaceAPI, server: WSMCPServer?, onSave: @escaping () -> Void) {
        self.ws = ws; self.server = server; self.onSave = onSave
        _name = State(initialValue: server?.name ?? "")
        _command = State(initialValue: server?.command ?? "")
        _args = State(initialValue: server?.args ?? "")
        _permissionMode = State(initialValue: server?.permissionMode ?? "sandbox")
    }

    var body: some View {
        EditorShell(title: server == nil ? "New MCP server" : "Edit MCP server",
                    saving: saving, canSave: canSave, error: $error,
                    save: { await save() }) {
            Section("Server") {
                TextField("Name", text: $name)
                TextField("Command", text: $command)
                    .textInputAutocapitalization(.never).autocorrectionDisabled()
                TextField("Arguments", text: $args)
                    .textInputAutocapitalization(.never).autocorrectionDisabled()
                WSPermissionPicker(title: "Agent access", mode: $permissionMode)
            }
            .listRowBackground(Color.white.opacity(0.06))
            if let server, !server.tools.isEmpty {
                Section("Discovered tools") {
                    ForEach(server.tools, id: \.self) { tool in
                        Text(tool).font(.subheadline).foregroundStyle(.white)
                    }
                }
                .listRowBackground(Color.white.opacity(0.06))
            }
            if let message = server?.error, !message.isEmpty {
                Section("Last discovery error") {
                    Text(message).font(.footnote).foregroundStyle(.orange)
                }
                .listRowBackground(Color.white.opacity(0.06))
            }
        }
    }

    private var canSave: Bool { !name.trimmingCharacters(in: .whitespaces).isEmpty && !command.trimmingCharacters(in: .whitespaces).isEmpty }

    private func save() async {
        saving = true
        defer { saving = false }
        do {
            try await ws.saveMCPServer(id: server?.id, name: name, command: command,
                                       args: args, permissionMode: permissionMode)
            onSave(); dismiss()
        } catch { self.error = error.localizedDescription }
    }
}

private struct PluginEditor: View {
    let ws: WorkspaceAPI
    let plugin: WSPlugin?
    let onSave: () -> Void

    @Environment(\.dismiss) private var dismiss
    @State private var name: String
    @State private var kind: String
    @State private var repoPath: String
    @State private var description: String
    @State private var permissionMode: String
    @State private var saving = false
    @State private var error: String?

    init(ws: WorkspaceAPI, plugin: WSPlugin?, onSave: @escaping () -> Void) {
        self.ws = ws; self.plugin = plugin; self.onSave = onSave
        _name = State(initialValue: plugin?.name ?? "")
        _kind = State(initialValue: plugin?.kind ?? "foreground")
        _repoPath = State(initialValue: plugin?.repoPath ?? "")
        _description = State(initialValue: plugin?.description ?? "")
        _permissionMode = State(initialValue: plugin?.permissionMode ?? "sandbox")
    }

    var body: some View {
        EditorShell(title: plugin == nil ? "New plugin" : "Edit plugin",
                    saving: saving, canSave: canSave, error: $error,
                    save: { await save() }) {
            Section("Plugin") {
                TextField("Name", text: $name)
                Picker("Kind", selection: $kind) {
                    Text("Foreground tool").tag("foreground")
                    Text("Background guardrail").tag("background")
                }
                .tint(Color.accentTint)
                TextField("Repository path", text: $repoPath)
                    .textInputAutocapitalization(.never).autocorrectionDisabled()
                WSPermissionPicker(title: "Agent access", mode: $permissionMode)
            }
            .listRowBackground(Color.white.opacity(0.06))
            Section("Description") {
                TextField("What this plugin does", text: $description, axis: .vertical).lineLimit(2...5)
            }
            .listRowBackground(Color.white.opacity(0.06))
        }
    }

    private var canSave: Bool { !name.trimmingCharacters(in: .whitespaces).isEmpty }

    private func save() async {
        saving = true
        defer { saving = false }
        do {
            try await ws.savePlugin(id: plugin?.id, name: name, kind: kind, repoPath: repoPath,
                                    description: description, permissionMode: permissionMode)
            onSave(); dismiss()
        } catch { self.error = error.localizedDescription }
    }
}

/// Shared chrome for the three editors above: glass form, cancel/save bar,
/// busy overlay and an error alert carrying the backend's own message.
private struct EditorShell<Content: View>: View {
    let title: String
    let saving: Bool
    let canSave: Bool
    @Binding var error: String?
    let save: () async -> Void
    @ViewBuilder let content: Content

    @Environment(\.dismiss) private var dismiss

    var body: some View {
        NavigationStack {
            Form { content }
                .scrollContentBackground(.hidden)
                .jbWallpaper()
                .navigationTitle(title)
                .navigationBarTitleDisplayMode(.inline)
                .toolbar {
                    ToolbarItem(placement: .topBarLeading) { Button("Cancel") { dismiss() }.disabled(saving) }
                    ToolbarItem(placement: .topBarTrailing) {
                        Button("Save") { Task { await save() } }.disabled(saving || !canSave)
                    }
                }
                .overlay { if saving { ProgressView().controlSize(.large) } }
                .alert("Couldn't save", isPresented: alertBinding($error)) {
                    Button("OK") { error = nil }
                } message: { Text(error ?? "") }
        }
    }
}
