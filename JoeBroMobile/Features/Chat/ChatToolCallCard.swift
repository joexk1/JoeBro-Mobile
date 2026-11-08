import SwiftUI

/// A prominent tool-call card, ported from the Mac app's `ToolRowView`.
///
/// Tool calls used to be a one-line grey label that was easy to miss. This
/// gives each one a card with the tool's own symbol, an uppercase name, a live
/// state (running → done → failed), a one-line command preview when collapsed
/// and expandable command/output panes. Failures read unmistakably red.
struct ChatToolCallCard: View {
    let call: ChatToolCall
    var groupedCalls: [ChatToolCall] = []
    private var calls: [ChatToolCall] { groupedCalls.isEmpty ? [call] : groupedCalls }
    private var finished: Bool { calls.allSatisfy(\.finished) }
    private var label: String { Self.prettyName(call.name) + (calls.count > 1 ? " (\(calls.count))" : "") }
    @State private var expanded = false

    private var failed: Bool { calls.contains { ($0.exitCode ?? 0) != 0 } }

    private var accent: Color {
        if failed { return Color(red: 1, green: 0.42, blue: 0.42) }
        if !finished { return Color.cyan }
        return Color.mint
    }

    var body: some View {
        VStack(alignment: .leading, spacing: 0) {
            header
            if expanded {
                if calls.count > 1 {
                    VStack(spacing: 8) {
                        ForEach(calls) { item in ChatToolCallCard(call: item) }
                    }.padding(10)
                } else { details }
            }
        }
        .background(accent.opacity(failed ? 0.14 : 0.09), in: RoundedRectangle(cornerRadius: 14, style: .continuous))
        .overlay(RoundedRectangle(cornerRadius: 14, style: .continuous)
            .strokeBorder(accent.opacity(failed ? 0.65 : 0.3), lineWidth: failed ? 1.4 : 1))
    }

    private var header: some View {
        Button {
            withAnimation(.snappy(duration: 0.25)) { expanded.toggle() }
        } label: {
            HStack(spacing: 9) {
                Image(systemName: ChatToolCallCard.icon(for: call.name))
                    .font(.footnote.weight(.semibold))
                    .foregroundStyle(accent)
                    .frame(width: 18)
                VStack(alignment: .leading, spacing: 3) {
                    Text(label.uppercased())
                        .font(.system(size: 11, weight: .bold, design: .rounded))
                        .tracking(0.7)
                        .foregroundStyle(.joeInk)
                        .lineLimit(1)
                    stateLine
                }
                Spacer(minLength: 6)
                Image(systemName: "chevron.right")
                    .font(.caption2.bold())
                    .foregroundStyle(.joeInk.opacity(0.5))
                    .rotationEffect(.degrees(expanded ? 90 : 0))
            }
            .padding(.horizontal, 12)
            .padding(.vertical, 10)
            .frame(minHeight: 44)
            .contentShape(Rectangle())
        }
        .buttonStyle(.plain)
        .accessibilityLabel("\(label), \(stateText)")
        .accessibilityHint(expanded ? "Hide details" : "Show details")
    }

    private var stateText: String {
        if !finished { return "Running" }
        return failed ? "Failed" : "Done"
    }

    @ViewBuilder
    private var stateLine: some View {
        HStack(spacing: 6) {
            if finished {
                Image(systemName: failed ? "exclamationmark.octagon.fill" : "checkmark.circle.fill")
                    .font(.system(size: 9))
                    .foregroundStyle(accent)
            } else {
                ProgressView().controlSize(.mini).tint(accent)
            }
            Text(stateText)
                .font(.caption2.weight(failed ? .bold : .regular))
                .foregroundStyle(failed ? accent : .secondary)
            if !expanded, !call.command.isEmpty {
                Text(call.command)
                    .font(.system(size: 10.5, design: .monospaced))
                    .foregroundStyle(.joeInk.opacity(0.45))
                    .lineLimit(1)
            }
        }
    }

