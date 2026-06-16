import Foundation
import Testing
@testable import Yana

@Suite("AggregatorRegistry — generic")
struct AggregatorRegistryGenericTests {
    @Test func buildsFeedContentAndFullWebsite() {
        let feedCfg = FeedConfig(type: .feedContent, identifier: "u", dailyLimit: 20,
                                 options: .feedContent(FeedContentOptions()), collectedToday: 0)
        let webCfg = FeedConfig(type: .fullWebsite, identifier: "u", dailyLimit: 20,
                                options: .fullWebsite(WebsiteOptions()), collectedToday: 0)
        #expect(AggregatorRegistry.shared.makeAggregator(feedCfg, credentials: .init()) is FeedContentAggregator)
        #expect(AggregatorRegistry.shared.makeAggregator(webCfg, credentials: .init()) is FullWebsiteAggregator)
    }
}
