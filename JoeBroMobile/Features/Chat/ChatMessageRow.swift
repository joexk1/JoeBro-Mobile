import SwiftUI

/// One transcript message. Kept as its own view so the transcript's body stays
/// small (this project has already hit "unable to type-check this expression in
/// reasonable time") and so streaming updates only re-render one row.
struct ChatMessageRow: View {
    let line: ChatLine
    var onOpenDocument: (ChatDocumentRef) -> Void

    private var isUser: Bool { line.role == "user" }

    var body: some View {
        HStack(spacing: 0) {
            if isUser { Spacer(minLength: 44) }
            bubble
            if !isUser { Spacer(minLength: 32) }
        }
    }

    private var bubble: some View {
        VStack(alignment: .leading, spacing: 10) {
            if !line.thinking.isEmpty { thinkingBlock }
            if !line.toolCalls.isEmpty || !line.tools.isEmpty {
                ChatToolActivity(calls: line.toolCalls, legacyNames: line.tools)
            }
            ForEach(line.visualizations.filter(\.isResult)) { visual in ChatVisualizationView(visual: visual) }
            messageBody
            ForEach(line.documents) { document in documentChip(document) }
            attachmentChips
            if line.streaming && line.text.isEmpty && line.toolCalls.isEmpty { typingIndicator }
        }
        .padding(.horizontal, 15)
        .padding(.vertical, 13)
        .background(bubbleFill, in: RoundedRectangle(cornerRadius: 20, style: .continuous))
        .overlay(RoundedRectangle(cornerRadius: 20, style: .continuous)
            .strokeBorder(.joeInk.opacity(isUser ? 0.22 : 0.13), lineWidth: 1))
    }

    // The user speaks in a tinted bubble, JoeBro in plain glass — the clearest
    // distinction that still reads as one material.
    private var bubbleFill: Color {
        isUser ? Color.accentTint.opacity(0.22) : Color.joeInk.opacity(0.07)
    }

