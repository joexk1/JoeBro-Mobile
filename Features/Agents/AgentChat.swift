import SwiftUI

// Coding agents as chats on the phone: transcript, approvals, composer.

extension JoeBroAPI {
    private struct SendResult: Decodable { let delivered: String? }
    private struct DecideResult: Decodable { let applied: Bool?; let detail: String? }
    private struct ScreenResult: Decodable { let screen: String?; let lines: [String]? }

    /// Type an instruction into a coding agent. Returns "terminal" (typed now) or "queued".
    func codingSend(id: String, text: String, mode: String = "auto") async throws -> String {
        let r = try await send(SendResult.self, "api/coding-agents/\(segment(id))/send", json: ["text": text, "sender": "phone", "mode": mode])
        return r.delivered ?? "queued"
    }

    /// Switch the active model on any coding agent. Uses the dedicated backend route when available,
    /// falling back to `/model <model>` in the agent's terminal on older backends.
    func codingSetModel(id: String, model: String, harness: String = "") async throws -> String {
        do {
            let r = try await send(SendResult.self, "api/coding-agents/\(segment(id))/model", json: ["model": model])
            return r.delivered ?? "terminal"
        } catch where error.isNotFound {
            let mode = harness == "opencode" ? "queue" : "terminal"
            return try await codingSend(id: id, text: "/model " + model, mode: mode)
        }
    }

    /// Approve or deny the agent's pending permission prompt. Returns a short outcome.
    func codingDecide(id: String, approve: Bool) async throws -> String {
        let r = try await send(DecideResult.self, "api/coding-agents/\(segment(id))/decide",
                               json: ["decision": approve ? "approve" : "deny"])
        return r.applied == true ? (approve ? "approved" : "denied") : (r.detail ?? "pending")
    }

    private struct AnswerResult: Decodable { let prompt: JBAgentPrompt? }

    /// Pick an option of the agent's on-screen question/menu (or type free text). Returns the next one, if any.
    func codingAnswer(id: String, key: String?, text: String?) async throws -> JBAgentPrompt? {
        var body: [String: String] = [:]
        if let key { body["key"] = key }
        if let text { body["text"] = text }
        return try await send(AnswerResult.self, "api/coding-agents/\(segment(id))/answer", json: body).prompt
    }

    func codingScreen(id: String, lines: Int = 40) async throws -> String {
        let r = try await fetch(ScreenResult.self, "api/coding-agents/\(segment(id))/screen",
                                query: [URLQueryItem(name: "lines", value: "\(lines)")])
        return r.screen ?? r.lines?.joined(separator: "\n") ?? ""
    }
}

/// The question a coding agent is asking, as tappable options, plus a text field when it
/// takes a typed answer. Multi-question forms step through in place.
struct AgentPromptCard: View {
    let api: JoeBroAPI
    let agentID: String
    let prompt: JBAgentPrompt
    var onDone: () async -> Void = {}
    @State private var shown: JBAgentPrompt?
    @State private var typed = ""
    @State private var busy = false
    @State private var note: String?
    @State private var tick = 0
    @FocusState private var typing: Bool

    private var p: JBAgentPrompt { shown ?? prompt }

