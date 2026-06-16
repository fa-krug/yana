import Foundation
import Testing
@testable import Yana

@Suite("RedditClient")
struct RedditClientTests {
    private let tokenJSON = #"{"access_token":"TKN","token_type":"bearer","expires_in":3600}"#

    private let listingJSON = """
    {"data":{"children":[
      {"data":{"id":"p1","title":"Hello","selftext":"Body **bold**","url":"https://reddit.com/r/swift/comments/p1/hello/",
               "permalink":"/r/swift/comments/p1/hello/","created_utc":1700000000,"author":"alice",
               "score":42,"num_comments":7,"is_self":true,"is_gallery":false,"is_video":false}},
      {"data":{"id":"am","title":"Pinned","selftext":"","url":"","permalink":"/r/swift/comments/am/pinned/",
               "created_utc":1700000000,"author":"AutoModerator","score":1,"num_comments":0,"is_self":true}}
    ]}}
    """

    private let commentsJSON = """
    [
      {"data":{"children":[{"data":{"id":"px","title":"Hello","selftext":"x","permalink":"/r/swift/comments/p1/hello/","author":"alice","created_utc":1700000000,"num_comments":7}}]}},
      {"data":{"children":[
        {"kind":"t1","data":{"id":"c1","body":"Top comment","author":"bob","score":10,"permalink":"/r/swift/comments/p1/hello/c1/"}},
        {"kind":"t1","data":{"id":"c2","body":"Low comment","author":"carol","score":2,"permalink":"/r/swift/comments/p1/hello/c2/"}},
        {"kind":"t1","data":{"id":"c3","body":"[deleted]","author":"dave","score":99,"permalink":"/x"}},
        {"kind":"t1","data":{"id":"c4","body":"bot output","author":"helpful_bot","score":50,"permalink":"/y"}},
        {"kind":"more","data":{"id":"more"}}
      ]}}
    ]
    """

    /// Routes by URL so one client serves token, listing, and comments.
    private func client() -> RedditClient {
        RedditClient(clientID: "id", clientSecret: "secret", userAgent: "Yana/1.0") { request in
            let url = request.url!.absoluteString
            if url.contains("access_token") { return Data(self.tokenJSON.utf8) }
            if url.contains("/comments/") { return Data(self.commentsJSON.utf8) }
            return Data(self.listingJSON.utf8)
        }
    }

    @Test func authTokenIsParsed() async throws {
        let token = try await client().authToken()
        #expect(token == "TKN")
    }

    @Test func listingParsesPosts() async throws {
        let posts = try await client().fetchListing(subreddit: "swift", sort: "hot", limit: 25)
        #expect(posts.count == 2)
        #expect(posts.first?.title == "Hello")
        #expect(posts.first?.author == "alice")
        #expect(posts.first?.numComments == 7)
    }

    @Test func commentsFilteredAndSorted() async throws {
        let comments = try await client().fetchComments(subreddit: "swift", postID: "p1")
        // deleted + bot removed; sorted by score desc.
        #expect(comments.map(\.author) == ["bob", "carol"])
        #expect(comments.first?.score == 10)
    }

    /// Thread-safe box so the `@Sendable` fetch closure can record the request it saw
    /// (Swift 6 strict concurrency forbids mutating a captured `var` inside it).
    private final class RequestBox: @unchecked Sendable {
        private let lock = NSLock()
        private var value: URLRequest?
        func set(_ request: URLRequest) { lock.lock(); value = request; lock.unlock() }
        var captured: URLRequest? { lock.lock(); defer { lock.unlock() }; return value }
    }

    @Test func authRequestUsesBasicAuthAndUserAgent() async throws {
        let box = RequestBox()
        let c = RedditClient(clientID: "abc", clientSecret: "xyz", userAgent: "MyAgent/9") { request in
            if request.url!.absoluteString.contains("access_token") { box.set(request) }
            return Data(self.tokenJSON.utf8)
        }
        _ = try await c.authToken()
        let req = try #require(box.captured)
        let basic = Data("abc:xyz".utf8).base64EncodedString()
        #expect(req.value(forHTTPHeaderField: "Authorization") == "Basic \(basic)")
        #expect(req.value(forHTTPHeaderField: "User-Agent") == "MyAgent/9")
        #expect(req.httpMethod == "POST")
    }

    @Test func encodesPathComponents() {
        #expect(RedditClient.encodePath("all") == "all")
        #expect(RedditClient.encodePath("a b") == "a%20b")
        #expect(RedditClient.encodePath("a/b") == "a%2Fb")
    }

    @Test func tokenExpiryGate() {
        let now = Date(timeIntervalSince1970: 1_000)
        #expect(RedditClient.isExpired(expiry: now.addingTimeInterval(60), now: now) == false)
        #expect(RedditClient.isExpired(expiry: now, now: now) == true)
    }
}
