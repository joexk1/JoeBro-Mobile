import SwiftUI

enum ChatToolFormat {
    static func clamp(_ text: String) -> String {
        text.count > 4000 ? String(text.prefix(4000)) + "\n…" : text
    }

    static func prettyName(_ raw: String) -> String {
        // MCP tools arrive as "server__tool"; show just the tool.
        var name = raw
        if raw.hasPrefix("mcp_"), let separator = raw.range(of: "__") {
            name = String(raw[separator.upperBound...])
        }
        let words = name.replacingOccurrences(of: "_", with: " ")
        return words.isEmpty ? "tool" : words.lowercased()
    }
}

/// One collapsed line per assistant turn: status dot, what it is doing, step
/// count. Tap to list the steps; tap a step for its command and output.
struct ChatToolActivity: View {
    let calls: [ChatToolCall]
    var legacyNames: [String] = []
    @State private var expanded = false
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
        VStack(alignment: .leading, spacing: 4) {
            Button { withAnimation(JB.snap) { expanded.toggle() } } label: {
                HStack(spacing: 8) {
                    JBStatusDot(color: failed ? JB.danger : running ? JB.live : JB.ink3, live: running, size: 6)
                    Text(summary).font(.jbMono(12)).foregroundStyle(JB.ink2).lineLimit(1)
                    Text("\(count)").font(.jbMono(12)).foregroundStyle(JB.ink3)
                    Image(systemName: "chevron.right").font(.jb(9, .medium)).foregroundStyle(JB.ink3)
                        .rotationEffect(.degrees(expanded ? 90 : 0))
                    Spacer(minLength: 0)
                }
                .frame(minHeight: 36)
                .contentShape(Rectangle())
            }
            .buttonStyle(.plain)
            .accessibilityLabel("\(summary), \(count) steps")
            .accessibilityValue(expanded ? "Expanded" : "Collapsed")
            if expanded {
                VStack(alignment: .leading, spacing: 0) {
                    ForEach(groups, id: \.first!.id) { group in ChatToolStep(calls: group) }
                    if calls.isEmpty {
                        ForEach(legacyNames.indices, id: \.self) { index in
                            Text(ChatToolFormat.prettyName(legacyNames[index]))
                                .font(.jbMono(12)).foregroundStyle(JB.ink3).frame(minHeight: 28)
                        }
                    }
                }
                .padding(.leading, 10)
                .overlay(alignment: .leading) { Rectangle().fill(JB.line).frame(width: 1) }
                .transition(.opacity)
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
        VStack(alignment: .leading, spacing: 4) {
            Button { withAnimation(JB.snap) { expanded.toggle() } } label: {
                HStack(spacing: 8) {
                    JBStatusDot(color: failed ? JB.danger : running ? JB.live : JB.ink3, live: running, size: 5)
                    Text(ChatToolFormat.prettyName(calls[0].name) + (calls.count > 1 ? " ×\(calls.count)" : ""))
                        .font(.jbMono(12)).foregroundStyle(failed ? JB.danger : JB.ink2).lineLimit(1)
                    if !expanded, calls.count == 1, !calls[0].command.isEmpty {
                        Text(calls[0].command).font(.jbMono(11)).foregroundStyle(JB.ink3).lineLimit(1)
                    }
                    Spacer(minLength: 0)
                }
                .frame(minHeight: 32)
                .contentShape(Rectangle())
            }
            .buttonStyle(.plain)
            if expanded {
                ForEach(calls) { call in
                    VStack(alignment: .leading, spacing: 6) {
                        if !call.command.isEmpty { pane(call.command) }
                        if !call.output.isEmpty {
                            ScrollView { pane(ChatToolFormat.clamp(call.output), tint: failed ? JB.danger : JB.ink2) }
                                .frame(maxHeight: 220)
                        }
                    }
                }
            }
        }
        .padding(.leading, 4)
    }

    private func pane(_ text: String, tint: Color = JB.ink) -> some View {
        Text(text)
            .font(.jbMono(11.5)).foregroundStyle(tint)
            .textSelection(.enabled)
            .frame(maxWidth: .infinity, alignment: .leading)
            .padding(9)
            .background(JB.raised, in: RoundedRectangle(cornerRadius: JB.rControl))
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
