import SwiftUI

/// Rows enter once, when they are the newest message; older rows that the lazy
/// stack rebuilds while scrolling stay still.
private struct RowEnter: ViewModifier {
    @Environment(\.accessibilityReduceMotion) private var reduceMotion
    @State private var shown: Bool
    init(fresh: Bool) { _shown = State(initialValue: !fresh) }
    func body(content: Content) -> some View {
        content
            .opacity(shown ? 1 : 0)
            .offset(y: shown || reduceMotion ? 0 : 6)
            .onAppear { withAnimation(JB.smooth) { shown = true } }
    }
}

/// One transcript message, ink on paper: the user's turn is a raised card,
/// JoeBro's is plain text. Its own view so streaming re-renders one row.
struct ChatMessageRow: View {
    let line: ChatLine
    var fresh = false
    var onOpenDocument: (ChatDocumentRef) -> Void
    var onRetry: () -> Void = {}
    @State private var copied = false

    private var isUser: Bool { line.role == "user" }

    var body: some View {
        HStack(spacing: 0) {
            if isUser { Spacer(minLength: 44) }
            content
            if !isUser { Spacer(minLength: 16) }
        }
        .modifier(RowEnter(fresh: fresh))
        .contextMenu {
            if !line.text.isEmpty {
                Button("Copy", systemImage: "doc.on.doc") {
                    UIPasteboard.general.string = line.text
                    copied.toggle()
                }
            }
            if !line.streaming { Button("Retry", systemImage: "arrow.clockwise", action: onRetry) }
        }
        .sensoryFeedback(.success, trigger: copied)
    }

    @ViewBuilder private var content: some View {
        if isUser {
            VStack(alignment: .leading, spacing: 8) {
                messageBody
                attachmentChips
            }
            .padding(.horizontal, 14)
            .padding(.vertical, 11)
            .background(JB.raised, in: RoundedRectangle(cornerRadius: JB.rCard, style: .continuous))
            .overlay(RoundedRectangle(cornerRadius: JB.rCard, style: .continuous).strokeBorder(JB.line, lineWidth: 1))
        } else {
            VStack(alignment: .leading, spacing: 10) {
                if line.streaming && line.text.isEmpty && line.thinking.isEmpty && line.toolCalls.isEmpty {
                    JBScrambleText(text: "thinking", active: true)
                } else if !line.thinking.isEmpty {
                    thinkingBlock
                }
                if !line.toolCalls.isEmpty || !line.tools.isEmpty {
                    ChatToolActivity(calls: line.toolCalls, legacyNames: line.tools)
                }
                ForEach(line.visualizations.filter(\.isResult)) { visual in ChatVisualizationView(visual: visual) }
                messageBody
                if line.streaming && !line.text.isEmpty { JBStreamCursor() }
                ForEach(line.documents) { document in documentChip(document) }
                attachmentChips
            }
            .frame(maxWidth: .infinity, alignment: .leading)
        }
    }

    @ViewBuilder
    private var messageBody: some View {
        if !line.text.isEmpty {
            if isUser {
                Text(line.text)
                    .font(.jbBody)
                    .foregroundStyle(JB.ink)
                    .lineSpacing(3)
                    .textSelection(.enabled)
                    .frame(maxWidth: .infinity, alignment: .leading)
            } else {
                // Markdown renders while streaming too: MarkdownText already
                // tolerates an unclosed ``` fence, so the partial text is safe.
                MarkdownText(text: line.text)
                    .textSelection(.enabled)
                    .environment(\.openURL, documentLinkAction)
            }
        }
    }

    private var documentLinkAction: OpenURLAction {
        OpenURLAction { url in
            let anchor = url.fragment ?? url.absoluteString.trimmingCharacters(in: CharacterSet(charactersIn: "#"))
            guard anchor.hasPrefix("document-") else { return .systemAction }
            let id = String(anchor.dropFirst("document-".count))
            guard !id.isEmpty else { return .discarded }
            onOpenDocument(ChatDocumentRef(id: id, title: "Document", language: "markdown"))
            return .handled
        }
    }

    private var thinkingBlock: some View {
        ThinkingBlock(text: line.thinking, live: line.streaming && line.text.isEmpty)
    }

    @ViewBuilder
    private var attachmentChips: some View {
        ForEach(line.attachments, id: \.self) { name in
            Label(name, systemImage: "paperclip")
                .font(.jb(11))
                .foregroundStyle(JB.ink3)
                .lineLimit(1)
        }
    }

