import Foundation
import SwiftData
import Testing
@testable import Yana

@MainActor
@Suite("AggregationService")
struct AggregationServiceTests {
    private func makeContext() throws -> ModelContext {
        let config = ModelConfiguration(isStoredInMemoryOnly: true)
        let container = try ModelContainer(for: Feed.self, Yana.Tag.self, Article.self, configurations: config)
        let context = ModelContext(container)
        context.insert(Yana.Tag(name: Yana.Tag.starredName, isBuiltIn: true))
        return context
    }

    /// Fake aggregator returning canned articles (no network).
    private struct FakeAggregator: Aggregator {
        let articles: [AggregatedArticle]
        var validateError: Error?
        func validate() throws { if let validateError { throw validateError } }
        func aggregate() async throws -> [AggregatedArticle] { articles }
    }

    private nonisolated func aggregated(_ id: String, date: Date = .now) -> AggregatedArticle {
        AggregatedArticle(title: id, identifier: id, url: id, rawContent: "", content: "c", date: date, author: "", iconURL: nil)
    }

    @Test func updateAllImportsArticlesFromEnabledFeedsOnly() async throws {
        let context = try makeContext()
        let enabled = Feed(name: "A", aggregatorType: .feedContent, identifier: "a")
        let disabled = Feed(name: "B", aggregatorType: .feedContent, identifier: "b", enabled: false)
        context.insert(enabled); context.insert(disabled)

        let service = AggregationService(context: context) { _, _ in
            FakeAggregator(articles: [self.aggregated("x1"), self.aggregated("x2")])
        }
        await service.updateAll()

        #expect(service.isUpdating == false)
        #expect(enabled.articles.count == 2)
        #expect(disabled.articles.isEmpty)
        #expect(enabled.lastFetchedAt != nil)
        #expect(enabled.lastError == nil)
    }

    @Test func runCapLimitsImportedArticles() async throws {
        let context = try makeContext()
        let feed = Feed(name: "A", aggregatorType: .feedContent, identifier: "a", dailyLimit: 2)
        context.insert(feed)

        let service = AggregationService(context: context) { _, _ in
            FakeAggregator(articles: [self.aggregated("1"), self.aggregated("2"), self.aggregated("3")])
        }
        await service.update(feed: feed)

        #expect(feed.articles.count == 2)
    }

    @Test func dropsArticlesOlderThanIntakeWindow() async throws {
        let context = try makeContext()
        let feed = Feed(name: "A", aggregatorType: .feedContent, identifier: "a")
        context.insert(feed)
        let old = aggregated("old", date: Date.now.addingTimeInterval(-61 * 24 * 3600))

        let service = AggregationService(context: context) { _, _ in
            FakeAggregator(articles: [self.aggregated("fresh"), old])
        }
        await service.update(feed: feed)

        #expect(feed.articles.map(\.identifier) == ["fresh"])
    }

    @Test func feedFailureIsIsolatedAndRecorded() async throws {
        let context = try makeContext()
        let bad = Feed(name: "bad", aggregatorType: .feedContent, identifier: "bad")
        let good = Feed(name: "good", aggregatorType: .feedContent, identifier: "good")
        context.insert(bad); context.insert(good)

        let service = AggregationService(context: context) { config, _ in
            if config.identifier == "bad" {
                return FakeAggregator(articles: [], validateError: AggregatorError.missingIdentifier)
            }
            return FakeAggregator(articles: [self.aggregated("g1")])
        }
        await service.updateAll()

        #expect(bad.lastError != nil)
        #expect(good.articles.count == 1)        // one feed's failure didn't abort the run
        #expect(good.lastError == nil)
    }

    @Test func missingAggregatorRecordsError() async throws {
        let context = try makeContext()
        let feed = Feed(name: "A", aggregatorType: .reddit, identifier: "swift")
        context.insert(feed)

        // Default factory (registry) returns nil until Phase 4b.
        let service = AggregationService(context: context)
        await service.update(feed: feed)

        #expect(feed.lastError != nil)
        #expect(feed.articles.isEmpty)
    }
}
