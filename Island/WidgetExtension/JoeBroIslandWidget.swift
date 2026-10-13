import ActivityKit
import SwiftUI
import WidgetKit

@main
struct JoeBroIslandBundle: WidgetBundle {
    var body: some Widget {
        JoeBroIslandWidget()
    }
}

private let islandTint = Color(red: 0.72, green: 0.78, blue: 1)

private func title(_ s: JoeBroActivityAttributes.ContentState, stale: Bool) -> String {
    if s.finished != nil { return s.headline ?? "Done" }
    return stale ? "Update paused" : s.headline ?? summary(s.count)
}

private func glyph(_ s: JoeBroActivityAttributes.ContentState) -> String {
    switch s.finished {
    case "done": "checkmark.circle.fill"
    case "failed": "exclamationmark.triangle.fill"
    default: "sparkles"
    }
}

private func summary(_ count: Int) -> String {
    count == 1 ? "1 agent working" : "\(count) agents working"
}

struct JoeBroIslandWidget: Widget {
    var body: some WidgetConfiguration {
        ActivityConfiguration(for: JoeBroActivityAttributes.self) { context in
            JoeBroLockScreenActivity(state: context.state, isStale: context.isStale)
                .activityBackgroundTint(Color(red: 0.12, green: 0.08, blue: 0.22).opacity(0.85))
                .activitySystemActionForegroundColor(islandTint)
                .widgetURL(URL(string: context.attributes.destination))
        } dynamicIsland: { context in
            DynamicIsland {
                DynamicIslandExpandedRegion(.leading) {
                    Image(systemName: "sparkles")
                        .font(.title2)
                        .foregroundStyle(islandTint)
                        .padding(.leading, 4)
                }
                DynamicIslandExpandedRegion(.trailing) {
                    if context.state.finished == nil {
                        Text(context.state.startedAt, style: .timer)
                            .font(.system(.subheadline, design: .rounded).monospacedDigit())
                            .foregroundStyle(HierarchicalShapeStyle.secondary)
                            .frame(maxWidth: 56, alignment: .trailing)
                            .padding(.trailing, 4)
                    }
                }
                DynamicIslandExpandedRegion(.center) {
                    Text(title(context.state, stale: context.isStale))
                        .font(.system(.headline, design: .rounded).weight(.bold))
                        .foregroundStyle(.white)
                }
                DynamicIslandExpandedRegion(.bottom) {
                    JoeBroRunList(state: context.state)
                        .padding(.horizontal, 6)
                }
            } compactLeading: {
                Image(systemName: glyph(context.state)).foregroundStyle(islandTint)
            } compactTrailing: {
                if context.state.finished != nil {
                    Image(systemName: glyph(context.state)).foregroundStyle(islandTint)
                } else {
                Text("\(context.state.count)")
                    .font(.system(.subheadline, design: .rounded).weight(.bold).monospacedDigit())
                    .foregroundStyle(.white)
                }
            } minimal: {
                Image(systemName: glyph(context.state)).foregroundStyle(islandTint)
            }
            .keylineTint(islandTint)
            .widgetURL(URL(string: context.attributes.destination))
        }
    }
}

private struct JoeBroLockScreenActivity: View {
    let state: JoeBroActivityAttributes.ContentState
    let isStale: Bool

    var body: some View {
        VStack(alignment: .leading, spacing: 10) {
            HStack {
                Image(systemName: glyph(state)).foregroundStyle(islandTint)
                Text(title(state, stale: isStale))
                    .font(.system(.headline, design: .rounded).weight(.bold))
                    .foregroundStyle(.white)
                Spacer(minLength: 8)
                if state.finished == nil {
                    Text(state.startedAt, style: .timer)
                        .font(.caption.monospacedDigit())
                        .foregroundStyle(HierarchicalShapeStyle.secondary)
                }
            }
            JoeBroRunList(state: state)
        }
        .padding(16)
    }
}

/// Up to three rows, then "+N more". Used by the expanded island and Lock Screen.
private struct JoeBroRunList: View {
    let state: JoeBroActivityAttributes.ContentState
    private let shown = 3

    var body: some View {
        VStack(alignment: .leading, spacing: 8) {
            ForEach(state.runs.prefix(shown)) { run in
                JoeBroRunRow(run: run)
            }
            if state.count > shown {
                Text("+\(state.count - shown) more")
                    .font(.caption)
                    .foregroundStyle(HierarchicalShapeStyle.secondary)
            }
        }
    }
}

private struct JoeBroRunRow: View {
    let run: JoeBroActivityAttributes.Run

    var body: some View {
        HStack(spacing: 10) {
            Image(systemName: symbol)
                .font(.subheadline)
                .foregroundStyle(islandTint)
                .frame(width: 22)
            VStack(alignment: .leading, spacing: 1) {
                Text(run.title)
                    .font(.subheadline.weight(.semibold))
                    .foregroundStyle(.white)
                    .lineLimit(1)
                Text(subtitle)
                    .font(.caption)
                    .foregroundStyle(HierarchicalShapeStyle.secondary)
                    .lineLimit(1)
            }
            Spacer(minLength: 0)
        }
    }

    private var subtitle: String {
        let label = run.queued ? "Queued" : kindLabel
        return run.detail.isEmpty ? label : "\(label) · \(run.detail)"
    }

    private var kindLabel: String {
        switch run.kind {
        case "research": "Research"
        case "chat": "Chat"
        case "reply": "Replying"
        case "task": "Task"
        default: "Agent"
        }
    }

    private var symbol: String {
        switch run.kind {
        case "research": "magnifyingglass"
        case "chat": "bubble.left.and.bubble.right"
        case "reply": "ellipsis.bubble"
        case "task": "clock.arrow.circlepath"
        default: "sparkles"
        }
    }
}
