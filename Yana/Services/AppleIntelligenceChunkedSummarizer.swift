import Foundation

/// On-device summarization: chunk + map-reduce over the ~4096-token on-device context window.
/// Extracted from the former `AppleIntelligenceProcessor` (which also handled improve-writing/
/// translate via the now-deleted `AIProcessing`/`AggregatedArticle`/`AIOptions` machinery, per
/// Task 12) -- this type keeps only the summarize path, consumed by `AppleIntelligenceSummaryProvider`.
enum AppleIntelligenceChunkedSummarizer {
    // On-device context window and reserves for instructions + model output.
    static let contextWindowTokens = 4096
    static let outputReserveTokens = 1200
    static let instructionReserveTokens = 400
    static var contentBudgetTokens: Int {
        max(256, contextWindowTokens - outputReserveTokens - instructionReserveTokens)
    }

    /// Generation knobs. Formerly the per-run `AIConfig.temperature`/`maxTokens` (fed from
    /// `AppSettings.aiTemperature`/`aiMaxTokens`, defaults 0.3/2000) -- both settings were deleted
    /// along with the rest of the 6-provider network AI stack (Task 15), so this on-device-only
    /// path now hardcodes the same defaults rather than exposing knobs nothing else reads.
    static let temperature = 0.3
    static let maxTokens = 2000

    /// Summarize article text via chunk → per-chunk summary → reduce into one summary string.
    ///
    /// Takes plain text (`Article.plainText`), which is what the only caller has always passed.
    /// The parameter used to be named `html` and was run through an HTML chrome-stripper first --
    /// see `ArticleAIText` and `ArticleChunker` for why that was not just redundant but actively
    /// defeated the chunking below.
    static func summarize(text: String, title: String, generator: ArticleGenerating) async -> String? {
        let clean = ArticleAIText.cap(text)
        let chunks = ArticleChunker.chunk(text: clean,
                                          budgetTokens: contentBudgetTokens,
                                          tokenCount: generator.tokenCount)
        do {
            var partials: [String] = []
            for chunk in chunks {
                let result = try await generator.generateSummary(
                    instructions: summaryInstructions,
                    prompt: prompt(title: title, text: chunk),
                    temperature: temperature,
                    maxTokens: maxTokens
                )
                partials.append(result)
            }
            guard partials.count > 1 else { return partials.first }
            return try await generator.generateSummary(
                instructions: reduceInstructions,
                prompt: prompt(title: title, text: ArticleAIText.cap(partials.joined(separator: "\n\n"))),
                temperature: temperature,
                maxTokens: maxTokens
            )
        } catch {
            return nil   // drop on failure -- "no summary" is an expected outcome here.
        }
    }

    // MARK: - Prompt assembly (guided generation: no JSON-format boilerplate needed)

    static let summaryInstructions =
        "You summarize article content. " + ArticleAIText.summarizeInstruction

    static let reduceInstructions =
        "You combine several partial article summaries into one concise summary. "
        + ArticleAIText.summarizeInstruction

    static func prompt(title: String, text: String) -> String {
        "Title: \(title)\n\nContent:\n\(text)"
    }
}
