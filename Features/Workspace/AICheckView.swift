import SwiftUI

/// Scores pasted text for how much of it reads as AI-written.
struct AICheckView: View {
    let ws: WorkspaceAPI

    @State private var text = ""
    @State private var result: WSAICheck?
    @State private var checking = false
    @State private var error: String?

    private var wordCount: Int { text.split(whereSeparator: { $0.isWhitespace }).count }

    var body: some View {
        ScrollView {
            VStack(alignment: .leading, spacing: 16) {
                editor
                checkButton
                if let error {
                    Text(error)
                        .font(.jb(12)).foregroundStyle(JB.warn)
                        .frame(maxWidth: .infinity, alignment: .leading)
                }
                if let result { ScoreCard(result: result) }
            }
            .frame(maxWidth: 760)
            .frame(maxWidth: .infinity)
            .padding(16)
        }
        .scrollIndicators(.hidden)
        .jbWallpaper()
        .navigationTitle("AI Check")
    }

    private var editor: some View {
        TextEditor(text: $text)
            .frame(minHeight: 200)
            .foregroundStyle(JB.ink)
            .font(.jb(15))
            .scrollContentBackground(.hidden)
            .padding(10)
            .jbSurface(.panel, radius: JB.rCard)
            .overlay(alignment: .topLeading) {
                if text.isEmpty {
                    Text("Paste at least 20 words to score")
                        .foregroundStyle(JB.ink2)
                        .padding(18)
                        .allowsHitTesting(false)
                }
            }
            .overlay(alignment: .bottomTrailing) {
                Text("\(wordCount) words")
                    .font(.jb(11))
                    .foregroundStyle(wordCount < 20 ? JB.warn : JB.ink3)
                    .padding(12)
                    .allowsHitTesting(false)
            }
    }

    private var checkButton: some View {
        Button {
            Task { await check() }
        } label: {
            Group {
                if checking { JBSpinner(tint: JB.onAccent) }
                else { Text("Check") }
            }
            .frame(maxWidth: .infinity, minHeight: 28)
        }
        .buttonStyle(.jbPrimary)
        .disabled(wordCount < 20 || checking)
        .sensoryFeedback(.success, trigger: result?.aiPercent)
    }

    private func check() async {
        guard !checking else { return }
        checking = true
        result = nil
        error = nil
        defer { checking = false }
        do { result = try await ws.aiCheck(text: text) }
        catch { self.error = error.localizedDescription }
    }
}

private struct ScoreCard: View {
    let result: WSAICheck

    var body: some View {
        VStack(alignment: .leading, spacing: 12) {
            Text("\(Int(result.aiPercent.rounded()))%")
                .font(.jb(34, .medium))
                .foregroundStyle(tint)
            ProgressView(value: min(1, max(0, result.aiPercent / 100)))
                .tint(tint)
            Text("\(result.aiWords) of \(result.totalWords) words"
                 + (result.provider.map { " · \($0)" } ?? ""))
                .font(.jb(11)).foregroundStyle(JB.ink3)
            if !result.flaggedSentences.isEmpty {
                Divider().overlay(JB.line)
                JBSectionHeader("Flagged", count: result.flaggedSentences.count)
                ForEach(result.flaggedSentences.indices, id: \.self) { index in
                    Text(result.flaggedSentences[index])
                        .font(.jbFootnote).foregroundStyle(JB.ink2)
                        .frame(maxWidth: .infinity, alignment: .leading)
                }
            }
        }
        .frame(maxWidth: .infinity, alignment: .leading)
        .padding(16)
        .jbSurface(.panel, radius: JB.rCard)
    }

    private var tint: Color {
        switch result.aiPercent {
        case ..<30: JB.live
        case ..<70: JB.warn
        default: JB.danger
        }
    }
}
