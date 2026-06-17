import Foundation
import Testing
@testable import Yana

@MainActor
@Suite("Feed.logoHash")
struct FeedLogoModelTests {
    @Test func defaultsToNilAndIsSettable() {
        let feed = Feed(name: "A", aggregatorType: .feedContent, identifier: "https://e.com/f.xml")
        #expect(feed.logoHash == nil)
        feed.logoHash = "abc123"
        #expect(feed.logoHash == "abc123")
    }
}
