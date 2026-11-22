import SwiftUI

/// A composer command. Built-ins act on the store; skills insert their name
/// so the agent picks the skill up from the message.
struct SlashCommand: Identifiable, Equatable {
    enum Kind: Equatable { case compact, clear, agent, chat, think, fast, web, skill }
    let kind: Kind
    let name: String
    let label: String
    var id: String { name }
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
                SlashCommand(kind: .fast, name: "/fast", label: "Answer quickly")]
        all += skills
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
            ForEach(Array(items.prefix(6).enumerated()), id: \.element.id) { index, cmd in
                Button { onPick(cmd) } label: {
                    HStack(spacing: 10) {
                        Text(cmd.name).font(.jbMono(13, .medium)).foregroundStyle(JB.ink)
                        Text(cmd.label).font(.jb(13)).foregroundStyle(JB.ink3).lineLimit(1)
                        Spacer(minLength: 0)
                    }
                    .padding(.horizontal, 12)
                    .frame(minHeight: 40)
                    .contentShape(Rectangle())
                }
                .buttonStyle(JBPressStyle())
                if index < min(items.count, 6) - 1 { Rectangle().fill(JB.line).frame(height: 1) }
            }
        }
        .jbFloating()
        .transition(.move(edge: .bottom).combined(with: .opacity))
    }
}
