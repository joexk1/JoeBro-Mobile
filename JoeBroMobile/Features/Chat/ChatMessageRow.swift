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
            ForEach(line.toolCalls) { call in ChatToolCallCard(call: call) }
            legacyTools
            messageBody
            ForEach(line.documents) { document in documentChip(document) }
            attachmentChips
            if line.streaming && line.text.isEmpty && line.toolCalls.isEmpty { typingIndicator }
        }
        .padding(.horizontal, 15)
        .padding(.vertical, 13)
        .background(bubbleFill, in: RoundedRectangle(cornerRadius: 20, style: .continuous))
        .overlay(RoundedRectangle(cornerRadius: 20, style: .continuous)
            .strokeBorder(.white.opacity(isUser ? 0.22 : 0.13), lineWidth: 1))
    }

    // The user speaks in a tinted bubble, JoeBro in plain glass — the clearest
    // distinction that still reads as one material.
    private var bubbleFill: Color {
        isUser ? Color.accentTint.opacity(0.22) : Color.white.opacity(0.07)
    }

    @ViewBuilder
    private var messageBody: some View {
        if !line.text.isEmpty {
            if isUser {
                Text(line.text)
                    .font(.body)
                    .foregroundStyle(.white)
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
                .foregroundStyle(.white.opacity(0.75))
                .lineSpacing(2)
                .textSelection(.enabled)
                .frame(maxWidth: .infinity, alignment: .leading)
                .padding(.top, 6)
        } label: {
            Label("Thinking", systemImage: "sparkles")
                .font(.caption.weight(.semibold))
                .foregroundStyle(.white.opacity(0.8))
        }
        .tint(.accentTint)
    }

    @ViewBuilder
    private var legacyTools: some View {
        if line.toolCalls.isEmpty {
            ForEach(line.tools.indices, id: \.self) { index in
                ChatToolCallCard(call: ChatToolCall(name: line.tools[index], finished: true))
            }
        }
    }

    @ViewBuilder
    private var attachmentChips: some View {
        ForEach(line.attachments, id: \.self) { name in
            Label(name, systemImage: "paperclip")
                .font(.caption)
                .foregroundStyle(.white.opacity(0.7))
                .lineLimit(1)
        }
    }

    private func documentChip(_ document: ChatDocumentRef) -> some View {
        Button { onOpenDocument(document) } label: {
            HStack(spacing: 10) {
                Image(systemName: "doc.text.fill").foregroundStyle(.accentTint)
                Text(document.title).font(.subheadline.weight(.semibold)).foregroundStyle(.white).lineLimit(1)
                Spacer(minLength: 4)
                Image(systemName: "chevron.right").font(.caption2.bold()).foregroundStyle(.white.opacity(0.5))
            }
            .padding(.horizontal, 12)
            .frame(minHeight: 44)
            .background(.white.opacity(0.1), in: RoundedRectangle(cornerRadius: 12, style: .continuous))
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
