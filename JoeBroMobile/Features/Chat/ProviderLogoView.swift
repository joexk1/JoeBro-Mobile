import SwiftUI

/// The same provider marks used by the Mac model picker, rendered as template
/// assets so they inherit the foreground colour of the control they sit in.
struct ProviderLogoView: View {
    let model: String
    var size: CGFloat = 14

    private static let logos: [(String, String)] = [
        ("openai|gpt-|^o[13]-|chatgpt|dall-e", "ProviderOpenAI"),
        ("anthropic|claude", "ProviderAnthropic"),
        ("google|gemini|gemma", "ProviderGoogle"),
        ("meta|llama(?![.\\-_ ]?cpp)", "ProviderMeta"),
        ("mistral", "ProviderMistral"),
        ("qwen|alibaba", "ProviderQwen"),
        ("deepseek", "ProviderDeepSeek"),
        ("x-ai|xai|grok", "ProviderXAI"),
        ("cohere|command-r", "ProviderCohere"),
        ("perplexity|sonar", "ProviderPerplexity"),
        ("nous|hermes", "ProviderNous"),
        ("microsoft|phi-", "ProviderMicrosoft"),
        ("zhipu|glm|chatglm", "ProviderZhipu"),
        ("minimax", "ProviderMiniMax"),
        ("kimi|moonshot", "ProviderKimi"),
        ("nvidia|nemotron", "ProviderNvidia")
    ]

    private var asset: String? {
        Self.logos.first { model.range(of: $0.0, options: [.regularExpression, .caseInsensitive]) != nil }?.1
    }

    var body: some View {
        Group {
            if model.localizedCaseInsensitiveContains("apple") {
                Image(systemName: "apple.logo").resizable().scaledToFit()
            } else if let asset {
                Image(asset).renderingMode(.template).resizable().scaledToFit()
            } else {
                Text(String(model.prefix(1)).uppercased())
                    .font(.system(size: size * 0.68, weight: .heavy, design: .rounded))
            }
        }
        .frame(width: size, height: size)
        .accessibilityHidden(true)
    }
}
