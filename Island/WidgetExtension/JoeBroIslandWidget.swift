import ActivityKit
import SwiftUI
import WidgetKit
import UIKit

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

/// "3 subagents" / "1 waiting", or nil when there is nothing to add.
private func extras(_ s: JoeBroActivityAttributes.ContentState) -> String? {
    var parts: [String] = []
    if let n = s.subagents, n > 0 { parts.append(n == 1 ? "1 subagent" : "\(n) subagents") }
    if let w = s.waiting, w > 0 { parts.append("\(w) waiting") }
    return parts.isEmpty ? nil : parts.joined(separator: " · ")
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

private func activityBackdrop(scene: String?) -> some View {
    ZStack {
        if let scene, scene != "off" {
            Color.black
            GeometryReader { geo in
                Image("scene-" + scene).resizable().scaledToFill()
                    .frame(width: geo.size.width, height: geo.size.height).clipped()
            }
            Color.black.opacity(0.48)
        }
    }.clipped()
}

struct JoeBroIslandWidget: Widget {
    var body: some WidgetConfiguration {
        ActivityConfiguration(for: JoeBroActivityAttributes.self) { context in
            JoeBroLockScreenActivity(state: context.state, isStale: context.isStale)
                .background { activityBackdrop(scene: context.attributes.sceneName) }
                .activityBackgroundTint(context.attributes.sceneName.map { $0 != "off" } == true
                                        ? Color.black
                                        : Color(red: 0.12, green: 0.08, blue: 0.22).opacity(0.85))
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
                    VStack(spacing: 1) {
                        Text(title(context.state, stale: context.isStale))
                            .font(.system(.headline, design: .rounded).weight(.bold))
                            .foregroundStyle(.white)
                        if context.state.finished == nil, let e = extras(context.state) {
                            Text(e).font(.caption2).foregroundStyle(HierarchicalShapeStyle.secondary)
                        }
                    }
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
                HStack(spacing: 3) {
                    Text("\(context.state.count)")
                        .font(.system(.subheadline, design: .rounded).weight(.bold).monospacedDigit())
                        .foregroundStyle(.white)
                    if let n = context.state.subagents, n > 0 {
                        Image(systemName: "arrow.triangle.branch").font(.caption2).foregroundStyle(islandTint)
                        Text("\(n)").font(.caption2.monospacedDigit()).foregroundStyle(islandTint)
                    }
                }
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
                if state.finished == nil, let e = extras(state) {
                    Text(e).font(.caption).foregroundStyle(HierarchicalShapeStyle.secondary)
                }
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
                if let kids = run.children, !kids.isEmpty {
                    ForEach(kids.prefix(2)) { kid in
                        JoeBroChildRow(child: kid)
                    }
                    if let n = run.subagents, n > 2 {
                        Text("+\(n - 2) more subagents")
                            .font(.caption2).foregroundStyle(HierarchicalShapeStyle.tertiary)
                            .padding(.leading, 44)
                    }
                }
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
        case "coding": "Coding"
        default: "Agent"
        }
    }

    private var symbol: String {
        switch run.kind {
        case "research": "magnifyingglass"
        case "chat": "bubble.left.and.bubble.right"
        case "reply": "ellipsis.bubble"
        case "task": "clock.arrow.circlepath"
        case "coding": "chevron.left.forwardslash.chevron.right"
        default: "sparkles"
        }
    }
}

/// A subagent, indented under its run, with a status dot.
private struct JoeBroChildRow: View {
    let child: JoeBroActivityAttributes.Child

    var body: some View {
        HStack(spacing: 6) {
            Image(systemName: "arrow.turn.down.right").font(.caption2).foregroundStyle(HierarchicalShapeStyle.tertiary)
            Circle().fill(color).frame(width: 6, height: 6)
            Text(child.title).font(.caption).foregroundStyle(.white.opacity(0.85)).lineLimit(1)
            Spacer(minLength: 0)
        }
        .padding(.leading, 26)
    }

    private var color: Color {
        switch child.status {
        case "running": islandTint
        case "failed": .red
        case "done": .green
        default: .gray
        }
    }
}