    private func documentChip(_ document: ChatDocumentRef) -> some View {
        Button { onOpenDocument(document) } label: {
            HStack(spacing: 10) {
                Image(systemName: "doc").foregroundStyle(JB.ink2)
                Text(document.title).font(.jb(14, .medium)).foregroundStyle(JB.ink).lineLimit(1)
                Spacer(minLength: 4)
                Image(systemName: "chevron.right").font(.jb(11, .medium)).foregroundStyle(JB.ink3)
            }
            .padding(.horizontal, 12)
            .frame(minHeight: 44)
            .jbSurface(.raised, radius: JB.rCard)
            .contentShape(Rectangle())
        }
        .buttonStyle(JBPressStyle())
        .accessibilityLabel("Open document \(document.title)")
    }
}

private struct ThinkingBlock: View {
    let text: String
    let live: Bool
    @State private var open = false
    var body: some View {
        VStack(alignment: .leading, spacing: 6) {
            Button { withAnimation(JB.snap) { open.toggle() } } label: {
                HStack(spacing: 6) {
                    if live { JBScrambleText(text: "thinking", active: true) }
                    else { Text("thought").font(.jb(12)).foregroundStyle(JB.ink3) }
                    Image(systemName: "chevron.right").font(.jb(9, .medium)).foregroundStyle(JB.ink3)
                        .rotationEffect(.degrees(open ? 90 : 0))
                }
                .frame(minHeight: 28)
                .contentShape(Rectangle())
            }
            .buttonStyle(.plain)
            if open {
                Text(text)
                    .font(.jb(13)).foregroundStyle(JB.ink2).lineSpacing(2)
                    .textSelection(.enabled)
                    .padding(.leading, 10)
                    .overlay(alignment: .leading) { Rectangle().fill(JB.line).frame(width: 1) }
                    .transition(.opacity)
            }
        }
    }
}

/// A factual snapshot emitted by a completed tool; never parsed from model prose.
struct ChatVisualization: Codable, Identifiable {
    struct Row: Codable, Identifiable {
        var id: String { title + detail + state }
        let title: String
        let detail: String
        let state: String
    }
    struct Metric: Codable, Identifiable {
        var id: String { label }
        let label: String
        let value: String
    }
    struct Point: Codable, Identifiable {
        var id: String { label }
        let label: String
        let value: Double
    }
    let id: String
    let kind: String
    let presentation: String?
    var isResult: Bool {
        kind == "plan" || presentation == "outcome" ||
        ["Calendar updated", "Reminder created", "Reminder updated", "Reminder completed", "Reminder reopened"].contains(title)
    }
    let title: String
    let subtitle: String
    let rows: [Row]
    let metrics: [Metric]
    let series: [Point]

    init?(json: JBJSON) {
        guard let id = json["id"]?.stringValue, let kind = json["kind"]?.stringValue,
              let title = json["title"]?.stringValue else { return nil }
        self.id = id; self.kind = kind; self.title = title
        presentation = json["presentation"]?.stringValue
        subtitle = json["subtitle"]?.stringValue ?? ""
        rows = (json["rows"]?.arrayValue ?? []).prefix(20).map {
            Row(title: $0["title"]?.stringValue ?? "", detail: $0["detail"]?.stringValue ?? "",
                state: $0["state"]?.stringValue ?? "")
        }
        metrics = (json["metrics"]?.arrayValue ?? []).prefix(6).map {
            Metric(label: $0["label"]?.stringValue ?? "", value: $0["value"]?.stringValue ?? "")
        }
        series = (json["series"]?.arrayValue ?? []).prefix(24).compactMap { item in
            guard let raw = item["value"], case .number(let value) = raw, value.isFinite else { return nil }
            return Point(label: item["label"]?.stringValue ?? "", value: value)
        }
    }
}

private struct ChatVisualizationView: View {
    let visual: ChatVisualization
    @State private var showAll = false

    private var tint: Color {
        switch visual.kind {
        case "calendar", "reminders": return JB.warn
        case "shopping", "health", "agents", "tasks", "plan": return JB.live
        default: return JB.accent
        }
    }
    @ViewBuilder private var symbol: some View {
        switch visual.kind {
        case "memory": JBIcon(.memory, size: 18)
        case "agents": JBIcon(.coding, size: 18)
        case "tasks", "plan": JBIcon(.tasks, size: 18)
        case "research": JBIcon(.research, size: 18)
        default: Image(systemName: Self.sfSymbol(visual.kind)).font(.jb(17, .regular))
        }
    }
    private static func sfSymbol(_ kind: String) -> String {
        switch kind {
        case "calendar": return "calendar"
        case "weather": return "cloud.sun"
        case "shopping": return "basket"
        case "reminders": return "bell"
        case "health": return "heart"
        case "email": return "envelope"
        default: return "square.grid.2x2"
        }
    }
    private var visibleRows: [ChatVisualization.Row] {
        showAll ? visual.rows : Array(visual.rows.prefix(5))
    }

