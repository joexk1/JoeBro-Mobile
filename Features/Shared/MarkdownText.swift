import SwiftUI

/// Renders markdown the way the Mac app's MarkdownText does: block-level
/// structure parsed by hand (headings, fences, lists, quotes, rules) with
/// inline spans left to AttributedString, which handles bold/italic/code/links.
///
/// Deliberately not a full CommonMark implementation — it covers what a model
/// actually emits in chat and in documents.
struct MarkdownText: View {
    let text: String
    var textColor: Color = JB.ink

    var body: some View {
        VStack(alignment: .leading, spacing: 10) {
            ForEach(Array(MarkdownBlock.parse(text).enumerated()), id: \.offset) { pair in
                block(pair.element)
            }
        }
        .frame(maxWidth: .infinity, alignment: .leading)
    }

    @ViewBuilder
    private func block(_ block: MarkdownBlock) -> some View {
        switch block {
        case .heading(let level, let content):
            inline(content)
                .font(.jb([26, 22, 19, 17, 16, 15][min(level - 1, 5)], level <= 2 ? .bold : .semibold))
                .padding(.top, level <= 2 ? 6 : 2)

        case .paragraph(let content):
            inline(content)

        case .bullet(let items):
            VStack(alignment: .leading, spacing: 6) {
                ForEach(Array(items.enumerated()), id: \.offset) { pair in
                    HStack(alignment: .firstTextBaseline, spacing: 8) {
                        Text("•").foregroundStyle(JB.ink3)
                        inline(pair.element)
                    }
                }
            }

        case .numbered(let items):
            VStack(alignment: .leading, spacing: 6) {
                ForEach(Array(items.enumerated()), id: \.offset) { pair in
                    HStack(alignment: .firstTextBaseline, spacing: 8) {
                        Text("\(pair.offset + 1).")
                            .font(.jbMono(13))
                            .foregroundStyle(JB.ink3)
                        inline(pair.element)
                    }
                }
            }

        case .quote(let content):
            HStack(alignment: .top, spacing: 10) {
                Rectangle().fill(JB.lineStrong).frame(width: 2)
                inline(content).foregroundStyle(JB.ink2)
            }

        case .code(let language, let content):
            VStack(alignment: .leading, spacing: 4) {
                if !language.isEmpty {
                    Text(language).font(.jbMono(10.5)).foregroundStyle(JB.ink3)
                }
                ScrollView(.horizontal) {
                    Text(content)
                        .font(.jbMono(.footnote))
                        .textSelection(.enabled)
                        .padding(10)
                }
                .scrollIndicators(.hidden)
                .background(JB.raised, in: RoundedRectangle(cornerRadius: JB.rCard))
                .overlay(RoundedRectangle(cornerRadius: JB.rCard).strokeBorder(JB.line))
            }

        case .image(let description, let address):
            if let url = URL(string: address) {
                AsyncImage(url: url) { image in
                    image.resizable().scaledToFit()
                        .clipShape(RoundedRectangle(cornerRadius: 12))
                } placeholder: {
                    JBSpinner().frame(maxWidth: .infinity, minHeight: 100)
                }
                .accessibilityLabel(description.isEmpty ? "Report image" : description)
            }

        case .rule:
            Rectangle().fill(JB.line).frame(height: 1)
        }
    }

    private func inline(_ raw: String) -> Text {
        // Inline emphasis, code spans and links are AttributedString's job.
        if let attributed = try? AttributedString(
            markdown: raw,
            options: .init(interpretedSyntax: .inlineOnlyPreservingWhitespace)) {
            return Text(attributed)
        }
        return Text(raw)
    }
}

enum MarkdownBlock {
    case heading(level: Int, text: String)
    case paragraph(String)
    case bullet([String])
    case numbered([String])
    case quote(String)
    case code(language: String, text: String)
    case image(description: String, url: String)
    case rule

    static func parse(_ source: String) -> [MarkdownBlock] {
        var blocks: [MarkdownBlock] = []
        var paragraph: [String] = []
        var bullets: [String] = []
        var numbers: [String] = []
        var quote: [String] = []

        func flushParagraph() {
            if !paragraph.isEmpty { blocks.append(.paragraph(paragraph.joined(separator: " "))); paragraph = [] }
        }
        func flushLists() {
            if !bullets.isEmpty { blocks.append(.bullet(bullets)); bullets = [] }
            if !numbers.isEmpty { blocks.append(.numbered(numbers)); numbers = [] }
            if !quote.isEmpty { blocks.append(.quote(quote.joined(separator: " "))); quote = [] }
        }
        func flushAll() { flushParagraph(); flushLists() }

        var lines = source.components(separatedBy: .newlines)[...]
        while let line = lines.first {
            lines = lines.dropFirst()
            let trimmed = line.trimmingCharacters(in: .whitespaces)

            // Fenced code runs to the closing fence, or to the end if the
            // model is still streaming and hasn't closed it yet.
            if trimmed.hasPrefix("```") {
                flushAll()
                let language = String(trimmed.dropFirst(3)).trimmingCharacters(in: .whitespaces)
                var body: [String] = []
                while let next = lines.first {
                    lines = lines.dropFirst()
                    if next.trimmingCharacters(in: .whitespaces).hasPrefix("```") { break }
                    body.append(next)
                }
                blocks.append(.code(language: language, text: body.joined(separator: "\n")))
                continue
            }

            if trimmed.isEmpty { flushAll(); continue }

            if trimmed.hasPrefix("!["), let split = trimmed.range(of: "]("),
               trimmed.hasSuffix(")") {
                flushAll()
                blocks.append(.image(
                    description: String(trimmed[trimmed.index(trimmed.startIndex, offsetBy: 2)..<split.lowerBound]),
                    url: String(trimmed[split.upperBound..<trimmed.index(before: trimmed.endIndex)])))
                continue
            }

            if trimmed == "---" || trimmed == "***" || trimmed == "___" {
                flushAll(); blocks.append(.rule); continue
            }

            if trimmed.hasPrefix("#") {
                let hashes = trimmed.prefix(while: { $0 == "#" }).count
                if hashes <= 6, trimmed.dropFirst(hashes).hasPrefix(" ") {
                    flushAll()
                    blocks.append(.heading(level: hashes,
                                           text: String(trimmed.dropFirst(hashes + 1))))
                    continue
                }
            }

            if trimmed.hasPrefix("> ") {
                flushParagraph()
                quote.append(String(trimmed.dropFirst(2)))
                continue
            }

            if let marker = ["- ", "* ", "+ "].first(where: { trimmed.hasPrefix($0) }) {
                flushParagraph()
                bullets.append(String(trimmed.dropFirst(marker.count)))
                continue
            }

            if let dot = trimmed.firstIndex(of: "."),
               Int(trimmed[trimmed.startIndex..<dot]) != nil,
               trimmed[dot...].hasPrefix(". ") {
                flushParagraph()
                numbers.append(String(trimmed[trimmed.index(dot, offsetBy: 2)...]))
                continue
            }

            flushLists()
            paragraph.append(trimmed)
        }
        flushAll()
        return blocks
    }
}