    private var details: some View {
        VStack(alignment: .leading, spacing: 8) {
            if !call.command.isEmpty {
                pane(call.command, opacity: 0.22)
            }
            if !call.output.isEmpty {
                ScrollView {
                    Text(ChatToolCallCard.clamp(call.output))
                        .font(.system(size: 11.5, design: .monospaced))
                        .foregroundStyle(failed ? accent : .joeInk.opacity(0.88))
                        .textSelection(.enabled)
                        .frame(maxWidth: .infinity, alignment: .leading)
                        .padding(9)
                }
                .frame(maxHeight: 240)
                .background(.black.opacity(0.16), in: RoundedRectangle(cornerRadius: 9))
            }
            if call.command.isEmpty && call.output.isEmpty {
                Text(call.finished ? "No output." : "Working…")
                    .font(.caption).foregroundStyle(.secondary)
            }
        }
        .padding(.horizontal, 12)
        .padding(.bottom, 11)
    }

    private func pane(_ text: String, opacity: Double) -> some View {
        Text(text)
            .font(.system(size: 11.5, design: .monospaced))
            .foregroundStyle(.joeInk.opacity(0.9))
            .textSelection(.enabled)
            .frame(maxWidth: .infinity, alignment: .leading)
            .padding(9)
            .background(.black.opacity(opacity), in: RoundedRectangle(cornerRadius: 9))
    }

    static func clamp(_ text: String) -> String {
        text.count > 4000 ? String(text.prefix(4000)) + "\n…" : text
    }

    /// Same symbol mapping as the Mac's ToolRowView, so a Bash call looks the
    /// same on both.
    static func icon(for name: String) -> String {
        switch name.lowercased() {
        case "bash", "terminal", "shell": return "apple.terminal"
        case "read", "read_file", "read_attachment": return "doc.text.magnifyingglass"
        case "write", "write_file", "update_document", "edit_document", "create_document": return "square.and.pencil"
        case "web_search", "search": return "magnifyingglass"
        case "generate_image": return "photo"
        case let tool where tool.contains("email"): return "envelope"
        case let tool where tool.contains("calendar") || tool.contains("note"): return "calendar"
        case let tool where tool.contains("memory"): return "brain.head.profile"
        case let tool where tool.contains("document"): return "doc.text"
        default: return "hammer"
        }
    }

    static func prettyName(_ raw: String) -> String {
        // MCP tools arrive as "server__tool"; show just the tool.
        var name = raw
        if raw.hasPrefix("mcp_"), let separator = raw.range(of: "__") {
            name = String(raw[separator.upperBound...])
        }
        let words = name.replacingOccurrences(of: "_", with: " ")
        return words.isEmpty ? "Tool" : words.capitalized
    }
}


/// One collapsed steps control per assistant turn, matching the PC widget.
struct ChatToolActivity: View {
    let calls: [ChatToolCall]
    var legacyNames: [String] = []
    @State private var expanded = false
    @Environment(\.accessibilityReduceMotion) private var reduceMotion
    private var count: Int { calls.isEmpty ? legacyNames.count : calls.count }
    private var running: Bool { calls.contains { !$0.finished } }
    private var failed: Bool { calls.contains { ($0.exitCode ?? 0) != 0 } }
    private var summary: String {
        if failed && !running { return "Finished with an issue" }
        return toolActivityText(calls.last(where: { !$0.finished })?.name ?? calls.last?.name ?? legacyNames.last ?? "", running: running)
    }
    private var groups: [[ChatToolCall]] {
        var rows: [[ChatToolCall]] = []
        for call in calls {
            if rows.last?.last?.name == call.name { rows[rows.count - 1].append(call) }
            else { rows.append([call]) }
        }
        return rows
    }
    var body: some View {
        VStack(alignment: .leading, spacing: 8) {
            Button {
                withAnimation(reduceMotion ? nil : .easeInOut(duration: 0.18)) { expanded.toggle() }
            } label: {
                HStack(spacing: 10) {
                    HStack(spacing: 6) {
                        if running { ProgressView().controlSize(.mini).tint(.joeInk) }
                        else { Image(systemName: failed ? "exclamationmark.circle" : "wrench.and.screwdriver").font(.caption2) }
                        Text("\(count) \(count == 1 ? "step" : "steps")").font(.caption.weight(.medium))
                        Image(systemName: "chevron.down").font(.system(size: 9, weight: .semibold))
                            .rotationEffect(.degrees(expanded ? 180 : 0))
                    }
                    .padding(.horizontal, 10).padding(.vertical, 6)
                    .background(.joeInk.opacity(expanded ? 0.12 : 0.06), in: Capsule())
                    Text(summary).font(.caption).foregroundStyle(.secondary).lineLimit(2)
                    Spacer(minLength: 0)
                }
                .foregroundStyle(.joeInk.opacity(0.8))
                .frame(maxWidth: .infinity, minHeight: 44, alignment: .leading)
                .contentShape(Rectangle())
            }
            .buttonStyle(.plain)
            .accessibilityLabel("\(summary), \(count) steps")
            .accessibilityValue(expanded ? "Expanded" : "Collapsed")
            .accessibilityHint(expanded ? "Hide tool calls" : "Show tool calls")
            if expanded {
                VStack(alignment: .leading, spacing: 9) {
                    ForEach(Array(groups.enumerated()), id: \.element.first!.id) { _, group in
                        ChatToolStep(calls: group)
                    }
                    if calls.isEmpty {
                        ForEach(legacyNames.indices, id: \.self) { index in
                            Label(ChatToolCallCard.prettyName(legacyNames[index]), systemImage: "checkmark")
                                .font(.caption).foregroundStyle(.secondary)
                        }
                    }
                }
                .padding(.leading, 10)
                .overlay(alignment: .leading) { Rectangle().fill(.joeInk.opacity(0.12)).frame(width: 1) }
            }
        }
    }
}

