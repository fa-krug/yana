import Foundation
import SwiftData
import Testing
@testable import Yana

@MainActor
@Suite("Feed model")
struct FeedModelTests {
    @Test func hasNoAggregatorTypeCoupling() throws {
        let container = try ModelContainer(for: Feed.self, configurations: .init(isStoredInMemoryOnly: true))
        let context = container.mainContext
        let feed = Feed(name: "Test Feed", aggregator: "reddit", identifier: "1")
        context.insert(feed)
        #expect(feed.aggregator == "reddit")
        #expect(feed.logoImageHash == nil)
        #expect(feed.tagIDs.isEmpty)
    }
}