    var body: some View {
        VStack(alignment: .leading, spacing: 8) {
            if !p.header.isEmpty { Text(p.header).jbEyebrow() }
            if !p.question.isEmpty { Text(p.question).font(.jb(14, .medium)).foregroundStyle(JB.ink) }
            ForEach(p.options.filter { !$0.freeform }, id: \.self) { o in
                Button { Task { await answer(key: o.key.isEmpty ? o.label : o.key, text: nil) } } label: {
                    VStack(alignment: .leading, spacing: 2) {
                        Text(o.label).font(.jb(14)).foregroundStyle(JB.ink)
                        if !o.description.isEmpty && o.description != o.label {
                            Text(o.description).font(.jb(12)).foregroundStyle(JB.ink3)
                        }
                    }
                    .frame(maxWidth: .infinity, alignment: .leading)
                    .padding(.horizontal, 12).padding(.vertical, 10)
                    .background(JB.hover, in: RoundedRectangle(cornerRadius: JB.rControl, style: .continuous))
                    .contentShape(Rectangle())
                }
                .buttonStyle(.plain)
            }
            if p.options.contains(where: \.freeform) {
                HStack(spacing: 8) {
                    TextField("Type your own answer", text: $typed)
                        .font(.jb(14)).focused($typing).submitLabel(.send)
                        .onSubmit { send() }
                        .padding(.horizontal, 12).padding(.vertical, 9)
                        .jbField(focused: typing)
                    Button { send() } label: { Image(systemName: "arrow.up") }
                        .buttonStyle(JBIconButtonStyle(size: 36, active: !typed.isEmpty))
                        .disabled(typed.trimmingCharacters(in: .whitespaces).isEmpty)
                }
            }
            if busy || note != nil {
                HStack(spacing: 6) {
                    if busy { JBSpinner() }
                    if let note { Text(note).font(.jb(11)).foregroundStyle(JB.ink3) }
                }
            }
        }
        .disabled(busy)
        .sensoryFeedback(.selection, trigger: tick)
        .onChange(of: prompt) { _, _ in shown = nil }
    }

    private func send() {
        let t = typed.trimmingCharacters(in: .whitespacesAndNewlines)
        guard !t.isEmpty else { return }
        Task { await answer(key: nil, text: t) }
    }

    private func answer(key: String?, text: String?) async {
        busy = true; note = nil
        defer { busy = false }
        do {
            let next = try await api.codingAnswer(id: agentID, key: key, text: text)
            typed = ""; tick += 1
            if let next { shown = next } else { note = "Answered"; await onDone() }
        } catch { note = error.localizedDescription }
    }
}

/// Approve / deny buttons for a waiting coding agent. Used in the Agents list, the thread and the notifications list.
struct AgentApprovalButtons: View {
    let api: JoeBroAPI
    let agentID: String
    var onDone: () async -> Void = {}
    @State private var busy = false
    @State private var note: String?
    @State private var tick = 0

    var body: some View {
        HStack(spacing: 8) {
            Button("Approve") { Task { await decide(true) } }.buttonStyle(.jbPrimary)
            Button("Deny") { Task { await decide(false) } }.buttonStyle(.jbDanger)
            if busy { JBSpinner() }
            if let note { Text(note).font(.jb(11)).foregroundStyle(JB.ink3).lineLimit(1) }
            Spacer(minLength: 0)
        }
        .disabled(busy)
        .sensoryFeedback(.success, trigger: tick)
    }

    private func decide(_ approve: Bool) async {
        busy = true
        defer { busy = false }
        do {
            note = try await api.codingDecide(id: agentID, approve: approve)
            tick += 1
            await onDone()
        } catch { note = error.localizedDescription }
    }
}

/// The chat view of one coding agent: your prompts as raised cards, replies as plain text,
/// tool calls as one mono line, then a composer that talks to the agent.
struct AgentChatThread: View {
    let api: JoeBroAPI
    let agent: JBAgentRecord
    var header: AnyView = AnyView(EmptyView())
    var onChanged: () async -> Void = {}
    @State private var draft = ""
    @State private var sending = false
    @State private var echoes: [(text: String, via: String)] = []
    @State private var error: String?
    @State private var showScreen = false
    @State private var screen = ""
    @State private var sentTick = 0
    @State private var voice = VoiceCapture()
    @State private var draftBeforeVoice = ""
    @State private var switchingModel = false
    @State private var pickedModel: String?
    @State private var customModelOpen = false
    @State private var customModelText = ""
    @FocusState private var focused: Bool

    private var messages: [JBAgentMessage] { agent.messages ?? [] }
    private var waiting: Bool { agent.status == "waiting" }

    private enum Item { case message(JBAgentMessage), tools([String]) }
    /// Consecutive tool lines fold into one row (same as the Mac).
    private var items: [Item] {
        var out: [Item] = []
        for m in messages {
            if !["user", "assistant", "approval", "notice", "event"].contains(m.role) {
                if case .tools(let l) = out.last { out[out.count - 1] = .tools(l + [m.content]) } else { out.append(.tools([m.content])) }
            } else { out.append(.message(m)) }
        }
        return out
    }
    private var working: Bool { agent.isLive && !waiting }
    private var canSend: Bool { agent.status != "ended" }

