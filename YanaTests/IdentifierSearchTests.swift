import Foundation
import Testing
@testable import Yana

@MainActor
@Suite("IdentifierSearch")
struct IdentifierSearchTests {
    @Test func redditResultsMapToRows() async {
        let model = IdentifierSearchModel(kind: .subreddit, credentials: .init(), userAgent: "Yana/1.0") { _ in
            [RedditSubredditResult(displayName: "swift", title: "Swift", subscribers: 12345)]
        } youtubeSearch: { _ in [] }
        await model.search("swi")
        #expect(model.rows.count == 1)
        #expect(model.rows.first?.value == "swift")
        #expect(model.rows.first?.label == "r/swift — Swift (12345 subs)")
    }

    @Test func youtubeResultsMapToRows() async {
        let model = IdentifierSearchModel(kind: .youtubeChannel, credentials: .init(), userAgent: "Yana/1.0") { _ in
            []
        } youtubeSearch: { _ in
            [YouTubeChannelResult(channelID: "UCabc", title: "Cool", handle: "@cool")]
        }
        await model.search("cool")
        #expect(model.rows.first?.value == "UCabc")
        #expect(model.rows.first?.label == "Cool (@cool)")
    }

    @Test func emptyQueryClearsRows() async {
        let model = IdentifierSearchModel(kind: .subreddit, credentials: .init(), userAgent: "Yana/1.0") { _ in
            [RedditSubredditResult(displayName: "x", title: "X", subscribers: 1)]
        } youtubeSearch: { _ in [] }
        await model.search("x")
        await model.search("")
        #expect(model.rows.isEmpty)
    }

    @Test func subscriberCompactFormatting() {
        #expect(SubscriberCount.compact(7_937_468) == "7.9M")
        #expect(SubscriberCount.compact(2_360_328) == "2.4M")
        #expect(SubscriberCount.compact(411_321) == "411K")
        #expect(SubscriberCount.compact(30_251) == "30K")
        #expect(SubscriberCount.compact(1_500) == "1.5K")
        #expect(SubscriberCount.compact(999) == "999")
        #expect(SubscriberCount.compact(0) == "0")
    }
}