    @ViewBuilder
    private var messageBody: some View {
        if !line.text.isEmpty {
            if isUser {
                Text(line.text)
                    .font(.body)
                    .foregroundStyle(.joeInk)
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
        DisclosureGroup {
            Text(line.thinking)
                .font(.footnote)
                .foregroundStyle(.joeInk.opacity(0.75))
                .lineSpacing(2)
                .textSelection(.enabled)
                .frame(maxWidth: .infinity, alignment: .leading)
                .padding(.top, 6)
        } label: {
            Label("Thinking", systemImage: "sparkles")
                .font(.caption.weight(.semibold))
                .foregroundStyle(.joeInk.opacity(0.8))
        }
        .tint(.accentTint)
    }

    @ViewBuilder
    private var attachmentChips: some View {
        ForEach(line.attachments, id: \.self) { name in
            Label(name, systemImage: "paperclip")
                .font(.caption)
                .foregroundStyle(.joeInk.opacity(0.7))
                .lineLimit(1)
        }
    }

    private func documentChip(_ document: ChatDocumentRef) -> some View {
        Button { onOpenDocument(document) } label: {
            HStack(spacing: 10) {
                Image(systemName: "doc.text.fill").foregroundStyle(.accentTint)
                Text(document.title).font(.subheadline.weight(.semibold)).foregroundStyle(.joeInk).lineLimit(1)
                Spacer(minLength: 4)
                Image(systemName: "chevron.right").font(.caption2.bold()).foregroundStyle(.joeInk.opacity(0.5))
            }
            .padding(.horizontal, 12)
            .frame(minHeight: 44)
            .background(.joeInk.opacity(0.1), in: RoundedRectangle(cornerRadius: 12, style: .continuous))
            .contentShape(Rectangle())
        }
        .buttonStyle(.plain)
        .accessibilityLabel("Open document \(document.title)")
    }

    private var typingIndicator: some View {
        HStack(spacing: 7) {
            ProgressView().controlSize(.small).tint(.accentTint)
            Text("JoeBro is replying…").font(.caption).foregroundStyle(.secondary)
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
        case "calendar", "reminders": return .orange
        case "weather": return .cyan
        case "shopping", "health": return .mint
        case "memory", "research": return .purple
        case "agents", "tasks", "plan": return .blue
        default: return .accentTint
        }
    }
    private var symbol: String {
        switch visual.kind {
        case "calendar": return "calendar"
        case "weather": return "cloud.sun.fill"
        case "shopping": return "basket.fill"
        case "reminders": return "bell.badge.fill"
        case "memory": return "brain.head.profile"
        case "agents": return "terminal.fill"
        case "tasks", "plan": return "checklist"
        case "health": return "heart.fill"
        case "research": return "sparkle.magnifyingglass"
        case "email": return "envelope.fill"
        default: return "square.grid.2x2.fill"
        }
    }
    private var visibleRows: [ChatVisualization.Row] {
        showAll ? visual.rows : Array(visual.rows.prefix(5))
    }

    var body: some View {
        VStack(alignment: .leading, spacing: 14) {
            HStack(alignment: .top, spacing: 10) {
                Image(systemName: symbol)
                    .font(.system(size: 18, weight: .medium))
                    .foregroundStyle(tint)
                    .frame(width: 36, height: 36)
                    .background(tint.opacity(0.12), in: RoundedRectangle(cornerRadius: 11))
                VStack(alignment: .leading, spacing: 3) {
                    Text(visual.title).font(.subheadline.weight(.semibold)).foregroundStyle(.joeInk)
                    if !visual.subtitle.isEmpty {
                        Text(visual.subtitle).font(.caption).foregroundStyle(.secondary).fixedSize(horizontal: false, vertical: true)
                    }
                }
                Spacer(minLength: 0)
            }
            if !visual.metrics.isEmpty { metricStrip }
            if visual.series.count > 1 { trendLine }
            VStack(spacing: 0) {
                ForEach(Array(visibleRows.enumerated()), id: \.offset) { index, row in
                    rowView(row)
                    if index < visibleRows.count - 1 { Divider().overlay(tint.opacity(0.1)).padding(.vertical, 9) }
                }
            }
            if visual.rows.count > 5 {
                Button(showAll ? "Show less" : "Show all \(visual.rows.count)") { showAll.toggle() }
                    .font(.caption.weight(.semibold)).foregroundStyle(tint)
            }
        }
        .padding(14)
        .frame(maxWidth: .infinity, alignment: .leading)
        .background(tint.opacity(0.06), in: RoundedRectangle(cornerRadius: 17))
        .overlay(RoundedRectangle(cornerRadius: 17).strokeBorder(tint.opacity(0.24), lineWidth: 1))
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
            Text(metric.value).font(.system(size: 25, weight: .medium, design: .rounded)).monospacedDigit().foregroundStyle(.joeInk)
            Text(metric.label).font(.caption2).foregroundStyle(.secondary)
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
            .font(.caption2).foregroundStyle(.secondary)
        }
        .accessibilityLabel(visual.title + " trend: " + visual.series.map { "\($0.label), \($0.value.formatted())" }.joined(separator: "; "))
    }

    private func rowView(_ row: ChatVisualization.Row) -> some View {
        HStack(alignment: .top, spacing: 9) {
            if visual.kind == "shopping" || visual.kind == "plan" {
                Image(systemName: row.state == "done" ? "checkmark.circle.fill" : "circle")
                    .foregroundStyle(row.state == "done" ? tint : Color.secondary)
                    .font(.subheadline).padding(.top, 2)
            } else {
                RoundedRectangle(cornerRadius: 2).fill(tint.opacity(0.65)).frame(width: 3)
            }
            VStack(alignment: .leading, spacing: 3) {
                Text(row.title).font(.subheadline).foregroundStyle(.joeInk)
                    .strikethrough(row.state == "done" && visual.kind == "shopping")
                if !row.detail.isEmpty {
                    Text(row.detail).font(.caption).foregroundStyle(.secondary).fixedSize(horizontal: false, vertical: true)
                }
            }
            Spacer(minLength: 0)
            if !row.state.isEmpty && !["shopping", "plan"].contains(visual.kind) {
                Text(row.state.replacingOccurrences(of: "_", with: " ").capitalized)
                    .font(.system(size: 10, weight: .semibold)).foregroundStyle(tint)
                    .padding(.horizontal, 7).padding(.vertical, 4)
                    .background(tint.opacity(0.1), in: Capsule())
            }
        }
        .fixedSize(horizontal: false, vertical: true)
    }
}
