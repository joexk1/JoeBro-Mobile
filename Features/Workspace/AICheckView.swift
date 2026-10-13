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
                    Label(error, systemImage: "exclamationmark.triangle")
                        .font(.subheadline).foregroundStyle(.orange)
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
            .foregroundStyle(.white)
            .scrollContentBackground(.hidden)
            .padding(10)
            .jbGlass(16)
            .overlay(alignment: .topLeading) {
                if text.isEmpty {
                    Text("Paste at least 20 words to score")
                        .foregroundStyle(.secondary)
                        .padding(18)
                        .allowsHitTesting(false)
                }
            }
            .overlay(alignment: .bottomTrailing) {
                Text("\(wordCount) words")
                    .font(.caption2)
                    .foregroundStyle(wordCount < 20 ? .orange : .secondary)
                    .padding(12)
                    .allowsHitTesting(false)
            }
    }

    private var checkButton: some View {
        Button {
            Task { await check() }
        } label: {
            Group {
                if checking { ProgressView().controlSize(.small) }
                else { Text("Check") }
            }
            .frame(maxWidth: .infinity, minHeight: 28)
        }
        .buttonStyle(.borderedProminent)
        .tint(Color.accentTint)
        .foregroundStyle(.black)
        .disabled(wordCount < 20 || checking)
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
            Text("\(Int(result.aiPercent.rounded()))% likely AI")
                .font(.system(size: 32, weight: .bold, design: .rounded))
                .foregroundStyle(tint)
            ProgressView(value: min(1, max(0, result.aiPercent / 100)))
                .tint(tint)
            Text("\(result.aiWords) of \(result.totalWords) words"
                 + (result.provider.map { " · \($0)" } ?? ""))
                .font(.caption).foregroundStyle(.secondary)
            if !result.flaggedSentences.isEmpty {
                Divider().overlay(.white.opacity(0.2))
                Text("Flagged sentences").font(.subheadline.weight(.semibold)).foregroundStyle(.white)
                ForEach(result.flaggedSentences.indices, id: \.self) { index in
                    Text(result.flaggedSentences[index])
                        .font(.footnote).foregroundStyle(.secondary)
                        .frame(maxWidth: .infinity, alignment: .leading)
                }
            }
        }
        .frame(maxWidth: .infinity, alignment: .leading)
        .padding(16)
        .jbGlass(20)
    }

    private var tint: Color {
        switch result.aiPercent {
        case ..<30: .green
        case ..<70: .yellow
        default: .orange
        }
    }
}
