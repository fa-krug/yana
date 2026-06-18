import Foundation
import Testing
@testable import Yana

@MainActor
@Suite("IdentifierSearch")
struct IdentifierSearchTests {
    @Test func subscriberCompactFormatting() {
        #expect(SubscriberCount.compact(7_937_468) == "7.9M")
        #expect(SubscriberCount.compact(2_360_328) == "2.4M")
        #expect(SubscriberCount.compact(411_321) == "411K")
        #expect(SubscriberCount.compact(30_251) == "30K")
        #expect(SubscriberCount.compact(1_500) == "1.5K")
        #expect(SubscriberCount.compact(999) == "999")
        #expect(SubscriberCount.compact(0) == "0")
    }

    @Test func redditResultsMapToStructuredRows() async {
        let model = IdentifierSearchModel(kind: .subreddit, credentials: .init(), userAgent: "Yana/1.0",
            redditSearch: { _ in
                [RedditSubredditResult(displayName: "swift", title: "Swift", subscribers: 12345)]
            }, youtubeSearch: { _ in [] }, redditPopular: { [] })
        await model.search("swi")
        #expect(model.rows.count == 1)
        #expect(model.rows.first?.value == "swift")
        #expect(model.rows.first?.title == "r/swift")
        #expect(model.rows.first?.subtitle.contains("Swift") == true)
        #expect(model.rows.first?.subtitle.contains("12K") == true)
    }

    @Test func youtubeResultsMapToStructuredRows() async {
        let model = IdentifierSearchModel(kind: .youtubeChannel, credentials: .init(), userAgent: "Yana/1.0",
            redditSearch: { _ in [] },
            youtubeSearch: { _ in [YouTubeChannelResult(channelID: "UCabc", title: "Cool", handle: "@cool")] },
            redditPopular: { [] })
        await model.search("cool")
        #expect(model.rows.first?.value == "UCabc")
        #expect(model.rows.first?.title == "Cool")
        #expect(model.rows.first?.subtitle == "@cool")
    }

    @Test func youtubeFallsBackToChannelIDWhenNoHandle() async {
        let model = IdentifierSearchModel(kind: .youtubeChannel, credentials: .init(), userAgent: "Yana/1.0",
            redditSearch: { _ in [] },
            youtubeSearch: { _ in [YouTubeChannelResult(channelID: "UCxyz", title: "NoHandle", handle: nil)] },
            redditPopular: { [] })
        await model.search("no")
        #expect(model.rows.first?.subtitle == "UCxyz")
    }

    @Test func preloadPopulatesRowsForSubreddit() async {
        let model = IdentifierSearchModel(kind: .subreddit, credentials: .init(), userAgent: "Yana/1.0",
            redditSearch: { _ in [] }, youtubeSearch: { _ in [] },
            redditPopular: { [RedditSubredditResult(displayName: "funny", title: "Funny", subscribers: 40_000_000)] })
        await model.preload()
        #expect(model.didPreload)
        #expect(model.rows.first?.title == "r/funny")
        #expect(model.rows.first?.subtitle.contains("40M") == true)
    }

    @Test func preloadIsIdempotent() async {
        final class Counter: @unchecked Sendable { var value = 0 }
        let counter = Counter()
        let model = IdentifierSearchModel(kind: .subreddit, credentials: .init(), userAgent: "Yana/1.0",
            redditSearch: { _ in [] }, youtubeSearch: { _ in [] },
            redditPopular: { counter.value += 1; return [RedditSubredditResult(displayName: "funny", title: "Funny", subscribers: 5)] })
        await model.preload()
        await model.preload()
        #expect(counter.value == 1)
        #expect(model.rows.count == 1)
    }

    @Test func clearingQueryRestoresPreloadedRows() async {
        let model = IdentifierSearchModel(kind: .subreddit, credentials: .init(), userAgent: "Yana/1.0",
            redditSearch: { _ in [RedditSubredditResult(displayName: "swift", title: "Swift", subscribers: 1)] },
            youtubeSearch: { _ in [] },
            redditPopular: { [RedditSubredditResult(displayName: "funny", title: "Funny", subscribers: 5)] })
        await model.preload()
        await model.search("swift")
        #expect(model.rows.first?.value == "swift")
        await model.search("")
        #expect(model.rows.first?.value == "funny")   // restored, not empty
        #expect(model.hasSearched == false)
    }
}
