import SwiftUI

/// A composer command. Built-ins act on the store; skills insert their name
/// so the agent picks the skill up from the message.
struct SlashCommand: Identifiable, Equatable {
    enum Kind: Equatable { case compact, clear, agent, chat, think, fast, web, skill, menu, option }
    let kind: Kind
    let name: String
    let label: String
    var parent = ""
    var value = ""
    var current = false
    var id: String { parent + name }

    /// Choices for a menu command (banner, palette, panels), current one marked.
    static func options(for menu: String) -> [SlashCommand] {
        let look = JBAppearance.shared
        switch menu {
        case "banner":
            let cur = UserDefaults.standard.string(forKey: "backgroundAnimation") ?? BackgroundAnimation.off.rawValue
            return BackgroundAnimation.allCases.map {
                SlashCommand(kind: .option, name: $0.rawValue, label: $0 == .off ? "Off" : $0.label,
                             parent: menu, value: $0.rawValue, current: cur == $0.rawValue)
            }
        case "palette":
            return JBPalette.allCases.map {
                SlashCommand(kind: .option, name: $0.rawValue, label: $0.label, parent: menu, value: $0.rawValue, current: look.palette == $0)
            }
        case "panels":
            return [40, 60, 80, 100].map { v in
                SlashCommand(kind: .option, name: "\(v)", label: v == 100 ? "Solid" : "\(v)% opaque", parent: menu,
                             value: "\(v)", current: abs(look.solidity * 100 - Double(v)) < 5)
            }
        default: return []
        }
    }
}

@MainActor
@Observable final class SlashCommandSource {
    private struct Skill: Decodable { let name: String; let description: String?; let status: String? }
    private struct Envelope: Decodable { let skills: [Skill] }
    private(set) var skills: [SlashCommand] = []
    private var loaded = false

    func loadSkills(api: JoeBroAPI) async {
        guard !loaded, let env = try? await api.fetch(Envelope.self, "/api/skills") else { return }
        loaded = true
        skills = env.skills.filter { $0.status != "disabled" }.map {
            let slug = $0.name.lowercased().replacingOccurrences(of: " ", with: "-")
            return SlashCommand(kind: .skill, name: "/" + slug, label: $0.description.map { String($0.prefix(48)) } ?? $0.name)
        }
    }

    func commands(main: Bool, query: String) -> [SlashCommand] {
        var all: [SlashCommand] = []
        if main {
            all += [SlashCommand(kind: .compact, name: "/compact", label: "Shrink this conversation"),
                    SlashCommand(kind: .clear, name: "/clear", label: "Start fresh")]
        } else {
            all += [SlashCommand(kind: .agent, name: "/agent", label: "Agent mode"),
                    SlashCommand(kind: .chat, name: "/chat", label: "Chat mode"),
                    SlashCommand(kind: .web, name: "/web", label: "Toggle web search")]
        }
        all += [SlashCommand(kind: .think, name: "/think", label: "Reason first"),
                SlashCommand(kind: .fast, name: "/fast", label: "Answer quickly"),
                SlashCommand(kind: .menu, name: "/banner", label: "Banner animation"),
                SlashCommand(kind: .menu, name: "/palette", label: "Accent colour"),
                SlashCommand(kind: .menu, name: "/panels", label: "Panel opacity")]
        all += skills
        let parts = query.split(separator: " ", maxSplits: 1, omittingEmptySubsequences: false)
        if parts.count == 2 {
            let opts = SlashCommand.options(for: String(parts[0]).lowercased())
            let q = String(parts[1]).lowercased()
            return q.isEmpty ? opts : opts.filter { ($0.name + " " + $0.label).lowercased().contains(q) }
        }
        let q = query.lowercased()
        return q.isEmpty ? all : all.filter { $0.name.dropFirst().hasPrefix(q) || $0.name.contains(q) }
    }
}

/// Floating list above the composer, tap to accept.
struct SlashSuggestions: View {
    let items: [SlashCommand]
    var onPick: (SlashCommand) -> Void

    var body: some View {
        VStack(spacing: 0) {
            ForEach(Array(items.prefix(8).enumerated()), id: \.element.id) { index, cmd in
                Button { onPick(cmd) } label: {
                    HStack(spacing: 10) {
                        if cmd.kind == .option {
                            Text(cmd.label).font(.jb(15, .medium)).foregroundStyle(JB.ink)
                        } else {
                            Text(cmd.name).font(.jb(13, .medium)).foregroundStyle(JB.ink)
                            Text(cmd.label).font(.jb(13)).foregroundStyle(JB.ink3).lineLimit(1)
                        }
                        Spacer(minLength: 0)
                        if cmd.current { Image(systemName: "checkmark").font(.jb(12, .semibold)).foregroundStyle(JB.accent) }
                        if cmd.kind == .menu { Image(systemName: "chevron.right").font(.jb(11, .semibold)).foregroundStyle(JB.ink3) }
                    }
                    .padding(.horizontal, 12)
                    .frame(minHeight: 40)
                    .contentShape(Rectangle())
                }
                .buttonStyle(JBPressStyle())
                if index < min(items.count, 8) - 1 { Rectangle().fill(JB.line).frame(height: 1) }
            }
        }
        .jbFloating()
        .transition(.move(edge: .bottom).combined(with: .opacity))
    }
}
