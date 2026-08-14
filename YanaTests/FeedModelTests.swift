import Foundation
import SwiftData
import Testing
@testable import Yana

@MainActor
@Suite("Feed model")
struct FeedModelTests {
    /// A `Feed` carries only what this client renders: a name, the server's id, a logo hash, and
    /// the live tag join. No aggregator key, no `enabled`/`dailyLimit` — that is server-owned
    /// configuration, so there is nothing here for a client-side branch to key off.
    @Test func storesOnlyRenderableState() throws {
        let container = try ModelContainer(for: Feed.self, configurations: .init(isStoredInMemoryOnly: true))
        let context = container.mainContext
        let feed = Feed(name: "Test Feed", identifier: "1")
        context.insert(feed)
        #expect(feed.name == "Test Feed")
        #expect(feed.identifier == "1")
        #expect(feed.logoImageHash == nil)
        #expect(feed.tagIDs.isEmpty)
    }
}
