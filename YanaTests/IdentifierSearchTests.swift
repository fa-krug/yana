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
        #expect(model.rows.first?.label.contains("Swift") == true)
    }

    @Test func youtubeResultsMapToRows() async {
        let model = IdentifierSearchModel(kind: .youtubeChannel, credentials: .init(), userAgent: "Yana/1.0") { _ in
            []
        } youtubeSearch: { _ in
            [YouTubeChannelResult(channelID: "UCabc", title: "Cool", handle: "@cool")]
        }
        await model.search("cool")
        #expect(model.rows.first?.value == "UCabc")
        #expect(model.rows.first?.label.contains("Cool") == true)
    }

    @Test func emptyQueryClearsRows() async {
        let model = IdentifierSearchModel(kind: .subreddit, credentials: .init(), userAgent: "Yana/1.0") { _ in
            [RedditSubredditResult(displayName: "x", title: "X", subscribers: 1)]
        } youtubeSearch: { _ in [] }
        await model.search("x")
        await model.search("")
        #expect(model.rows.isEmpty)
    }
}
