import SwiftUI

/// Start a coding agent on any linked computer from the phone:
/// device → folder → new session or resume one of its recent sessions.
struct NewCodingAgentSheet: View {
    let api: JoeBroAPI
    var onStarted: () -> Void
    @Environment(\.dismiss) private var dismiss

    private struct SessionsEnv: Decodable { let sessions: [Session] }
    private struct Session: Decodable, Identifiable, Hashable {
        let id: String
        let repo: String?, host: String?, agent: String?, summary: String?, branch: String?, at: String?, resume_id: String?
    }
    private struct StartReply: Decodable { let ok: Bool?; let detail: String? }

    @State private var ws: WorkspaceAPI
    @State private var hosts: [NSHost] = []
    @State private var sessions: [Session] = []
    @State private var host = ""
    @State private var repo = ""
    @State private var customRepo = ""
    @State private var agent = "claude"
    @State private var permission = "edits"
    @State private var prompt = ""
    @State private var busy = false
    @State private var error: String?

    init(api: JoeBroAPI, onStarted: @escaping () -> Void) {
        self.api = api
        self.onStarted = onStarted
        _ws = State(initialValue: WorkspaceAPI(baseURL: api.baseURL, token: ServerConfig.token))
    }

    private var folders: [String] {
        var seen = Set<String>()
        return sessions.compactMap { s -> String? in
            guard s.host == host, let r = s.repo, !r.isEmpty, !r.hasPrefix("/tmp/"), !r.contains("/scratchpad") else { return nil }
            return r
        }.filter { seen.insert($0).inserted }
    }
    private var folder: String { repo == "__other" ? customRepo.trimmingCharacters(in: .whitespaces) : repo }
    private var resumable: [Session] { sessions.filter { $0.host == host && $0.repo == folder && !($0.resume_id ?? "").isEmpty } }

    var body: some View {
        NavigationStack {
            Form {
                Section {
                    if hosts.count > 1 {    // only with more than one linked computer
                        Picker("Device", selection: $host) {
                            ForEach(hosts) { h in Text(h.up == false ? h.label + " (offline)" : h.label).tag(h.id) }
                        }
                    }
                    Picker("Agent", selection: $agent) {
                        Text("Claude Code").tag("claude"); Text("Codex").tag("codex"); Text("OpenCode").tag("opencode")
                    }
                    Picker("Permissions", selection: $permission) {
                        Text("Ask first").tag("ask"); Text("Accept edits").tag("edits"); Text("Full access").tag("full")
                    }
                }
                .pickerStyle(.menu)
                Section("Folder") {
                    ForEach(folders, id: \.self) { f in folderRow(f) }
                    folderRow("__other")
                    if repo == "__other" {
                        TextField("/path/to/project", text: $customRepo)
                            .textInputAutocapitalization(.never).autocorrectionDisabled()
                    }
                }
                if !folder.isEmpty {
                    Section {
                        TextField("First message (optional)", text: $prompt, axis: .vertical).lineLimit(1...4)
                        Button { Task { await start(resume: nil) } } label: {
                            Text("Start new session").font(.jb(16, .semibold)).frame(maxWidth: .infinity)
                        }
                        .disabled(busy || host.isEmpty)
                    }
                    if !resumable.isEmpty {
                        Section("Or resume") {
                            ForEach(resumable) { s in
                                Button { Task { await start(resume: s.resume_id) } } label: {
                                    VStack(alignment: .leading, spacing: 3) {
                                        Text((s.summary ?? "").isEmpty ? "Session" : s.summary!).font(.jb(15, .medium)).foregroundStyle(JB.ink).lineLimit(2)
                                        Text([s.agent ?? "", s.branch ?? "", rel(s.at)].filter { !$0.isEmpty }.joined(separator: " · "))
                                            .font(.jb(13)).foregroundStyle(JB.ink3)
                                    }
                                }
                                .disabled(busy)
                            }
                        }
                    }
                }
                if let error { Section { Text(error).foregroundStyle(JB.danger) } }
            }
            .navigationTitle("New coding agent")
            .navigationBarTitleDisplayMode(.inline)
            .toolbar {
                ToolbarItem(placement: .cancellationAction) { Button("Cancel") { dismiss() } }
                if busy { ToolbarItem(placement: .confirmationAction) { JBSpinner() } }
            }
            .task { await load() }
            .onChange(of: host) { repo = folders.first ?? "__other" }
        }
    }

    private func folderRow(_ f: String) -> some View {
        Button { repo = f } label: {
            HStack(spacing: 12) {
                Image(systemName: f == "__other" ? "plus" : "folder").foregroundStyle(repo == f ? JB.accent : JB.ink3).frame(width: 22)
                VStack(alignment: .leading, spacing: 2) {
                    Text(f == "__other" ? "Other folder…" : (f as NSString).lastPathComponent).font(.jb(15, .medium)).foregroundStyle(JB.ink)
                    if f != "__other" { Text(f).font(.jb(12)).foregroundStyle(JB.ink3).lineLimit(1).truncationMode(.middle) }
                }
                Spacer()
                if repo == f { Image(systemName: "checkmark").foregroundStyle(JB.accent) }
            }
        }
    }

    private func short(_ p: String) -> String {
        let parts = p.split(separator: "/")
        return parts.count > 2 ? "…/" + parts.suffix(2).joined(separator: "/") : p
    }

    private func rel(_ iso: String?) -> String {
        guard let iso, let d = jbParseISO(iso) else { return "" }
        return d.formatted(.relative(presentation: .named))
    }

    private func load() async {
        hosts = await ws.nightHosts()
        if let env = try? await api.fetch(SessionsEnv.self, "/api/shared-memory/sessions", query: [URLQueryItem(name: "limit", value: "50")]) {
            sessions = env.sessions
        }
        host = sessions.first(where: { s in hosts.contains { $0.id == s.host } })?.host ?? hosts.first { $0.label == "Mac" }?.id ?? hosts.first?.id ?? ""
        repo = folders.first ?? "__other"
    }

    private func start(resume: String?) async {
        busy = true; error = nil
        defer { busy = false }
        var body: [String: Any] = ["repo": folder, "host": host, "agent": agent, "permission": permission]
        if resume == nil, !prompt.trimmingCharacters(in: .whitespacesAndNewlines).isEmpty { body["prompt"] = prompt }
        body["resume"] = resume ?? false
        do {
            let r = try await api.send(StartReply.self, "/api/coding-agents/start", json: body)
            if r.ok == false { error = r.detail ?? "Couldn't start"; return }
            onStarted(); dismiss()
        } catch {
            self.error = error.localizedDescription
        }
    }
}
