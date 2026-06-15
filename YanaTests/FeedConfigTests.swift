import Foundation
import SwiftData
import Testing
@testable import Yana

@MainActor
@Suite("FeedConfig")
struct FeedConfigTests {
    private func makeContext() throws -> ModelContext {
        let config = ModelConfiguration(isStoredInMemoryOnly: true)
        let container = try ModelContainer(for: Feed.self, Yana.Tag.self, Article.self, configurations: config)
        return ModelContext(container)
    }

    @Test func snapshotCopiesFeedFieldsAndCollectedToday() throws {
        let context = try makeContext()
        let feed = Feed(name: "A", aggregatorType: .feedContent, identifier: "https://a.com/feed", dailyLimit: 12)
        context.insert(feed)

        let config = FeedConfig(feed: feed, collectedToday: 3)

        #expect(config.type == .feedContent)
        #expect(config.identifier == "https://a.com/feed")
        #expect(config.dailyLimit == 12)
        #expect(config.collectedToday == 3)
    }
}
