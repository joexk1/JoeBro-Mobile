import SwiftUI
import AppIntents

// Live Activity / Dynamic Island views. This file is compiled into the widget extension, which cannot
// import Design/*: the few JB tokens it needs are mirrored here (dark values; the lock screen is dark).

enum IslandInk {
    static let bg = Color(red: 0.039, green: 0.039, blue: 0.043)        // JB.bg dark 0A0A0B
    static let raised = Color(red: 0.102, green: 0.102, blue: 0.110)    // 1A1A1C
    static let line = Color(red: 0.145, green: 0.145, blue: 0.157)      // 252528
    static let ink = Color(red: 0.929, green: 0.929, blue: 0.925)       // EDEDEC
    static let ink2 = Color(red: 0.604, green: 0.604, blue: 0.624)      // 9A9A9F
    static let ink3 = Color(red: 0.369, green: 0.369, blue: 0.388)      // 5E5E63
    static let live = Color(red: 0.373, green: 0.820, blue: 0.690)      // 5FD1B0
    static let warn = Color(red: 0.961, green: 0.722, blue: 0.239)      // F5B83D
    static let danger = Color(red: 1, green: 0.353, blue: 0.290)        // FF5A4A
}

/// Geist (Mono) when the extension bundles it; the system faces otherwise.
extension Font {
    static func islandMono(_ size: CGFloat, _ weight: Font.Weight = .regular) -> Font {
        let face = weight == .semibold || weight == .bold ? "GeistMono-SemiBold" : weight == .medium ? "GeistMono-Medium" : "GeistMono-Regular"
        return .custom(face, size: size)
    }
    static func islandSans(_ size: CGFloat, _ weight: Font.Weight = .regular) -> Font {
        .custom(weight == .semibold || weight == .bold ? "Geist-SemiBold" : weight == .medium ? "Geist-Medium" : "Geist-Regular", size: size)
    }
}

let islandTint = IslandInk.live
let waitingTint = IslandInk.warn

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

func summary(_ count: Int) -> String {
    count == 1 ? "1 agent working" : "\(count) agents working"
}

/// Mono ASCII mark for a run kind or the activity state, drawn in a hairline square.
func islandMark(_ s: JoeBroActivityAttributes.ContentState) -> String {
    switch s.finished {
    case "done": "ok"
    case "failed": "!!"
    default: "o_o"
    }
}

func runMark(_ kind: String) -> String {
    switch kind {
    case "coding": ">_"
    case "research": "/?"
    case "task": "[]"
    case "reply", "chat": "..."
    default: "o_o"
    }
}

struct IslandMark: View {
    let text: String
    var tint: Color = IslandInk.ink2
    var size: CGFloat = 20
    var body: some View {
        Text(text).font(.islandMono(size * 0.45, .semibold)).foregroundStyle(tint)
            .frame(width: size, height: size)
            .overlay(RoundedRectangle(cornerRadius: 5, style: .continuous).strokeBorder(IslandInk.line, lineWidth: 1))
    }
}

/// Dot-matrix numerals, the same 3x5 grid as JBDotNumber in the app.
struct IslandDots: View {
    let value: Int
    var dot: CGFloat = 2
    var tint: Color = IslandInk.ink
    private static let digits: [Character: [String]] = [
        "0": ["###", "#.#", "#.#", "#.#", "###"], "1": [".#.", "##.", ".#.", ".#.", "###"],
        "2": ["###", "..#", "###", "#..", "###"], "3": ["###", "..#", ".##", "..#", "###"],
        "4": ["#.#", "#.#", "###", "..#", "..#"], "5": ["###", "#..", "###", "..#", "###"],
        "6": ["###", "#..", "###", "#.#", "###"], "7": ["###", "..#", ".#.", ".#.", ".#."],
        "8": ["###", "#.#", "###", "#.#", "###"], "9": ["###", "#.#", "###", "..#", "..#"]
    ]
    var body: some View {
        let chars = Array(String(min(max(value, 0), 99)))
        let pitch = dot * 1.9
        Canvas { ctx, _ in
            for (i, ch) in chars.enumerated() {
                guard let rows = Self.digits[ch] else { continue }
                for (y, row) in rows.enumerated() {
                    for (x, c) in row.enumerated() where c == "#" {
                        let px = CGFloat(i * 4 + x) * pitch, py = CGFloat(y) * pitch
                        ctx.fill(Path(ellipseIn: CGRect(x: px, y: py, width: dot, height: dot)), with: .color(tint))
                    }
                }
            }
        }
        .frame(width: CGFloat(chars.count * 4 - 1) * pitch, height: 5 * pitch - (pitch - dot))
    }
}

