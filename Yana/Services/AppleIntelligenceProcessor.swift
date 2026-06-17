import Foundation

/// On-device AI post-processor. Parallel to `AIProcessor` but routes through the system
/// language model with chunk + map-reduce to fit the ~4096-token window. Off-main, `Sendable`,
/// no SwiftData. Model-unavailable → passthrough; per-article failure → drop.
struct AppleIntelligenceProcessor: AIProcessing {
    let generator: ArticleGenerating
    let temperature: Double
    let maxTokens: Int

    // On-device context window and reserves for instructions + model output.
    static let contextWindowTokens = 4096
    static let outputReserveTokens = 1200
    static let instructionReserveTokens = 400
    static var contentBudgetTokens: Int {
        max(256, contextWindowTokens - outputReserveTokens - instructionReserveTokens)
    }

    init(generator: ArticleGenerating, temperature: Double, maxTokens: Int) {
        self.generator = generator
        self.temperature = temperature
        self.maxTokens = maxTokens
    }

    func process(_ input: [AggregatedArticle], ai: AIOptions) async -> [AggregatedArticle] {
        let anyEnabled = ai.summarize || ai.improveWriting || ai.translate
        guard anyEnabled else { return input }
        // Model unavailable on this device → passthrough, never call the model.
        guard generator.availability == .available else { return input }

        var output: [AggregatedArticle] = []
        for article in input {
            if Task.isCancelled { break }
            guard !article.content.isEmpty else { output.append(article); continue }
            do {
                output.append(try await processOne(article, ai: ai))
            } catch {
                continue   // drop on failure
            }
        }
        return output
    }

    private func processOne(_ article: AggregatedArticle, ai: AIOptions) async throws -> AggregatedArticle {
        let clean = ArticleAIText.cap((try? ArticleAIText.stripChrome(article.content)) ?? article.content)
        let chunks = ArticleChunker.chunk(html: clean,
                                          budgetTokens: Self.contentBudgetTokens,
                                          tokenCount: generator.tokenCount)

        let instructions = Self.instructions(ai: ai)
        var title = article.title
        var mapped: [String] = []
        for (i, chunk) in chunks.enumerated() {
            let result = try await generator.generate(
                instructions: instructions,
                prompt: Self.prompt(title: article.title, html: chunk),
                temperature: temperature,
                maxTokens: maxTokens
            )
            if i == 0 { title = result.title }
            mapped.append(result.content)
        }
        var content = mapped.joined(separator: "\n")

        // Reduce: when summarizing, fold the (already per-chunk-summarized) pieces into one.
        if ai.summarize, chunks.count > 1 {
            let reduced = try await generator.generate(
                instructions: Self.reduceInstructions,
                prompt: Self.prompt(title: title, html: ArticleAIText.cap(content)),
                temperature: temperature,
                maxTokens: maxTokens
            )
            title = reduced.title
            content = reduced.content
        }

        var updated = article
        updated.title = title
        updated.content = content
        return updated
    }

    // MARK: - Prompt assembly (guided generation: no JSON-format boilerplate needed)

    static func instructions(ai: AIOptions) -> String {
        var parts = ["You process article content provided as HTML. "
            + "Preserve all HTML tags and structure in the content you return."]
        if ai.summarize { parts.append(ArticleAIText.summarizeInstruction) }
        if ai.improveWriting { parts.append(ArticleAIText.improveWritingInstruction) }
        if ai.translate {
            parts.append(ArticleAIText.translateInstruction(language: ai.translateLanguage))
        }
        return parts.joined(separator: "\n")
    }

    static let reduceInstructions =
        "You combine several partial article summaries into one concise summary. "
        + "Preserve any HTML structure. " + ArticleAIText.summarizeInstruction

    static func prompt(title: String, html: String) -> String {
        "Title: \(title)\n\nContent (HTML):\n\(html)"
    }
}