    var body: some View {
        ScrollViewReader { proxy in
            ScrollView {
                VStack(alignment: .leading, spacing: 14) {
                    header
                    ForEach(Array(items.enumerated()), id: \.offset) { i, item in
                        switch item {
                        case .message(let m): bubble(m, last: i == items.count - 1)
                        case .tools(let lines): AgentToolGroup(lines: lines, running: working && i == items.count - 1)
                        }
                    }
                    ForEach(Array(echoes.enumerated()).filter { e in !messages.contains { $0.role == "user" && sameMessage($0.content, e.element.text) } },
                            id: \.offset) { _, e in userCard(e.text, tag: e.via) }
                    if working { HStack(spacing: 6) { JBSpinner(); JBStreamCursor() } }
                    if waiting && !messages.contains(where: { $0.role == "approval" }) { approvalCard("needs your approval") }
                    if showScreen {
                        Text(screen.isEmpty ? " " : screen)
                            .font(.jbMono(10.5)).foregroundStyle(JB.ink2).textSelection(.enabled)
                            .frame(maxWidth: .infinity, alignment: .leading).jbCard(padding: 12)
                    }
                    Color.clear.frame(height: 1).id("end")
                }
                .padding(16)
            }
            .scrollIndicators(.hidden)
            .scrollDismissesKeyboard(.interactively)
            .onChange(of: messages.count + echoes.count) { _, _ in
                withAnimation(JB.smooth) { proxy.scrollTo("end", anchor: .bottom) }
            }
        }
        .safeAreaInset(edge: .bottom, spacing: 0) { if canSend { composer } }
        .task(id: showScreen) {
            guard showScreen else { return }
            while !Task.isCancelled {
                screen = (try? await api.codingScreen(id: agent.id)) ?? screen
                try? await Task.sleep(for: .seconds(2))
            }
        }
        .sensoryFeedback(.impact(weight: .light), trigger: sentTick)
    }

    @ViewBuilder private func bubble(_ m: JBAgentMessage, last: Bool) -> some View {
        switch m.role {
        case "user": userCard(handoverStripped(m.content), tag: nil)
        case "assistant":
            MarkdownText(text: m.content).textSelection(.enabled)
                .frame(maxWidth: .infinity, alignment: .leading)
        case "approval": approvalCard(m.content, active: last && waiting)
        case "notice":   // usage limit / API error: the agent stopped and why
            HStack(spacing: 8) {
                Image(systemName: "exclamationmark.triangle.fill").font(.jb(11)).foregroundStyle(JB.warn)
                Text(m.content).font(.jb(12.5, .medium)).foregroundStyle(JB.ink)
            }
            .padding(.horizontal, 12).padding(.vertical, 8)
            .background(RoundedRectangle(cornerRadius: JB.rControl, style: .continuous).fill(JB.warn.opacity(0.12)))
            .overlay(RoundedRectangle(cornerRadius: JB.rControl, style: .continuous).strokeBorder(JB.warn.opacity(0.35), lineWidth: 1))
            .frame(maxWidth: .infinity, alignment: .leading)
        case "event":    // harness happenings (background task done, /command, compacted): a quiet centred line
            HStack(spacing: 8) {
                Rectangle().fill(JB.line).frame(height: 1)
                Text(m.content).font(.jb(11.5)).foregroundStyle(JB.ink3).lineLimit(2).multilineTextAlignment(.center)
                Rectangle().fill(JB.line).frame(height: 1)
            }
            .frame(maxWidth: .infinity)
        default:
            HStack(spacing: 6) {
                JBStatusDot(color: JB.ink3, size: 5)
                Text(m.content).font(.jb(11)).foregroundStyle(JB.ink2).lineLimit(2)
            }
        }
    }

    private func userCard(_ text: String, tag: String?) -> some View {
        VStack(alignment: .leading, spacing: 4) {
            Text(text).font(.jbBody).foregroundStyle(JB.ink).textSelection(.enabled)
            if let tag { Text(tag).jbEyebrow() }
        }
        .jbCard(padding: 12)
    }

