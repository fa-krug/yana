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
        // `stripChrome` drops the lead-image <header>; restore it onto a rewritten body below so
        // improve/translate don't lose the header image. (Summarize-only leaves `content` as-is.)
        let headerHTML = (try? ArticleAIText.leadingHeaderHTML(article.content)) ?? nil

        var title = article.title
        var content = article.content

        // Content pass: only when the body is actually being rewritten (improve/translate).
        // Summarize no longer modifies the body — it produces a separate summary below.
        if ai.improveWriting || ai.translate {
            let instructions = Self.contentInstructions(ai: ai)
            let chunks = ArticleChunker.chunk(html: clean,
                                              budgetTokens: Self.contentBudgetTokens,
                                              tokenCount: generator.tokenCount)
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
            content = (headerHTML ?? "") + mapped.joined(separator: "\n")
        }

        var updated = article
        updated.title = title
        updated.content = content

        // Summary pass: chunk + map + reduce over the (possibly transformed) content.
        if ai.summarize {
            updated.summary = try await summarize(html: content, title: title)
        }
        return updated
    }

    /// Summarize HTML via chunk → per-chunk summary → reduce into one summary string.
    private func summarize(html: String, title: String) async throws -> String {
        let clean = ArticleAIText.cap((try? ArticleAIText.stripChrome(html)) ?? html)
        let chunks = ArticleChunker.chunk(html: clean,
                                          budgetTokens: Self.contentBudgetTokens,
                                          tokenCount: generator.tokenCount)
        var partials: [String] = []
        for chunk in chunks {
            let result = try await generator.generateSummary(
                instructions: Self.summaryInstructions,
                prompt: Self.prompt(title: title, html: chunk),
                temperature: temperature,
                maxTokens: maxTokens
            )
            partials.append(result)
        }
        guard partials.count > 1 else { return partials.first ?? "" }
        return try await generator.generateSummary(
            instructions: Self.reduceInstructions,
            prompt: Self.prompt(title: title, html: ArticleAIText.cap(partials.joined(separator: "\n"))),
            temperature: temperature,
            maxTokens: maxTokens
        )
    }

    // MARK: - Prompt assembly (guided generation: no JSON-format boilerplate needed)

    /// Instructions for the body-rewrite pass — improve/translate only. Summarize is handled
    /// by a separate pass so the body is never collapsed into a summary.
    static func contentInstructions(ai: AIOptions) -> String {
        var parts = ["You process article content provided as HTML. "
            + "Preserve all HTML tags and structure in the content you return."]
        if ai.improveWriting { parts.append(ArticleAIText.improveWritingInstruction) }
        if ai.translate {
            parts.append(ArticleAIText.translateInstruction(language: ai.translateLanguage))
        }
        return parts.joined(separator: "\n")
    }

    static let summaryInstructions =
        "You summarize article content provided as HTML. " + ArticleAIText.summarizeInstruction

    static let reduceInstructions =
        "You combine several partial article summaries into one concise summary. "
        + ArticleAIText.summarizeInstruction

    static func prompt(title: String, html: String) -> String {
        "Title: \(title)\n\nContent (HTML):\n\(html)"
    }
}
