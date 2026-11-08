import ActivityKit
import Foundation

/// Keeps ONE summary Live Activity in sync with the running agents. Stateless:
/// the activity is found through `Activity.activities`, so any instance works.
/// Updates happen while the app is running (RootView polls); there is no push.
@MainActor
final class JoeBroActivityController {
    private static let summaryID = "agents"
    private static let maxRuns = 4

    var isAvailable: Bool { ActivityAuthorizationInfo().areActivitiesEnabled }

    func refreshScene() async { await sync() }

    func endAll() async {
        for activity in Activity<JoeBroActivityAttributes>.activities {
            await activity.end(nil, dismissalPolicy: .immediate)
        }
    }

    /// Old builds started one activity per agent or per briefing. Remove them.
    func endLegacyBriefings() async {
        for activity in Activity<JoeBroActivityAttributes>.activities
        where activity.attributes.id != Self.summaryID {
            await activity.end(nil, dismissalPolicy: .immediate)
        }
    }

    // The controller is instantiated in several places, so the two sources
    // (agent registry, in-flight chat turns) live in static storage and every
    // entry point funnels into one `sync()`. The activity ends only when both
    // are idle.
    private static var agents: [JBAgentRecord] = []
    private static var chatTurns: [String: String] = [:]   // sessionID -> title
    private static var chatOrder: [String] = []
    private static var chatBegan: [String: Date] = [:]
    private static var keepAlive: Task<Void, Never>?
    private static var lastLive: [String: String] = [:]   // live agent id -> title, to name the outcome
    private static var failedTurn = false

    /// A failed GET must not call this (the caller only reconciles on success),
    /// so being offline never dismisses a still-running activity.
    func reconcileAgents(_ agents: [JBAgentRecord], activeTurns: [String]? = nil) async {
        await endLegacyBriefings()
        // A turn whose stream was lost (backgrounded, network drop) never calls
        // chatTurnEnded; the server is the truth about which turns still run.
        if let activeTurns {
            let live = Set(activeTurns)
            for id in Self.chatOrder where !live.contains(id)
                && Date().timeIntervalSince(Self.chatBegan[id] ?? .distantPast) > 30 {
                Self.chatTurns[id] = nil
                Self.chatBegan[id] = nil
            }
            Self.chatOrder.removeAll { Self.chatTurns[$0] == nil }
        }
        // Anything that was live and is now failed makes the finish state "failed".
        for (id, _) in Self.lastLive {
            if let r = agents.first(where: { $0.id == id }), r.status == "failed" { Self.failedTurn = true }
        }
        Self.agents = Self.uniqueBySession(agents.filter { $0.kind != .briefing && !$0.isSessionOnly && $0.isLive })
        Self.lastLive = Dictionary(Self.agents.map { ($0.id, $0.displayTitle) }, uniquingKeysWith: { a, _ in a })
        await sync()
    }

    /// Call (on the main actor) when a chat turn starts streaming, while the
    /// app is still foregrounded, so the island is up before the user leaves.
    func chatTurnBegan(sessionID: String, title: String) async {
        let clean = title.trimmingCharacters(in: .whitespacesAndNewlines)
        Self.chatTurns[sessionID] = clean.isEmpty ? "JoeBro" : clean
        Self.chatBegan[sessionID] = .now
        if !Self.chatOrder.contains(sessionID) { Self.chatOrder.append(sessionID) }
        Self.startKeepAlive()
        await sync()
    }

    /// Call on every exit path of a turn (done, error, cancel).
    func chatTurnEnded(sessionID: String, failed: Bool = false) async {
        if failed { Self.failedTurn = true }
        Self.chatTurns[sessionID] = nil
        Self.chatBegan[sessionID] = nil
        Self.chatOrder.removeAll { $0 == sessionID }
        await sync()
    }

    /// Re-pushes the content while a chat turn runs so the staleDate keeps
    /// moving and a foregrounded, healthy activity never reads "paused".
    private static func startKeepAlive() {
        guard keepAlive == nil else { return }
        keepAlive = Task { @MainActor in
            while !Task.isCancelled, !chatTurns.isEmpty {
                try? await Task.sleep(for: .seconds(30))
                if Task.isCancelled { break }
                await JoeBroActivityController().sync()
            }
            keepAlive = nil
        }
    }