private struct ChatToolStep: View {
    let calls: [ChatToolCall]
    @State private var expanded = false
    private var failed: Bool { calls.contains { ($0.exitCode ?? 0) != 0 } }
    private var running: Bool { calls.contains { !$0.finished } }
    var body: some View {
        DisclosureGroup(isExpanded: $expanded) {
            ForEach(calls) { call in
                VStack(alignment: .leading, spacing: 6) {
                    if !call.command.isEmpty { Text(call.command).font(.system(.caption, design: .monospaced)).textSelection(.enabled) }
                    if !call.output.isEmpty {
                        ScrollView { Text(call.output).font(.system(.caption, design: .monospaced)).textSelection(.enabled).frame(maxWidth: .infinity, alignment: .leading) }
                            .frame(maxHeight: 220)
                    }
                    if call.command.isEmpty && call.output.isEmpty { Text(call.finished ? "No output" : "Running…").font(.caption).foregroundStyle(.secondary) }
                }.padding(.vertical, 6)
            }
        } label: {
            HStack(spacing: 8) {
                Image(systemName: running ? "ellipsis" : failed ? "xmark" : "checkmark")
                    .foregroundStyle(failed ? Color.red : Color.secondary)
                    .font(.caption2).frame(width: 12)
                Text(ChatToolCallCard.prettyName(calls[0].name) + (calls.count > 1 ? " (\(calls.count))" : ""))
                    .font(.caption.weight(.medium)).foregroundStyle(.joeInk)
                    .lineLimit(2)
            }.frame(minHeight: 32)
        }.tint(.joeInk.opacity(0.5))
    }
}

/// Human activity text beside the steps disclosure; never expose raw arguments.
private func toolActivityText(_ raw: String, running: Bool) -> String {
    let name = raw.components(separatedBy: "__").last!.lowercased()
    if name.contains("spotify") && name.contains("search") { return running ? "Searching Spotify" : "Searched Spotify" }
    if name.contains("email") || name.contains("mail") {
        if name.contains("send") || name.contains("reply") { return running ? "Sending email" : "Sent email" }
        return running ? "Reading email" : "Checked email"
    }
    if name.contains("weather") { return running ? "Checking the weather" : "Checked the weather" }
    if name.contains("plan") { return running ? "Updating the plan" : "Updated the plan" }
    if name.contains("reminder") { return running ? "Working with reminders" : "Checked reminders" }
    if name.contains("calendar") || name.contains("event") { return running ? "Working with the calendar" : "Checked the calendar" }
    if name.contains("memory") || name.hasPrefix("muse_") { return running ? "Working with memory" : "Finished memory steps" }
    if name.contains("read") || name.contains("inspect") { return running ? "Reading information" : "Read information" }
    if name.contains("search") || name.contains("find") { return running ? "Searching" : "Finished searching" }
    if name.contains("create") || name.contains("write") || name.contains("edit") { return running ? "Working on changes" : "Finished change steps" }
    if name.contains("agent") { return running ? "Working with agents" : "Checked agents" }
    if name == "bash" || name == "python" { return running ? "Running a command" : "Finished command steps" }
    return running ? "Working" : "Finished steps"
}
