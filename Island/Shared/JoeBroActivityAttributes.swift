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
    }

    /// Always "agents": there is a single summary activity.
    var id: String
    /// App deep link, `joebro://agents`.
    var destination: String
}