    private func sync() async {
        let chats = Self.chatOrder.compactMap { id in Self.chatTurns[id].map { (id, $0) } }
        var current = Activity<JoeBroActivityAttributes>.activities.first {
            $0.attributes.id == Self.summaryID && $0.activityState == .active
        }
        // The header scene is part of the activity's static attributes, so a new
        // choice needs a fresh activity.
        let scene = UserDefaults.standard.string(forKey: "backgroundAnimation") ?? "off"
        if let old = current, old.attributes.sceneName != scene {
            await old.end(nil, dismissalPolicy: .immediate)
            current = nil
        }
        guard !chats.isEmpty || !Self.agents.isEmpty else {
            if let current {
                if current.content.state.finished == nil {
                    let failed = Self.failedTurn
                    let done = ActivityContent(
                        state: JoeBroActivityAttributes.ContentState(count: 0, runs: [], startedAt: current.content.state.startedAt,
                                     headline: failed ? "Something went wrong" : "JoeBro finished",
                                     finished: failed ? "failed" : "done"),
                        staleDate: nil)
                    await current.end(done, dismissalPolicy: .after(.now.addingTimeInterval(300)))
                    Self.failedTurn = false
                    Self.lastLive = [:]
                }
                // A turn may have begun while the end was in flight.
                if !Self.chatTurns.isEmpty || !Self.agents.isEmpty { await sync() }
            }
            return
        }
        guard isAvailable else { return }
        // A streaming chat turn is also registered by the backend as a "chat" agent
        // with the same session: show it once (as the reply), never twice.
        let chatSessions = Set(chats.map(\.0))
        let agentRuns = Self.agents.filter { agent in
            guard let s = agent.sessionID, !s.isEmpty else { return true }
            return !chatSessions.contains(s)
        }
        let chatRuns = chats.map { id, title in
            JoeBroActivityAttributes.Run(id: "chat-" + id, title: title, kind: "reply",
                                         detail: "", queued: false)
        }
        let all = chatRuns + agentRuns.map(Self.run)
        let headline: String? = agentRuns.isEmpty
            ? (chats.count == 1 ? "JoeBro is replying" : "\(chats.count) chats replying")
            : nil
        let state = JoeBroActivityAttributes.ContentState(
            count: all.count,
            runs: Array(all.prefix(Self.maxRuns)),
            startedAt: current?.content.state.startedAt ?? .now,
            headline: headline,
            finished: nil
        )
        let content = ActivityContent(state: state, staleDate: .now.addingTimeInterval(120))
        if let current {
            let fresh = (current.content.staleDate ?? .distantPast).timeIntervalSinceNow > 60
            if current.content.state != state || !fresh { await current.update(content) }
        } else {
            let attributes = JoeBroActivityAttributes(id: Self.summaryID, sceneName: scene, destination: "joebro://agents")
            Self.failedTurn = false
            if let activity = try? Activity.request(attributes: attributes, content: content, pushType: .token) {
                Self.observePushToken(activity)
            }
        }
    }

    /// Sends the activity's push token to the backend so it can end the island
    /// (liveactivity push) when the app is backgrounded and cannot update it.
    private static func observePushToken(_ activity: Activity<JoeBroActivityAttributes>) {
        Task {
            for await data in activity.pushTokenUpdates {
                let token = data.map { String(format: "%02x", $0) }.joined()
                guard let env = apnsEnvironment(), let api = ServerConfig.api()
                else { continue }
                let _: JoeBroAPI.OK? = try? await api.send(JoeBroAPI.OK.self, "/api/push/activity",
                                                           json: ["token": token, "environment": env])
            }
        }
    }

    private static func apnsEnvironment() -> String? {
        guard let path = Bundle.main.path(forResource: "embedded", ofType: "mobileprovision"),
              let data = FileManager.default.contents(atPath: path),
              let text = String(data: data, encoding: .isoLatin1),
              let start = text.range(of: "<?xml"), let end = text.range(of: "</plist>"),
              let plist = try? PropertyListSerialization.propertyList(
                from: Data(text[start.lowerBound..<end.upperBound].utf8), format: nil) as? [String: Any],
              let ent = plist["Entitlements"] as? [String: Any],
              let env = ent["aps-environment"] as? String else { return nil }
        return env
    }

    /// One live entry per session; agents without a session (coding agents,
    /// research) are each their own work and kept as-is.
    static func uniqueBySession(_ agents: [JBAgentRecord]) -> [JBAgentRecord] {
        var seen = Set<String>()
        return agents.filter { agent in
            guard let s = agent.sessionID?.trimmingCharacters(in: .whitespaces), !s.isEmpty else { return true }
            return seen.insert(s).inserted
        }
    }

    private static func run(_ agent: JBAgentRecord) -> JoeBroActivityAttributes.Run {
        .init(
            id: agent.id,
            title: agent.displayTitle,
            kind: (agent.kind ?? .unknown).rawValue,
            detail: agent.progress?.trimmingCharacters(in: .whitespacesAndNewlines) ?? "",
            queued: agent.status == "queued"
        )
    }
}
