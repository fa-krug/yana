import Foundation
import SwiftData
import Testing
@testable import Yana

@MainActor
@Suite("ArticleSearch")
struct ArticleSearchTests {
    private func makeContainer() throws -> ModelContainer {
        let config = ModelConfiguration(isStoredInMemoryOnly: true, cloudKitDatabase: .none)
        return try ModelContainer(for: Feed.self, Yana.Tag.self, Article.self, configurations: config)
    }

    /// Pins the off-main `ArticleSearcher` path end to end: a title-matching query finds the seeded
    /// article and a non-matching query finds nothing, through the new `container`-based signature.
    @Test func searchSummariesMatchesTitleOffMain() async throws {
        let container = try makeContainer()
        let context = ModelContext(container)
        let article = Article(title: "Solar Battery Breakthrough", identifier: "a1", url: "u", date: .now)
        context.insert(article)
        try context.save()

        let hits = await ArticleSearch.searchSummaries(query: "battery", container: container)
        #expect(hits.count == 1)

        let misses = await ArticleSearch.searchSummaries(query: "zeppelin", container: container)
        #expect(misses.isEmpty)
    }
}