    private func approvalCard(_ text: String, active: Bool = true) -> some View {
        VStack(alignment: .leading, spacing: 10) {
            HStack(spacing: 6) { JBStatusDot(color: JB.warn, live: active, size: 6); Text("Needs you").jbEyebrow() }
            if active, let prompt = agent.prompt, !prompt.options.isEmpty {
                AgentPromptCard(api: api, agentID: agent.id, prompt: prompt, onDone: onChanged)
            } else {
                Text(text.replacingOccurrences(of: "Question: ", with: "")).font(.jb(12)).foregroundStyle(JB.ink)
                if active { AgentApprovalButtons(api: api, agentID: agent.id, onDone: onChanged) }
            }
        }
        .jbCard(padding: 12)
        .background(RoundedRectangle(cornerRadius: JB.rCard, style: .continuous).fill(JB.surface.opacity(active ? 0.96 : 0)))   // solid while it waits on you
        .overlay(RoundedRectangle(cornerRadius: JB.rCard, style: .continuous).strokeBorder(JB.warn.opacity(active ? 0.5 : 0), lineWidth: 1))
    }

    private var composer: some View {
        VStack(alignment: .leading, spacing: 4) {
            HStack(alignment: .bottom, spacing: 8) {
                TextField("Message agent", text: $draft, axis: .vertical)
                    .font(.jbBody).lineLimit(1...5)
                    .focused($focused)
                    .padding(.horizontal, 12).padding(.vertical, 10)
                    .jbField(focused: focused)
                Button {
                    if voice.isRecording { voice.stop() }
                    else { draftBeforeVoice = draft; Task { await voice.start() } }
                } label: {
                    Image(systemName: voice.isRecording ? "mic.fill" : "mic")
                        .foregroundStyle(voice.isRecording ? JB.danger : JB.ink2)
                        .symbolEffect(.pulse, isActive: voice.isRecording)
                }
                .buttonStyle(JBIconButtonStyle(size: 40))
                .accessibilityLabel(voice.isRecording ? "Stop dictation" : "Dictate")
                Button { voice.stop(); submit() } label: { Image(systemName: "arrow.up") }
                    .buttonStyle(JBIconButtonStyle(size: 40, active: !draft.isEmpty))
                    .disabled(draft.trimmingCharacters(in: .whitespacesAndNewlines).isEmpty || sending)
                    .accessibilityLabel("Send")
            }
            if !agent.harness.isEmpty { modelMenu }
            if let error = error ?? voice.error { Text(error).font(.jb(11)).foregroundStyle(JB.danger) }
        }
        .alert("Switch model", isPresented: $customModelOpen) {
            TextField("Model id (e.g. provider/model)", text: $customModelText)
                .textInputAutocapitalization(.never).autocorrectionDisabled()
            Button("Switch") {
                let m = customModelText.trimmingCharacters(in: .whitespacesAndNewlines)
                if !m.isEmpty { Task { await switchModel(to: m) } }
            }
            Button("Cancel", role: .cancel) { }
        } message: {
            Text("Enter the model slug to pass to /model.")
        }
        .onChange(of: voice.transcript) { _, t in
            guard voice.isRecording, !t.isEmpty else { return }
            draft = draftBeforeVoice.isEmpty ? t : draftBeforeVoice + " " + t
        }
        .onDisappear { voice.stop() }
        .padding(.horizontal, 12).padding(.vertical, 8)
        .background(JB.surface)
        .overlay(alignment: .top) { Rectangle().fill(JB.line).frame(height: 1) }
    }

    private var activeModel: String { pickedModel ?? agent.model ?? "" }

    private var modelOptions: [JBCodingModel] {
        CodingAgentModelPresets.options(for: agent.harness, current: activeModel, server: agent.availableModels)
    }

    private func isCurrentModel(_ id: String) -> Bool {
        let cur = activeModel.lowercased()
        guard !cur.isEmpty else { return false }
        return cur == id.lowercased() || cur.contains(id.lowercased())
    }