func activityBackdrop(scene: String?) -> some View {
    ZStack {
        IslandInk.bg
        if let scene, scene != "off" {
            GeometryReader { geo in
                Image("scene-" + scene).resizable().scaledToFill()
                    .frame(width: geo.size.width, height: geo.size.height).clipped()
            }
            Color.black.opacity(0.62)
        }
    }.clipped()
}

/// Awaiting approval first (needs the user), then running, then queued; stable inside each group.
func prioritised(_ runs: [JoeBroActivityAttributes.Run]) -> [JoeBroActivityAttributes.Run] {
    func rank(_ r: JoeBroActivityAttributes.Run) -> Int { r.waiting == true ? 0 : (r.queued ? 2 : 1) }
    return runs.enumerated().sorted { (rank($0.element), $0.offset) < (rank($1.element), $1.offset) }.map(\.element)
}

/// Dot for the whole activity: amber while anything waits for approval, phosphor while running.
func statusColor(_ s: JoeBroActivityAttributes.ContentState) -> Color {
    if s.finished == "failed" { return IslandInk.danger }
    if s.finished != nil { return IslandInk.ink2 }
    return (s.waiting ?? 0) > 0 || s.runs.contains { $0.waiting == true } ? waitingTint : islandTint
}

/// Bottom region of the expanded island (about 160pt in total with the header).
struct JoeBroExpandedIslandContent: View {
    let state: JoeBroActivityAttributes.ContentState
    var body: some View {
        JoeBroRunList(state: state, rows: state.count <= 3 ? 3 : 2, rowHeight: 22)
            .padding(.horizontal, 4)
    }
}

struct JoeBroLockScreenActivity: View {
    let state: JoeBroActivityAttributes.ContentState
    let isStale: Bool

    var body: some View {
        VStack(alignment: .leading, spacing: 8) {
            HStack(spacing: 8) {
                IslandMark(text: islandMark(state), tint: statusColor(state), size: 22)
                Text(title(state, stale: isStale))
                    .font(.islandSans(15, .semibold))
                    .foregroundStyle(IslandInk.ink)
                    .lineLimit(1).minimumScaleFactor(0.75)
                Spacer(minLength: 6)
                if state.finished == nil {
                    Text(state.startedAt, style: .timer)
                        .font(.islandMono(11))
                        .foregroundStyle(IslandInk.ink3)
                        .frame(maxWidth: 50, alignment: .trailing)
                }
            }
            .frame(height: 22)
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
                    .font(.islandMono(10.5))
                    .foregroundStyle(IslandInk.ink3)
                    .padding(.leading, 28)
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
            IslandMark(text: runMark(run.kind), tint: waiting ? waitingTint : islandTint, size: 20)
            VStack(alignment: .leading, spacing: 0) {
                Text(run.title)
                    .font(.islandSans(13.5, .medium))
                    .foregroundStyle(IslandInk.ink)
                    .lineLimit(1).minimumScaleFactor(0.85)
                if detailed, !run.detail.isEmpty {
                    Text(run.detail).font(.islandMono(10.5))
                        .foregroundStyle(IslandInk.ink2).lineLimit(1)
                }
            }
            Spacer(minLength: 4)
            trailing(waiting: waiting).layoutPriority(1)
        }
        .frame(height: detailed ? height + 12 : height)
    }

    @ViewBuilder func trailing(waiting: Bool) -> some View {
        if waiting {
            if run.kind == "coding" {
                HStack(spacing: 6) {
                    Button(intent: JoeBroApprovalIntent(agentID: run.id, approve: false)) {
                        Text("Deny").font(.islandMono(11, .medium)).foregroundStyle(IslandInk.danger)
                            .padding(.horizontal, 8).frame(height: 24)
                            .background(IslandInk.raised, in: RoundedRectangle(cornerRadius: 6, style: .continuous))
                    }
                    Button(intent: JoeBroApprovalIntent(agentID: run.id, approve: true)) {
                        Text("Approve").font(.islandMono(11, .semibold)).foregroundStyle(IslandInk.bg)
                            .padding(.horizontal, 8).frame(height: 24)
                            .background(waitingTint, in: RoundedRectangle(cornerRadius: 6, style: .continuous))
                    }
                }
                .buttonStyle(.plain).fixedSize()
            } else {
                HStack(spacing: 4) {
                    Circle().fill(waitingTint).frame(width: 6, height: 6)
                    Text("needs you").font(.islandMono(10.5, .medium)).foregroundStyle(waitingTint)
                }.fixedSize()
            }
        } else if let n = run.subagents, n > 0 {
            Text("+\(n) sub")
                .font(.islandMono(10.5)).foregroundStyle(IslandInk.ink3)
                .lineLimit(1).fixedSize()
        } else if run.queued {
            Text("queued").font(.islandMono(10.5)).foregroundStyle(IslandInk.ink3).fixedSize()
        } else {
            Circle().fill(islandTint).frame(width: 6, height: 6)
        }
    }
}