    var body: some View {
        VStack(alignment: .leading, spacing: 14) {
            HStack(alignment: .top, spacing: 10) {
                symbol
                    .foregroundStyle(tint)
                    .frame(width: 32, height: 32)
                    .background(JB.raised, in: RoundedRectangle(cornerRadius: JB.rControl))
                VStack(alignment: .leading, spacing: 3) {
                    Text(visual.title).font(.jb(15, .semibold)).foregroundStyle(JB.ink)
                    if !visual.subtitle.isEmpty {
                        Text(visual.subtitle).font(.jb(11)).foregroundStyle(JB.ink3).fixedSize(horizontal: false, vertical: true)
                    }
                }
                Spacer(minLength: 0)
            }
            if !visual.metrics.isEmpty { metricStrip }
            if visual.series.count > 1 { trendLine }
            VStack(spacing: 0) {
                ForEach(Array(visibleRows.enumerated()), id: \.offset) { index, row in
                    rowView(row)
                    if index < visibleRows.count - 1 { Rectangle().fill(JB.line).frame(height: 1).padding(.vertical, 9) }
                }
            }
            if visual.rows.count > 5 {
                Button(showAll ? "Show less" : "Show all \(visual.rows.count)") { showAll.toggle() }
                    .font(.jb(11, .medium)).foregroundStyle(JB.ink2)
            }
        }
        .padding(14)
        .frame(maxWidth: .infinity, alignment: .leading)
        .jbSurface(.raised, radius: JB.rCard)
        .accessibilityElement(children: .contain)
    }

    private var metricStrip: some View {
        ViewThatFits(in: .horizontal) {
            HStack(alignment: .firstTextBaseline, spacing: 18) {
                ForEach(visual.metrics) { metric in metricView(metric) }
            }
            LazyVGrid(columns: [GridItem(.flexible(), alignment: .leading), GridItem(.flexible(), alignment: .leading)], alignment: .leading, spacing: 12) {
                ForEach(visual.metrics) { metric in metricView(metric) }
            }
        }
    }

    private func metricView(_ metric: ChatVisualization.Metric) -> some View {
        VStack(alignment: .leading, spacing: 4) {
            Text(metric.value).font(.jb(22, .medium)).foregroundStyle(JB.ink)
            Text(metric.label).font(.jb(10.5)).foregroundStyle(JB.ink3)
        }
    }

    private var trendLine: some View {
        VStack(spacing: 5) {
            Canvas { context, size in
                let values = visual.series.map(\.value)
                let lo = (values.min() ?? 0) - 1
                let span = max(2, (values.max() ?? 0) - lo + 1)
                var path = Path()
                for (index, value) in values.enumerated() {
                    let point = CGPoint(x: size.width * Double(index) / Double(max(1, values.count - 1)),
                                        y: size.height * (1 - (value - lo) / span))
                    if index == 0 { path.move(to: point) } else { path.addLine(to: point) }
                }
                context.stroke(path, with: .color(tint), style: StrokeStyle(lineWidth: 2.5, lineCap: .round, lineJoin: .round))
            }
            .frame(height: 48)
            HStack {
                Text(visual.series.first?.label ?? "")
                Spacer()
                Text(visual.series.last?.label ?? "")
            }
            .font(.jb(10.5)).foregroundStyle(JB.ink3)
        }
        .accessibilityLabel(visual.title + " trend: " + visual.series.map { "\($0.label), \($0.value.formatted())" }.joined(separator: "; "))
    }

    private func rowView(_ row: ChatVisualization.Row) -> some View {
        HStack(alignment: .top, spacing: 9) {
            if visual.kind == "shopping" || visual.kind == "plan" {
                Image(systemName: row.state == "done" ? "checkmark.circle" : "circle")
                    .foregroundStyle(row.state == "done" ? tint : JB.ink3)
                    .font(.jbSubheadline).padding(.top, 2)
            } else {
                RoundedRectangle(cornerRadius: 2).fill(tint.opacity(0.65)).frame(width: 3)
            }
            VStack(alignment: .leading, spacing: 3) {
                Text(row.title).font(.jb(14)).foregroundStyle(JB.ink)
                    .strikethrough(row.state == "done" && visual.kind == "shopping")
                if !row.detail.isEmpty {
                    Text(row.detail).font(.jb(12)).foregroundStyle(JB.ink3).fixedSize(horizontal: false, vertical: true)
                }
            }
            Spacer(minLength: 0)
            if !row.state.isEmpty && !["shopping", "plan"].contains(visual.kind) {
                JBChip(text: row.state.replacingOccurrences(of: "_", with: " "))
            }
        }
        .fixedSize(horizontal: false, vertical: true)
    }
}