    private func switchModel(to model: String) async {
        switchingModel = true
        defer { switchingModel = false }
        do {
            _ = try await api.codingSetModel(id: agent.id, model: model, harness: agent.harness)
            pickedModel = model
            error = nil
            await onChanged()
        } catch {
            self.error = "Model change needs the agent idle in a Kitty/tmux terminal: " + error.localizedDescription
        }
    }

    /// Model picker for every linked coding agent (Claude Code, Antigravity, Codex, OpenCode).
    private var modelMenu: some View {
        Menu {
            ForEach(modelOptions) { m in
                Button { Task { await switchModel(to: m.id) } } label: {
                    if isCurrentModel(m.id) { Label(m.label, systemImage: "checkmark") } else { Text(m.label) }
                }
            }
            Divider()
            Button("Custom model…") {
                customModelText = activeModel
                customModelOpen = true
            }
        } label: {
            HStack(spacing: 5) {
                ProviderLogoView(model: activeModel.isEmpty ? agent.harness : activeModel, size: 11)
                if switchingModel { JBSpinner() }
                Text(CodingAgentModelPresets.displayLabel(activeModel, in: modelOptions))
                    .font(.jb(11.5)).foregroundStyle(JB.ink2).lineLimit(1)
                Image(systemName: "chevron.down").font(.jb(8, .semibold)).foregroundStyle(JB.ink3)
            }
            .padding(.horizontal, 6).padding(.vertical, 2)
        }
        .disabled(switchingModel)
    }

    private func submit() {
        let text = draft.trimmingCharacters(in: .whitespacesAndNewlines)
        guard !text.isEmpty, !sending else { return }
        draft = ""
        Task { await send(text) }
    }

    private func send(_ text: String) async {
        guard !sending else { return }
        sending = true
        // Shown immediately, labelled the same way the terminal shows it: queued while the agent works.
        echoes.append((text, working ? "queued" : "sending"))
        let idx = echoes.count - 1
        defer { sending = false }
        do {
            let how = try await api.codingSend(id: agent.id, text: text)
            if echoes.indices.contains(idx) { echoes[idx].via = how == "terminal" && !working ? "sent" : "queued" }
            error = nil; sentTick += 1
            await onChanged()
        } catch {
            if echoes.indices.contains(idx) { echoes.remove(at: idx) }
            draft = text; self.error = error.localizedDescription
        }
    }
}


/// Default model presets per coding-agent harness, merged with any server-reported options and the active model.
enum CodingAgentModelPresets {
    static let defaults: [String: [JBCodingModel]] = [
        "claude": [
            .init(id: "opus", label: "Opus"),
            .init(id: "sonnet", label: "Sonnet"),
            .init(id: "haiku", label: "Haiku"),
            .init(id: "default", label: "Default"),
        ],
        "agy": [
            .init(id: "gemini-4-neon-high", label: "Gemini 4 Neon (High)"),
            .init(id: "gemini-4-neon-medium", label: "Gemini 4 Neon (Medium)"),
            .init(id: "gemini-4-carbon-high", label: "Gemini 4 Carbon (High)"),
            .init(id: "gemini-4-hydrogen-high", label: "Gemini 4 Hydrogen (High)"),
            .init(id: "gemini-pro-orchestrator-neon", label: "Orchestrator (Neon)"),
            .init(id: "claude-opus-5-5-high", label: "Claude Opus 5.5 (High)"),
            .init(id: "claude-sonnet-5-5-high", label: "Claude Sonnet 5.5 (High)"),
        ],
        "codex": [
            .init(id: "gpt-6.2-sol", label: "GPT-6.2 Sol"),
            .init(id: "gpt-6.2-astra", label: "GPT-6.2 Astra"),
            .init(id: "gpt-6.1-terra", label: "GPT-6.1 Terra"),
            .init(id: "gpt-5-codex", label: "GPT-5 Codex"),
            .init(id: "gpt-5", label: "GPT-5"),
        ],
        "opencode": [
            .init(id: "qwen3-coder:30b", label: "Qwen3 Coder 30B"),
            .init(id: "llama3.3:70b", label: "Llama 3.3 70B"),
            .init(id: "deepseek-v3.2", label: "DeepSeek V3.2"),
        ],
    ]

