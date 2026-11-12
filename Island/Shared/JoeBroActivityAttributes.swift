import ActivityKit
import Foundation

/// Compiled into both the app and the JoeBroIsland widget extension.
/// One Live Activity summarises every running agent.
struct JoeBroActivityAttributes: ActivityAttributes {
    struct Run: Codable, Hashable, Identifiable {
        var id: String
        var title: String
        /// "research", "chat", "task" or "unknown".
        var kind: String
        /// Latest progress text from the backend (may be empty).
        var detail: String
        var queued: Bool
        /// Live subagents this run spawned (nil from older builds and pushes).
        var subagents: Int? = nil
        /// True while the run waits for an approval.
        var waiting: Bool? = nil
        /// Up to three subagents, shown nested under the run.
        var children: [Child]? = nil
    }

    /// One subagent of a run: id, title and "running", "done", "failed" or "queued".
    struct Child: Codable, Hashable, Identifiable {
        var id: String
        var title: String
        var status: String
    }

    struct ContentState: Codable, Hashable {
        /// Total running agents; `runs` holds at most the first few.
        var count: Int
        var runs: [Run]
        var startedAt: Date
        /// Overrides the "N agents working" title (e.g. a chat reply).
        var headline: String?
        /// nil while running; "done" or "failed" once finished.
        var finished: String?
        /// Live subagents across all runs, and runs waiting for approval.
        /// Optional so pushes from older backends still decode.
        var subagents: Int? = nil
        var waiting: Int? = nil
    }

    /// Always "agents": there is a single summary activity.
    var id: String
    /// Header scene shown behind the lock-screen activity ("off" or nil for none).
    var sceneName: String? = nil
    /// App deep link, `joebro://agents`.
    var destination: String
}
