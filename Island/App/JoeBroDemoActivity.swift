#if DEBUG
import ActivityKit
import SwiftUI

/// `-JoeBroDemoActivity` starts a local Live Activity (no push) from the demo
/// agents in demo.json. `-JoeBroDemoIslandPreview` overlays the lock-screen card
/// and the expanded-island layout in the app, for screenshots.
@MainActor enum JoeBroDemoActivity {
    static var requested: Bool { ProcessInfo.processInfo.arguments.contains("-JoeBroDemoActivity") }
    static var previewRequested: Bool { ProcessInfo.processInfo.arguments.contains("-JoeBroDemoIslandPreview") }

    /// Same source as DemoMode: the "GET /api/agents" entry of the bundled demo.json.
    static func demoState(longTitle: Bool = false, agentLimit: Int? = nil) -> JoeBroActivityAttributes.ContentState {
        var agents: [JBAgentRecord] = []
        if let url = Bundle.main.url(forResource: "demo", withExtension: "json"),
           let data = try? Data(contentsOf: url),
           let root = try? JSONSerialization.jsonObject(with: data) as? [String: Any],
           let entry = root["GET /api/agents"] as? [String: Any],
           let list = entry["agents"],
           let raw = try? JSONSerialization.data(withJSONObject: list) {
            agents = (try? JSONDecoder().decode([JBAgentRecord].self, from: raw)) ?? []
        }
        let live = agents.filter { $0.kind != .briefing && !$0.isSessionOnly && $0.isLive && $0.kind != .subagent }
        let ids = Set(live.map(\.id))
        let subs = agents.filter { $0.kind == .subagent && ($0.parentID.map(ids.contains) ?? false) }
        var runs = live.prefix(agentLimit ?? live.count).map { JoeBroActivityController.run($0, subagents: subs) }
        // One agent is waiting for an approval.
        if let i = runs.firstIndex(where: { $0.id == "o1" }) { runs[i].waiting = true; runs[i].detail = "Approve: run xcodebuild" }
        if longTitle, !runs.isEmpty { runs[0].title = "Claude Code: migrate the authentication middleware to the new session token format across every service" }
        return .init(count: runs.count, runs: runs, startedAt: .now.addingTimeInterval(-492), headline: nil, finished: nil,
                     subagents: subs.filter(\.isLive).count, waiting: runs.filter { $0.waiting == true }.count)
    }

    static func startIfRequested() async {
        guard requested else { return }
        for old in Activity<JoeBroActivityAttributes>.activities { await old.end(nil, dismissalPolicy: .immediate) }
        let attrs = JoeBroActivityAttributes(id: "agents", sceneName: "off", destination: "joebro://agents")
        _ = try? Activity.request(attributes: attrs, content: .init(state: demoState(), staleDate: nil), pushType: nil)
    }

    @ViewBuilder static func snapshotOverlay() -> some View {
        if previewRequested {
            let args = ProcessInfo.processInfo.arguments
            let variant = args.contains("-JoeBroPreviewSingle") ? 1 : args.contains("-JoeBroPreviewLong") ? 2 : 0
            let state = demoState(longTitle: variant == 2, agentLimit: variant == 1 ? 1 : nil)
            VStack(spacing: 24) {
                Text("Lock screen").font(.caption).foregroundStyle(.secondary)
                JoeBroLockScreenActivity(state: state, isStale: false)
                    .frame(width: 358, height: 160, alignment: .top)
                    .background(Color(red: 0.12, green: 0.08, blue: 0.22))
                    .clipShape(RoundedRectangle(cornerRadius: 24))
                    .overlay(RoundedRectangle(cornerRadius: 24).stroke(.red.opacity(0.6), lineWidth: 0.5))
                Text("Expanded Dynamic Island").font(.caption).foregroundStyle(.secondary)
                VStack(spacing: 4) {
                    HStack {
                        Image(systemName: "sparkles").font(.system(size: 18)).foregroundStyle(Color(red: 0.72, green: 0.78, blue: 1))
                            .frame(width: 24, height: 24)
                        Spacer()
                        Text(title(state, stale: false)).font(.system(.subheadline, design: .rounded).weight(.bold)).foregroundStyle(.white)
                        Spacer()
                        Text(state.startedAt, style: .timer).font(.system(.caption, design: .rounded).monospacedDigit())
                            .foregroundStyle(.secondary).frame(maxWidth: 48, alignment: .trailing)
                    }
                    JoeBroExpandedIslandContent(state: state)
                }
                .padding(.horizontal, 18).padding(.vertical, 16)
                .frame(width: 370, height: 160, alignment: .top)
                .background(Color.black)
                .clipShape(RoundedRectangle(cornerRadius: 44))
            }
            .padding(.top, 60)
            .frame(maxWidth: .infinity, maxHeight: .infinity, alignment: .top)
            .background(Color(white: 0.18))
        }
    }
}
#endif
