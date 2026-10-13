import SwiftUI

/// A prominent tool-call card, ported from the Mac app's `ToolRowView`.
///
/// Tool calls used to be a one-line grey label that was easy to miss. This
/// gives each one a card with the tool's own symbol, an uppercase name, a live
/// state (running → done → failed), a one-line command preview when collapsed
/// and expandable command/output panes. Failures read unmistakably red.
struct ChatToolCallCard: View {
    let call: ChatToolCall
    @State private var expanded = false

    private var failed: Bool {
        guard let code = call.exitCode else { return false }
        return code != 0
    }

    private var accent: Color {
        if failed { return Color(red: 1, green: 0.42, blue: 0.42) }
        if !call.finished { return Color.cyan }
        return Color.mint
    }

    var body: some View {
        VStack(alignment: .leading, spacing: 0) {
            header
            if expanded { details }
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
                    Text(ChatToolCallCard.prettyName(call.name).uppercased())
                        .font(.system(size: 11, weight: .bold, design: .rounded))
                        .tracking(0.7)
                        .foregroundStyle(.white)
                        .lineLimit(1)
                    stateLine
                }
                Spacer(minLength: 6)
                Image(systemName: "chevron.right")
                    .font(.caption2.bold())
                    .foregroundStyle(.white.opacity(0.5))
                    .rotationEffect(.degrees(expanded ? 90 : 0))
            }
            .padding(.horizontal, 12)
            .padding(.vertical, 10)
            .frame(minHeight: 44)
            .contentShape(Rectangle())
        }
        .buttonStyle(.plain)
        .accessibilityLabel("\(ChatToolCallCard.prettyName(call.name)), \(stateText)")
        .accessibilityHint(expanded ? "Hide details" : "Show details")
    }

    private var stateText: String {
        if !call.finished { return "Running" }
        return failed ? "Failed" : "Done"
    }

    @ViewBuilder
    private var stateLine: some View {
        HStack(spacing: 6) {
            if call.finished {
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
                    .foregroundStyle(.white.opacity(0.45))
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
                        .foregroundStyle(failed ? accent : .white.opacity(0.88))
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
            .foregroundStyle(.white.opacity(0.9))
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
        case "read", "read_file": return "doc.text.magnifyingglass"
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
