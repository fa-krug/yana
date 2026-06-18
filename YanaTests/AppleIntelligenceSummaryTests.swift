import Foundation
import Testing
@testable import Yana

private struct FakeGenerator: ArticleGenerating {
    let availability: AppleIntelligenceAvailability = .available
    let contentReply: String
    let summaryReply: String
    // Returns summaryReply for the dedicated summary pass, contentReply otherwise.
    func generate(instructions: String, prompt: String, temperature: Double, maxTokens: Int) async throws -> ProcessedArticle {
        if instructions.contains("summary") || instructions.contains("Summarize") {
            return ProcessedArticle(title: "T", content: summaryReply)
        }
        return ProcessedArticle(title: "T", content: contentReply)
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
}
