import Foundation
import Testing
@testable import Yana

@Suite("AggregatorRegistry")
struct AggregatorRegistryTests {
    @Test func returnsNilForUnregisteredType() {
        // Reddit is not yet registered (4e social/media fills its case).
        let config = FeedConfig(
            type: .reddit,
            identifier: "swift",
            dailyLimit: 20,
            options: .reddit(RedditOptions()),
            collectedToday: 0
        )
        #expect(AggregatorRegistry.shared.makeAggregator(config, credentials: .init()) == nil)
    }

    @Test func aggregatedArticleStoresAllFields() {
        let date = Date(timeIntervalSince1970: 1000)
        let a = AggregatedArticle(
            title: "Hello",
            identifier: "https://example.com/post/1",
            url: "https://example.com/post/1",
            rawContent: "<p>raw</p>",
            content: "<p>clean</p>",
            date: date,
            author: "Ada",
            iconURL: nil
        )
        #expect(a.title == "Hello")
        #expect(a.identifier == "https://example.com/post/1")
        #expect(a.date == date)
        #expect(a.author == "Ada")
    }
}
