import Foundation
import SwiftData
import Testing
@testable import Yana

@MainActor
@Suite("BackgroundRefreshManager")
struct BackgroundRefreshManagerTests {
    @Test func nextBeginDateAddsIntervalToReference() {
        let now = Date(timeIntervalSince1970: 1_000_000_000)
        let result = BackgroundRefreshManager.nextBeginDate(from: now, interval: 1800)
        #expect(result == now.addingTimeInterval(1800))
    }

    @Test func nextBeginDateClampsNonPositiveIntervalToMinimum() {
        let now = Date(timeIntervalSince1970: 1_000_000_000)
        // Zero or negative intervals would let iOS run immediately/never; clamp to the floor.
        #expect(BackgroundRefreshManager.nextBeginDate(from: now, interval: 0)
                == now.addingTimeInterval(BackgroundRefreshManager.minimumInterval))
        #expect(BackgroundRefreshManager.nextBeginDate(from: now, interval: -500)
                == now.addingTimeInterval(BackgroundRefreshManager.minimumInterval))
    }

    private func makeContext() throws -> ModelContext {
        let config = ModelConfiguration(isStoredInMemoryOnly: true)
        let container = try ModelContainer(for: Feed.self, Yana.Tag.self, Article.self, configurations: config)
        let context = ModelContext(container)
        context.insert(Yana.Tag(name: Yana.Tag.starredName, isBuiltIn: true))
        return context
    }

    /// Fake aggregator returning one canned article (no network).
    private struct FakeAggregator: Aggregator {
        let articles: [AggregatedArticle]
        func validate() throws {}
        func aggregate() async throws -> [AggregatedArticle] { articles }
    }

    @Test func runRefreshAwaitsUpdateAllAndImports() async throws {
        let context = try makeContext()
        let feed = Feed(name: "A", aggregatorType: .feedContent, identifier: "a")
        context.insert(feed)

        let article = AggregatedArticle(
            title: "x1", identifier: "x1", url: "x1",
            rawContent: "", content: "c", date: .now, author: "", iconURL: nil
        )
        let service = AggregationService(context: context) { _, _ in
            FakeAggregator(articles: [article])
        }

        await BackgroundRefreshManager.runRefresh(service: service)

        #expect(service.isUpdating == false)
        #expect(feed.articles.count == 1)
    }
}