    static func options(for harness: String, current: String?, server: [JBCodingModel]?) -> [JBCodingModel] {
        var seen = Set<String>()
        var out: [JBCodingModel] = []
        func add(_ m: JBCodingModel) {
            let k = m.id.trimmingCharacters(in: .whitespacesAndNewlines).lowercased()
            guard !k.isEmpty, seen.insert(k).inserted else { return }
            out.append(m)
        }
        if let cur = current?.trimmingCharacters(in: .whitespacesAndNewlines), !cur.isEmpty {
            let preset = (server ?? defaults[harness] ?? []).first { $0.id.lowercased() == cur.lowercased() }
            add(preset ?? JBCodingModel(id: cur))
        }
        for m in server ?? [] { add(m) }
        for m in defaults[harness] ?? [] { add(m) }
        return out
    }

    static func displayLabel(_ model: String, in options: [JBCodingModel]) -> String {
        guard !model.isEmpty else { return "Model" }
        if let hit = options.first(where: { $0.id.lowercased() == model.lowercased() }) { return hit.label }
        return model.components(separatedBy: "/").last ?? model
    }
}

/// "Message from app via JoeBro: hi" / "[from app] hi" -> "hi" (how a delivered message is logged).
func handoverStripped(_ s: String) -> String {
    var t = s.replacingOccurrences(of: "[from app] ", with: "")
    if let r = t.range(of: #"^Message from [^:\n]{1,40}: "#, options: .regularExpression) { t.removeSubrange(r) }
    return t
}


/// Delivered-yet check: the feed collapses whitespace and clips long text, so compare normalised prefixes.
func sameMessage(_ feed: String, _ sent: String) -> Bool {
    func norm(_ s: String) -> String { handoverStripped(s).split(whereSeparator: \.isWhitespace).joined(separator: " ").lowercased() }
    let a = norm(feed), b = norm(sent)
    guard !a.isEmpty, !b.isEmpty else { return false }
    let n = min(80, a.count, b.count)
    return a.contains(b.prefix(n)) || b.hasPrefix(a.prefix(n))
}

struct ToolCard: ViewModifier {
    func body(content: Content) -> some View {
        content
            .padding(.horizontal, 10).padding(.vertical, 5)
            .background(RoundedRectangle(cornerRadius: JB.rControl + 1, style: .continuous).fill(JB.readFill))
            .overlay(RoundedRectangle(cornerRadius: JB.rControl + 1, style: .continuous).strokeBorder(JB.line, lineWidth: 1))
    }
}

/// A run of a coding agent's tool calls, collapsed to one line (the latest), like JoeBro's tool rows.
struct AgentToolGroup: View {
    let lines: [String]
    var running = false
    @State private var expanded = false
    var body: some View {
        VStack(alignment: .leading, spacing: 4) {
            Button { withAnimation(JB.snap) { expanded.toggle() } } label: {
                HStack(spacing: 8) {
                    JBStatusDot(color: running ? JB.live : JB.ink3, live: running, size: 6)
                    Text(lines.last ?? "").font(.jb(12)).foregroundStyle(JB.ink2).lineLimit(1).truncationMode(.tail)
                    if lines.count > 1 { Text("\(lines.count)").font(.jb(11)).foregroundStyle(JB.ink3) }
                    Image(systemName: "chevron.right").font(.jb(7, .bold)).foregroundStyle(JB.ink3)
                        .rotationEffect(.degrees(expanded ? 90 : 0))
                }
                .frame(minHeight: 22)
                .contentShape(Rectangle())
            }
            .buttonStyle(.plain)
            if expanded {
                VStack(alignment: .leading, spacing: 3) {
                    ForEach(Array(lines.enumerated()), id: \.offset) { _, l in
                        Text(l).font(.jbMono(11)).foregroundStyle(JB.ink2).lineLimit(3).textSelection(.enabled)
                    }
                }
                .padding(.leading, 14)
                .transition(.opacity)
            }
        }
        .modifier(ToolCard())
        .frame(maxWidth: .infinity, alignment: .leading)
    }
}
