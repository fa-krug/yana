import Foundation
import Testing
@testable import Yana

private struct FakeGenerator: ArticleGenerating {
    let availability: AppleIntelligenceAvailability = .available
    let contentReply: String
    let summaryReply: String
    // Body-rewrite pass returns the configured content reply.
    func generate(instructions: String, prompt: String, temperature: Double, maxTokens: Int) async throws -> ProcessedArticle {
        ProcessedArticle(title: "T", content: contentReply)
    }
    // Summary pass goes through its own method, returning a distinct summary string.
    func generateSummary(instructions: String, prompt: String, temperature: Double, maxTokens: Int) async throws -> String {
        summaryReply
    }
    func tokenCount(_ text: String) -> Int { max(1, text.count / 4) }
}

/// Simulates the real on-device model honoring the guided-generation `@Guide`: the
/// `ProcessedArticle` path always reproduces the article body (preserving structure),
/// while the dedicated summary path produces an actual summary. Catches the regression
/// where summaries routed through `ProcessedArticle` returned the body verbatim.
private struct StructurePreservingGenerator: ArticleGenerating {
    let availability: AppleIntelligenceAvailability = .available
    // Echoes the prompt's HTML content back — mimics "preserve the input structure".
    func generate(instructions: String, prompt: String, temperature: Double, maxTokens: Int) async throws -> ProcessedArticle {
        ProcessedArticle(title: "T", content: prompt)
    }
    func generateSummary(instructions: String, prompt: String, temperature: Double, maxTokens: Int) async throws -> String {
        "a real summary"
    }
    func tokenCount(_ text: String) -> Int { max(1, text.count / 4) }
}

struct AppleIntelligenceSummaryTests {
    @Test func summarizeProducesSeparateSummaryAndKeepsBody() async {
        let gen = FakeGenerator(contentReply: "<p>full body</p>", summaryReply: "short summary")
        let processor = AppleIntelligenceProcessor(generator: gen, temperature: 0.3, maxTokens: 200)
        let ai = AIOptions(summarize: true, improveWriting: false, translate: false, translateLanguage: "English")
        let input = AggregatedArticle(title: "T", identifier: "id", url: "u", rawContent: "",
                                      content: "<p>original body</p>", date: .now, author: "", iconURL: nil)
        let out = await processor.process([input], ai: ai)
        #expect(out.count == 1)
        #expect(out.first?.summary == "short summary")
        // Summarize alone must not rewrite the body.
        #expect(out.first?.content == "<p>original body</p>")
    }

    @Test func summaryIsNotTheArticleBodyWhenModelPreservesStructure() async {
        // A model that honors the ProcessedArticle @Guide echoes the body. The summary
        // must NOT be that body — it must come from the dedicated summary path.
        let gen = StructurePreservingGenerator()
        let processor = AppleIntelligenceProcessor(generator: gen, temperature: 0.3, maxTokens: 200)
        let ai = AIOptions(summarize: true, improveWriting: false, translate: false, translateLanguage: "English")
        let body = "<p>The quick brown fox jumps over the lazy dog.</p>"
        let input = AggregatedArticle(title: "T", identifier: "id", url: "u", rawContent: "",
                                      content: body, date: .now, author: "", iconURL: nil)
        let out = await processor.process([input], ai: ai)
        #expect(out.count == 1)
        #expect(out.first?.summary == "a real summary")
        #expect(out.first?.summary.contains("<p>") == false)
        #expect(out.first?.content == body)
    }
}
