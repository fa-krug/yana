import Foundation
import SwiftData
import Testing
@testable import Yana

@MainActor
@Suite("AggregationService stub")
struct AggregationServiceTests {
    private func makeContext() throws -> ModelContext {
        let config = ModelConfiguration(isStoredInMemoryOnly: true)
        let container = try ModelContainer(for: Feed.self, Yana.Tag.self, Article.self, configurations: config)
        return ModelContext(container)
    }

    @Test func updateAllTouchesEnabledFeedsAndClearsFlag() async throws {
        let context = try makeContext()
        let enabled = Feed(name: "A", aggregatorType: .feedContent, identifier: "https://a.com/feed")
        let disabled = Feed(name: "B", aggregatorType: .feedContent, identifier: "https://b.com/feed", enabled: false)
        context.insert(enabled); context.insert(disabled)
        try context.save()

        let service = AggregationService(context: context)
        await service.updateAll()

        #expect(service.isUpdating == false)
        #expect(enabled.lastFetchedAt != nil)
        #expect(disabled.lastFetchedAt == nil)
    }

    @Test func updateFeedTouchesThatFeed() async throws {
        let context = try makeContext()
        let feed = Feed(name: "A", aggregatorType: .feedContent, identifier: "https://a.com/feed")
        context.insert(feed)
        try context.save()

        let service = AggregationService(context: context)
        await service.update(feed: feed)
        #expect(feed.lastFetchedAt != nil)
    }
}
