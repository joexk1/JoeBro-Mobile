import SwiftUI

// Coding agents as chats on the phone: transcript, approvals, composer.

extension JoeBroAPI {
    private struct SendResult: Decodable { let delivered: String? }
    private struct DecideResult: Decodable { let applied: Bool?; let detail: String? }
    private struct ScreenResult: Decodable { let screen: String?; let lines: [String]? }

    /// Type an instruction into a coding agent. Returns "terminal" (typed now) or "queued".
    func codingSend(id: String, text: String) async throws -> String {
        let r = try await send(SendResult.self, "api/coding-agents/\(segment(id))/send", json: ["text": text, "sender": "phone"])
        return r.delivered ?? "queued"
    }

    /// Approve or deny the agent's pending permission prompt. Returns a short outcome.
    func codingDecide(id: String, approve: Bool) async throws -> String {
        let r = try await send(DecideResult.self, "api/coding-agents/\(segment(id))/decide",
                               json: ["decision": approve ? "approve" : "deny"])
        return r.applied == true ? (approve ? "approved" : "denied") : (r.detail ?? "pending")
    }

    func codingScreen(id: String, lines: Int = 40) async throws -> String {
        let r = try await fetch(ScreenResult.self, "api/coding-agents/\(segment(id))/screen",
                                query: [URLQueryItem(name: "lines", value: "\(lines)")])
        return r.screen ?? r.lines?.joined(separator: "\n") ?? ""
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
    @FocusState private var focused: Bool

    private var messages: [JBAgentMessage] { agent.messages ?? [] }
    private var waiting: Bool { agent.status == "waiting" }
    private var working: Bool { agent.isLive && !waiting }
    private var canSend: Bool { agent.status != "ended" }

    var body: some View {
        ScrollViewReader { proxy in
            ScrollView {
                VStack(alignment: .leading, spacing: 14) {
                    header
                    ForEach(Array(messages.enumerated()), id: \.offset) { i, m in
                        bubble(m, last: i == messages.count - 1)
                    }
                    ForEach(Array(echoes.enumerated()), id: \.offset) { _, e in userCard(e.text, tag: e.via) }
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
        case "user": userCard(m.content, tag: nil)
        case "assistant":
            MarkdownText(text: m.content).textSelection(.enabled)
                .frame(maxWidth: .infinity, alignment: .leading)
        case "approval": approvalCard(m.content, active: last && waiting)
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
            Text(text).font(.jb(12)).foregroundStyle(JB.ink)
            if active { AgentApprovalButtons(api: api, agentID: agent.id, onDone: onChanged) }
        }
        .jbCard(padding: 12)
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
                Button { showScreen.toggle() } label: { JBIcon(.coding, size: 16) }
                    .buttonStyle(JBIconButtonStyle(size: 40, active: showScreen))
                    .accessibilityLabel("Terminal")
                Button { Task { await send() } } label: { Image(systemName: "arrow.up") }
                    .buttonStyle(JBIconButtonStyle(size: 40, active: !draft.isEmpty))
                    .disabled(draft.trimmingCharacters(in: .whitespacesAndNewlines).isEmpty || sending)
                    .accessibilityLabel("Send")
            }
            if let error { Text(error).font(.jb(11)).foregroundStyle(JB.danger) }
        }
        .padding(.horizontal, 12).padding(.vertical, 8)
        .background(JB.surface)
        .overlay(alignment: .top) { Rectangle().fill(JB.line).frame(height: 1) }
    }

    private func send() async {
        let text = draft.trimmingCharacters(in: .whitespacesAndNewlines)
        guard !text.isEmpty, !sending else { return }
        sending = true
        defer { sending = false }
        do {
            let how = try await api.codingSend(id: agent.id, text: text)
            echoes.append((text, how == "terminal" ? "sent" : "queued for its next turn"))
            draft = ""; error = nil; sentTick += 1
            await onChanged()
        } catch { self.error = error.localizedDescription }
    }
}
