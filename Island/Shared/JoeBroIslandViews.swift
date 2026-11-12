import SwiftUI

let islandTint = Color(red: 0.72, green: 0.78, blue: 1)

func title(_ s: JoeBroActivityAttributes.ContentState, stale: Bool) -> String {
    if s.finished != nil { return s.headline ?? "Done" }
    return stale ? "Update paused" : s.headline ?? summary(s.count)
}

/// "3 subagents" / "1 waiting", or nil when there is nothing to add.
func extras(_ s: JoeBroActivityAttributes.ContentState) -> String? {
    var parts: [String] = []
    if let n = s.subagents, n > 0 { parts.append(n == 1 ? "1 subagent" : "\(n) subagents") }
    if let w = s.waiting, w > 0 { parts.append("\(w) waiting") }
    return parts.isEmpty ? nil : parts.joined(separator: " · ")
}

func glyph(_ s: JoeBroActivityAttributes.ContentState) -> String {
    switch s.finished {
    case "done": "checkmark.circle.fill"
    case "failed": "exclamationmark.triangle.fill"
    default: "sparkles"
    }
}

func summary(_ count: Int) -> String {
    count == 1 ? "1 agent working" : "\(count) agents working"
}

func activityBackdrop(scene: String?) -> some View {
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

/// Awaiting approval first (needs the user), then running, then queued; stable inside each group.
func prioritised(_ runs: [JoeBroActivityAttributes.Run]) -> [JoeBroActivityAttributes.Run] {
    func rank(_ r: JoeBroActivityAttributes.Run) -> Int { r.waiting == true ? 0 : (r.queued ? 2 : 1) }
    return runs.enumerated().sorted { (rank($0.element), $0.offset) < (rank($1.element), $1.offset) }.map(\.element)
}

let waitingTint = Color.orange

/// Dot for the whole activity: orange while anything waits for approval, green when finished.
func statusColor(_ s: JoeBroActivityAttributes.ContentState) -> Color {
    if s.finished == "failed" { return .red }
    if s.finished != nil { return .green }
    return (s.waiting ?? 0) > 0 || s.runs.contains { $0.waiting == true } ? waitingTint : islandTint
}

/// Bottom region of the expanded island (about 160pt in total with the header).
struct JoeBroExpandedIslandContent: View {
    let state: JoeBroActivityAttributes.ContentState
    var body: some View {
        JoeBroRunList(state: state, rows: state.count <= 3 ? 3 : 2, rowHeight: 20)
            .padding(.horizontal, 4)
    }
}

struct JoeBroLockScreenActivity: View {
    let state: JoeBroActivityAttributes.ContentState
    let isStale: Bool

    var body: some View {
        VStack(alignment: .leading, spacing: 6) {
            HStack(spacing: 6) {
                Image(systemName: glyph(state)).foregroundStyle(islandTint)
                    .font(.system(size: 15)).frame(width: 18, height: 18)
                Text(title(state, stale: isStale))
                    .font(.system(.subheadline, design: .rounded).weight(.bold))
                    .foregroundStyle(.white)
                    .lineLimit(1).minimumScaleFactor(0.75)
                Spacer(minLength: 6)
                if state.finished == nil {
                    Text(state.startedAt, style: .timer)
                        .font(.caption.monospacedDigit())
                        .foregroundStyle(Color.white.opacity(0.65))
                        .frame(maxWidth: 50, alignment: .trailing)
                }
            }
            .frame(height: 20)
            JoeBroRunList(state: state, rows: 3, rowHeight: 24)
        }
        .padding(.horizontal, 16)
        .padding(.vertical, 12)
        .frame(maxHeight: 160, alignment: .top)
    }
}

/// The 2-3 most relevant rows (running, then approval, then queued), then "+N more".
/// Subagents never get rows: they collapse into a count on their parent.
struct JoeBroRunList: View {
    let state: JoeBroActivityAttributes.ContentState
    let rows: Int
    let rowHeight: CGFloat

    var body: some View {
        let runs = prioritised(state.runs)
        let hidden = max(0, state.count - min(rows, runs.count))
        VStack(alignment: .leading, spacing: 3) {
            ForEach(runs.prefix(rows)) { run in
                JoeBroRunRow(run: run, detailed: state.count == 1, height: rowHeight)
            }
            if hidden > 0 {
                Text("+\(hidden) more")
                    .font(.caption2)
                    .foregroundStyle(Color.white.opacity(0.65))
                    .padding(.leading, 24)
                    .frame(height: 12)
            }
        }
    }
}

struct JoeBroRunRow: View {
    let run: JoeBroActivityAttributes.Run
    let detailed: Bool
    let height: CGFloat

    var body: some View {
        let waiting = run.waiting == true
        HStack(spacing: 8) {
            Image(systemName: symbol)
                .font(.system(size: 13, weight: .medium))
                .foregroundStyle(waiting ? waitingTint : islandTint)
                .frame(width: 18, height: 18)
            VStack(alignment: .leading, spacing: 0) {
                Text(run.title)
                    .font(.system(size: 14, weight: .semibold))
                    .foregroundStyle(.white)
                    .lineLimit(1).minimumScaleFactor(0.85)
                if detailed, !subtitle.isEmpty {
                    Text(subtitle).font(.caption2)
                        .foregroundStyle(Color.white.opacity(0.65)).lineLimit(1)
                }
            }
            Spacer(minLength: 4)
            trailing(waiting: waiting).layoutPriority(1)
        }
        .frame(height: detailed ? height + 12 : height)
    }

    @ViewBuilder func trailing(waiting: Bool) -> some View {
        if waiting {
            HStack(spacing: 3) {
                Circle().fill(waitingTint).frame(width: 6, height: 6)
                Text("Approval").font(.system(size: 11, weight: .semibold)).foregroundStyle(waitingTint)
            }.fixedSize()
        } else if let n = run.subagents, n > 0 {
            Text("+\(n) subagent\(n == 1 ? "" : "s")")
                .font(.system(size: 11)).foregroundStyle(Color.white.opacity(0.65))
                .lineLimit(1).fixedSize()
        } else if run.queued {
            Text("Queued").font(.system(size: 11)).foregroundStyle(Color.white.opacity(0.65)).fixedSize()
        }
    }

    var subtitle: String { run.detail }

    var symbol: String {
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
