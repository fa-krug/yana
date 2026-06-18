import Foundation
import Testing
@testable import Yana

struct AIProcessorSummaryTests {
    private func config() -> AIConfig {
        AIConfig(provider: .openai, model: "m", apiKey: "k", apiBaseURL: "https://api.openai.com/v1",
                 temperature: 0.3, maxTokens: 100, requestTimeout: 30,
                 maxRetries: 0, retryDelay: 0, maxRetryTime: 10)
    }

    private func article() -> AggregatedArticle {
        AggregatedArticle(title: "T", identifier: "id", url: "u", rawContent: "",
                          content: "<p>full body</p>", date: .now, author: "", iconURL: nil)
    }

    @Test func summarizePromptRequestsSummaryKeyAndPreservesContent() {
        let ai = AIOptions(summarize: true, improveWriting: false, translate: false, translateLanguage: "English")
        let prompt = AIProcessor.buildPrompt(title: "T", cleanHTML: "<p>x</p>", ai: ai)
        #expect(prompt.contains("'summary'") || prompt.contains("summary"))
        #expect(prompt.lowercased().contains("full article") || prompt.lowercased().contains("do not replace"))
    }

    @Test func noSummaryKeyWhenSummarizeOff() {
        let ai = AIOptions(summarize: false, improveWriting: true, translate: false, translateLanguage: "English")
        let prompt = AIProcessor.buildPrompt(title: "T", cleanHTML: "<p>x</p>", ai: ai)
        #expect(!prompt.contains("'summary'"))
    }

    @Test func processPopulatesSummaryAndKeepsContent() async {
        let ai = AIOptions(summarize: true, improveWriting: false, translate: false, translateLanguage: "English")
        let processor = AIProcessor(config: config(), requestDelay: 0) { _, _ in
            #"{"title":"T","content":"<p>full body</p>","summary":"short summary"}"#
        }
        let out = await processor.process([article()], ai: ai)
        #expect(out.count == 1)
        #expect(out.first?.summary == "short summary")
        #expect(out.first?.content == "<p>full body</p>")
    }
}
