import Foundation
import UIKit
import Testing
@testable import Yana

@Suite("RedditAggregator")
struct RedditAggregatorTests {
    private func tempStore() -> ImageStore {
        let dir = FileManager.default.temporaryDirectory.appendingPathComponent(UUID().uuidString)
        let png = UIGraphicsImageRenderer(size: CGSize(width: 50, height: 50)).image { _ in }.pngData()!
        return ImageStore(directory: dir, fetch: { _ in (png, "image/png") })
    }

    private let tokenJSON = #"{"access_token":"TKN"}"#
    // Use a recent timestamp (now minus 1 day) so fixtures pass the implementation's
    // Date()-relative two-month retention filter regardless of the wall-clock date.
    private let recentUTC = Date().addingTimeInterval(-24 * 3600).timeIntervalSince1970
    private var listingJSON: String {
        """
        {"data":{"children":[
          {"data":{"id":"p1","title":"Hello","selftext":"Body **bold** [docs](https://e.com/d)",
                   "url":"https://i.redd.it/pic.png","permalink":"/r/swift/comments/p1/hello/",
                   "created_utc":\(recentUTC),"author":"alice","score":42,"num_comments":7,"is_self":false}},
          {"data":{"id":"am","title":"Pinned","selftext":"","url":"","permalink":"/r/swift/comments/am/p/",
                   "created_utc":\(recentUTC),"author":"AutoModerator","score":1,"num_comments":99,"is_self":true}},
          {"data":{"id":"lc","title":"Few comments","selftext":"x","url":"","permalink":"/r/swift/comments/lc/p/",
                   "created_utc":\(recentUTC),"author":"carol","score":1,"num_comments":1,"is_self":true}}
        ]}}
        """
    }
    private let commentsJSON = """
    [ {"data":{"children":[]}},
      {"data":{"children":[
        {"kind":"t1","data":{"id":"c1","body":"Great post","author":"bob","score":10,"permalink":"/r/swift/comments/p1/hello/c1/"}}
      ]}} ]
    """

    private func makeAggregator(options: RedditOptions = RedditOptions()) -> RedditAggregator {
        var opts = options
        opts.minComments = 5      // p1=7 keeps, lc=1 drops
        opts.minAgeHours = 0      // disable age filter for deterministic fixture dates
        let config = FeedConfig(type: .reddit, identifier: "swift", dailyLimit: 25,
                                options: .reddit(opts), collectedToday: 0)
        let creds = AggregatorCredentials(redditClientID: "id", redditClientSecret: "secret", youtubeAPIKey: nil)
        let client = RedditClient(clientID: "id", clientSecret: "secret", userAgent: "Yana/1.0") { request in
            let url = request.url!.absoluteString
            if url.contains("access_token") { return Data(self.tokenJSON.utf8) }
            if url.contains("/comments/") { return Data(self.commentsJSON.utf8) }
            return Data(self.listingJSON.utf8)
        }
        return RedditAggregator(config: config, credentials: creds, store: tempStore(), client: client)
    }

    @Test func filtersAutoModeratorAndLowComments() async throws {
        let articles = try await makeAggregator().aggregate()
        #expect(articles.count == 1)
        #expect(articles.first?.title == "Hello")
        #expect(articles.first?.author == "alice")
    }

    @Test func buildsContentWithMarkdownCommentsAndFooter() async throws {
        let a = try #require(try await makeAggregator().aggregate().first)
        #expect(a.content.contains("<strong>bold</strong>"))      // selftext markdown
        #expect(a.content.contains("Great post"))                 // comment body
        #expect(a.content.contains("<blockquote"))                // comment markup
        #expect(a.content.contains("<strong>bob</strong>"))       // comment author
        #expect(a.content.contains("Source:"))                    // formatArticleContent footer
        #expect(a.identifier == "https://reddit.com/r/swift/comments/p1/hello/")
    }

    @Test func headerImageLocalizedAndDedupedFromBody() async throws {
        let a = try #require(try await makeAggregator().aggregate().first)
        #expect(a.content.contains("\(ReaderWeb.imageScheme)://"))   // header image cached
        #expect(!a.content.contains("https://i.redd.it/pic.png"))     // remote url removed
    }

    @Test func missingCredentialsThrows() async {
        let config = FeedConfig(type: .reddit, identifier: "swift", dailyLimit: 25,
                                options: .reddit(RedditOptions()), collectedToday: 0)
        let agg = RedditAggregator(config: config, credentials: .init(), store: tempStore(), client: nil)
        await #expect(throws: AggregatorError.self) { try await agg.aggregate() }
    }
}
