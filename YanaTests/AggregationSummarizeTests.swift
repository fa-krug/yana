import Foundation
import SwiftData
import Testing
@testable import Yana

@MainActor
@Suite("AggregationService.summarize")
struct AggregationSummarizeTests {
    private func makeContext() throws -> ModelContext {
        let config = ModelConfiguration(isStoredInMemoryOnly: true)
        let container = try ModelContainer(for: Feed.self, Yana.Tag.self, Article.self, configurations: config)
        let context = ModelContext(container)
        context.insert(Yana.Tag(name: Yana.Tag.starredName, isBuiltIn: true))
        return context
    }

    /// Stub processor that stamps a fixed summary onto every input article.
    private struct StubSummarizer: AIProcessing {
        let summary: String
        func process(_ input: [AggregatedArticle], ai: AIOptions) async -> [AggregatedArticle] {
            input.map { var a = $0; a.summary = summary; return a }
        }
    }

    /// Stub processor that drops everything (mirrors AI failure / invalid JSON).
    private struct DroppingProcessor: AIProcessing {
        func process(_ input: [AggregatedArticle], ai: AIOptions) async -> [AggregatedArticle] { [] }
    }

    @Test func writesSummaryAndReturnsTrue() async throws {
        let context = try makeContext()
        let article = Article(title: "T", identifier: "i", url: "https://x")
        article.plainText = "body"   // summarize seeds the AI from the article's visible text
        context.insert(article)

        let service = AggregationService(context: context, aiProcessor: StubSummarizer(summary: "Short summary."))
        let ok = await service.summarize(article)

        #expect(ok == true)
        #expect(article.summary == "Short summary.")
    }

    @Test func failureLeavesArticleUnchanged() async throws {
        let context = try makeContext()
        let article = Article(title: "T", identifier: "i", url: "https://x", summary: "old")
        article.plainText = "body"
        context.insert(article)

        let service = AggregationService(context: context, aiProcessor: DroppingProcessor())
        let ok = await service.summarize(article)

        #expect(ok == false)
        #expect(article.summary == "old")
    }
}
