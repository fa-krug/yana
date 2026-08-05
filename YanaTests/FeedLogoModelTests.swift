import Foundation
import Testing
@testable import Yana

@MainActor
@Suite("Feed.logoImageHash")
struct FeedLogoModelTests {
    @Test func defaultsToNilAndIsSettable() {
        let feed = Feed(name: "A", aggregator: "feedContent", identifier: "https://e.com/f.xml")
        #expect(feed.logoImageHash == nil)
        feed.logoImageHash = "abc123"
        #expect(feed.logoImageHash == "abc123")
    }
}
