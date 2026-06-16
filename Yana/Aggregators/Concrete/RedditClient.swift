import Foundation

/// Raw Reddit application-only OAuth client (replaces PRAW). Injectable fetch closure
/// keeps tests hermetic. `@unchecked Sendable`: created per run, the cached token is the
/// only mutable state and it is set once before concurrent reads.
final class RedditClient: @unchecked Sendable {
    typealias Fetch = @Sendable (URLRequest) async throws -> Data

    private let clientID: String
    private let clientSecret: String
    private let userAgent: String
    private let fetch: Fetch
    private var cachedToken: String?

    init(clientID: String, clientSecret: String, userAgent: String,
         fetch: @escaping Fetch = { try await HTTPClient.fetchJSON($0) }) {
        self.clientID = clientID
        self.clientSecret = clientSecret
        self.userAgent = userAgent
        self.fetch = fetch
    }

    func authToken() async throws -> String {
        if let cachedToken { return cachedToken }
        var req = URLRequest(url: URL(string: "https://www.reddit.com/api/v1/access_token")!)
        req.httpMethod = "POST"
        let basic = Data("\(clientID):\(clientSecret)".utf8).base64EncodedString()
        req.setValue("Basic \(basic)", forHTTPHeaderField: "Authorization")
        req.setValue(userAgent, forHTTPHeaderField: "User-Agent")
        req.setValue("application/x-www-form-urlencoded", forHTTPHeaderField: "Content-Type")
        req.httpBody = Data("grant_type=client_credentials".utf8)
        let data = try await fetch(req)
        let token = (try? JSONDecoder().decode(RedditTokenResponse.self, from: data))?.access_token
        guard let token, !token.isEmpty else { throw AggregatorError.contentFetch("Reddit auth failed") }
        cachedToken = token
        return token
    }

    func fetchListing(subreddit: String, sort: String, limit: Int) async throws -> [RedditPostData] {
        let url = URL(string: "https://oauth.reddit.com/r/\(subreddit)/\(sort).json?limit=\(limit)&raw_json=1")!
        let data = try await authorizedGET(url)
        let listing = try JSONDecoder().decode(RedditListing.self, from: data)
        return listing.data.children.map(\.data)
    }

    func fetchComments(subreddit: String, postID: String) async throws -> [RedditComment] {
        let url = URL(string: "https://oauth.reddit.com/comments/\(postID).json?sort=best&raw_json=1")!
        let data = try await authorizedGET(url)
        // Response is [postListing, commentListing]; index 1 holds the comments.
        let listings = try JSONDecoder().decode([RedditCommentEnvelope].self, from: data)
        guard listings.count >= 2 else { return [] }
        let raw = listings[1].data.children.compactMap(\.data)        // skips "more" kind (no data fields)
        let valid = raw.filter { isValidComment($0) }
        return valid.sorted { $0.score > $1.score }
    }

    static func searchSubreddits(query: String, credentials: AggregatorCredentials,
                                 userAgent: String,
                                 fetch: @escaping Fetch = { try await HTTPClient.fetchJSON($0) }) async -> [RedditSubredditResult] {
        guard let id = credentials.redditClientID, let secret = credentials.redditClientSecret,
              !query.isEmpty else { return [] }
        let client = RedditClient(clientID: id, clientSecret: secret, userAgent: userAgent, fetch: fetch)
        guard let q = query.addingPercentEncoding(withAllowedCharacters: .urlQueryAllowed),
              let url = URL(string: "https://oauth.reddit.com/subreddits/search.json?q=\(q)&limit=10&raw_json=1"),
              let data = try? await client.authorizedGET(url),
              let listing = try? JSONDecoder().decode(RedditSubredditListing.self, from: data) else { return [] }
        return listing.data.children.map {
            RedditSubredditResult(displayName: $0.data.displayName ?? "",
                                  title: $0.data.title ?? "",
                                  subscribers: $0.data.subscribers ?? 0)
        }.filter { !$0.displayName.isEmpty }
    }

    // MARK: - Helpers

    private func authorizedGET(_ url: URL) async throws -> Data {
        let token = try await authToken()
        var req = URLRequest(url: url)
        req.setValue("Bearer \(token)", forHTTPHeaderField: "Authorization")
        req.setValue(userAgent, forHTTPHeaderField: "User-Agent")
        return try await fetch(req)
    }

    private func isValidComment(_ c: RedditComment) -> Bool {
        guard !c.body.isEmpty, c.body != "[deleted]", c.body != "[removed]", !c.author.isEmpty else { return false }
        let a = c.author.lowercased()
        return !(a.hasSuffix("_bot") || a.hasSuffix("-bot") || a == "automoderator")
    }
}

struct RedditTokenResponse: Decodable { let access_token: String }

// MARK: - Decoding envelopes

private struct RedditListing: Decodable {
    let data: ListingData
    struct ListingData: Decodable { let children: [Child] }
    struct Child: Decodable { let data: RedditPostData }
}
private struct RedditCommentEnvelope: Decodable {
    let data: ListingData
    struct ListingData: Decodable { let children: [Child] }
    struct Child: Decodable {
        let data: RedditComment?     // optional: "more" kind has no comment fields
    }
}
private struct RedditSubredditListing: Decodable {
    let data: ListingData
    struct ListingData: Decodable { let children: [Child] }
    struct Child: Decodable { let data: SubData }
    struct SubData: Decodable {
        let displayName: String?
        let title: String?
        let subscribers: Int?
        enum CodingKeys: String, CodingKey {
            case displayName = "display_name", title, subscribers
        }
    }
}
