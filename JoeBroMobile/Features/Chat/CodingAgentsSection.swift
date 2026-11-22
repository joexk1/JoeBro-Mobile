import SwiftUI

/// Coding agents shown above the chats, as on the Mac: live, waiting, or idle in the last 24h.
@MainActor
@Observable final class CodingAgentsStore {
    let api: JoeBroAPI
    var agents: [JBAgentRecord] = []

    init(api: JoeBroAPI) { self.api = api }

    var hasLive: Bool { agents.contains(where: \.isLive) }

    func load() async {
        guard let all = try? await api.agentRegistry() else { return }
        let cutoff = Date().addingTimeInterval(-24 * 3600)
        let kept = all.filter { $0.kind == .coding && ($0.isLive || Self.recent($0, after: cutoff)) }
        agents = kept.sorted { rank($0) != rank($1) ? rank($0) < rank($1) : ($0.createdAt ?? "") > ($1.createdAt ?? "") }
    }

    private func rank(_ a: JBAgentRecord) -> Int { a.status == "waiting" ? 0 : a.isLive ? 1 : 2 }

    /// Only idle rows (not failed/stopped) count, by their latest timestamp.
    private static func recent(_ a: JBAgentRecord, after cutoff: Date) -> Bool {
        guard ["idle", "done", "completed"].contains(a.status ?? "") else { return false }
        guard let stamp = a.finishedAt ?? a.startedAt ?? a.createdAt, let date = parse(stamp) else { return false }
        return date >= cutoff
    }

    private static func parse(_ s: String) -> Date? {
        let f = ISO8601DateFormatter()
        f.formatOptions = [.withInternetDateTime, .withFractionalSeconds]
        if let d = f.date(from: s) { return d }
        f.formatOptions = [.withInternetDateTime]
        return f.date(from: s)
    }

    /// Poll ~6s while any agent is live, ~20s otherwise. Cancelled with the calling task.
    func poll() async {
        while !Task.isCancelled {
            await load()
            try? await Task.sleep(for: .seconds(hasLive ? 6 : 20))
        }
    }
}

struct CodingAgentRow: View {
    let agent: JBAgentRecord
    var onOpen: () -> Void

    private var waiting: Bool { agent.status == "waiting" }
    private var tint: Color { waiting ? JB.warn : agent.isLive && agent.status != "queued" ? JB.live : JB.ink3 }

    var body: some View {
        Button(action: onOpen) {
            HStack(spacing: 10) {
                JBStatusDot(color: tint, live: agent.isLive && !waiting && agent.status != "queued", size: 7)
                Text(agent.displayTitle).font(.jb(15, .medium)).foregroundStyle(JB.ink).lineLimit(1)
                Spacer(minLength: 6)
                if waiting { Text("Needs you").font(.jbMono(11, .medium)).foregroundStyle(JB.warn) }
                Image(systemName: "chevron.right").font(.jb(11)).foregroundStyle(JB.ink3)
            }
            .padding(.horizontal, 14)
            .frame(minHeight: 50)
            .contentShape(Rectangle())
        }
        .buttonStyle(JBPressStyle())
        .listRowInsets(EdgeInsets(top: 3, leading: 16, bottom: 3, trailing: 16))
        .listRowBackground(
            RoundedRectangle(cornerRadius: 12, style: .continuous)
                .fill(JB.raised.opacity(0.92))
                .overlay(RoundedRectangle(cornerRadius: 12, style: .continuous)
                    .strokeBorder(waiting ? JB.warn.opacity(0.5) : JB.line, lineWidth: 1))
                .padding(.vertical, 3).padding(.horizontal, 16))
        .listRowSeparator(.hidden)
        .accessibilityLabel("\(agent.displayTitle), \(waiting ? "needs you" : agent.isLive ? "working" : "idle")")
    }
}
