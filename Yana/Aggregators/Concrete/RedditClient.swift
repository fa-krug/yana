import Foundation

/// Raw Reddit application-only OAuth client (replaces PRAW). Injectable fetch closure
/// keeps tests hermetic. `@unchecked Sendable`: the cached token is the only mutable
/// state and its read/write are guarded by `tokenLock`.
final class RedditClient: @unchecked Sendable {
    typealias Fetch = @Sendable (URLRequest) async throws -> Data

    private let clientID: String
    private let clientSecret: String
    private let userAgent: String
    private let fetch: Fetch
    private let tokenLock = NSLock()
    private var cachedToken: String?
    private var tokenExpiry: Date?

    /// Percent-encode a single path segment so reserved characters can't break or redirect the URL.
    static func encodePath(_ s: String) -> String {
        s.addingPercentEncoding(withAllowedCharacters: .urlHostAllowed) ?? s
    }

    /// Pure expiry gate (testable). True when `now` has reached or passed `expiry`.
    static func isExpired(expiry: Date, now: Date) -> Bool { now >= expiry }

    init(clientID: String, clientSecret: String, userAgent: String,
         fetch: @escaping Fetch = { try await HTTPClient.fetchJSON($0) }) {
        self.clientID = clientID
        self.clientSecret = clientSecret
        self.userAgent = userAgent
        self.fetch = fetch
    }

    func authToken() async throws -> String {
        if let cached = cachedTokenValue() { return cached }
        var req = URLRequest(url: URL(string: "https://www.reddit.com/api/v1/access_token")!)
        req.httpMethod = "POST"
        let basic = Data("\(clientID):\(clientSecret)".utf8).base64EncodedString()
        req.setValue("Basic \(basic)", forHTTPHeaderField: "Authorization")
        req.setValue(userAgent, forHTTPHeaderField: "User-Agent")
        req.setValue("application/x-www-form-urlencoded", forHTTPHeaderField: "Content-Type")
        req.httpBody = Data("grant_type=client_credentials".utf8)
        let data = try await fetch(req)
        let decoded = try? JSONDecoder().decode(RedditTokenResponse.self, from: data)
        guard let token = decoded?.accessToken, !token.isEmpty else {
            throw AggregatorError.contentFetch("Reddit auth failed")
        }
        // Refresh 60s before the real expiry to avoid using a token mid-flight as it lapses.
        let ttl = max(0, (decoded?.expiresIn ?? 3600) - 60)
        setCachedToken(token, expiry: Date().addingTimeInterval(TimeInterval(ttl)))
        return token
    }

    private func cachedTokenValue() -> String? {
        tokenLock.lock(); defer { tokenLock.unlock() }
        guard let token = cachedToken, let expiry = tokenExpiry,
              !Self.isExpired(expiry: expiry, now: Date()) else { return nil }
        return token
    }

    private func setCachedToken(_ token: String, expiry: Date) {
        tokenLock.lock(); defer { tokenLock.unlock() }
        cachedToken = token
        tokenExpiry = expiry
    }

    func fetchListing(subreddit: String, sort: String, limit: Int) async throws -> [RedditPostData] {
        guard let url = URL(string:
            "https://oauth.reddit.com/r/\(Self.encodePath(subreddit))/\(Self.encodePath(sort)).json?limit=\(limit)&raw_json=1")
        else { throw AggregatorError.contentFetch("invalid subreddit/sort") }
        let data = try await authorizedGET(url)
        let listing = try JSONDecoder().decode(RedditListing.self, from: data)
        return listing.data.children.map(\.data)
    }

    func fetchComments(subreddit: String, postID: String) async throws -> [RedditComment] {
        guard let url = URL(string:
            "https://oauth.reddit.com/comments/\(Self.encodePath(postID)).json?sort=best&raw_json=1")
        else { throw AggregatorError.contentFetch("invalid post id") }
        let data = try await authorizedGET(url)
        // Response is [postListing, commentListing]; index 1 holds the comments.
        let listings = try JSONDecoder().decode([RedditCommentEnvelope].self, from: data)
        guard listings.count >= 2 else { return [] }
        // A "more" kind child still decodes (its {"id":"more"} yields a comment with empty
        // body/author via RedditComment's defensive init); it is dropped by isValidComment below.
        let raw = listings[1].data.children.compactMap(\.data)
        let valid = raw.filter { isValidComment($0) }
        return valid.sorted { $0.score > $1.score }
    }

    /// Subreddit icon for the feed logo. Prefers `community_icon`, falls back to `icon_img`.
    /// Returns the entity-decoded, trimmed URL, or nil when unavailable.
    func fetchSubredditAbout(_ subreddit: String) async -> String? {
        guard let url = URL(string:
            "https://oauth.reddit.com/r/\(Self.encodePath(subreddit))/about.json?raw_json=1")
        else { return nil }
        guard let data = try? await authorizedGET(url),
              let about = try? JSONDecoder().decode(RedditAboutResponse.self, from: data) else { return nil }
        for raw in [about.data.communityIcon, about.data.iconImg] {
            guard let raw, !raw.isEmpty else { continue }
            let decoded = RedditMarkdown.decodeEntities(raw).trimmingCharacters(in: .whitespaces)
            if !decoded.isEmpty { return decoded }
        }
        return nil
    }

    static func searchSubreddits(query: String, credentials: AggregatorCredentials,
                                 userAgent: String,
                                 fetch: @escaping Fetch = { try await HTTPClient.fetchJSON($0) }) async -> [RedditSubredditResult] {
        guard let id = credentials.redditClientID, let secret = credentials.redditClientSecret,
              !query.isEmpty else { return [] }
        let client = RedditClient(clientID: id, clientSecret: secret, userAgent: userAgent, fetch: fetch)
        guard let q = query.addingPercentEncoding(withAllowedCharacters: .urlQueryAllowed),
              let url = URL(string: "https://oauth.reddit.com/subreddits/search.json?q=\(q)&limit=25&raw_json=1"),
              let data = try? await client.authorizedGET(url),
              let listing = try? JSONDecoder().decode(RedditSubredditListing.self, from: data) else { return [] }
        return listing.data.children.map {
            RedditSubredditResult(displayName: $0.data.displayName ?? "",
                                  title: $0.data.title ?? "",
                                  subscribers: $0.data.subscribers ?? 0)
        }.filter { !$0.displayName.isEmpty }
    }

    static func popularSubreddits(credentials: AggregatorCredentials, userAgent: String,
                                  fetch: @escaping Fetch = { try await HTTPClient.fetchJSON($0) }) async -> [RedditSubredditResult] {
        guard let id = credentials.redditClientID, let secret = credentials.redditClientSecret else { return [] }
        let client = RedditClient(clientID: id, clientSecret: secret, userAgent: userAgent, fetch: fetch)
        guard let url = URL(string: "https://oauth.reddit.com/subreddits/popular.json?limit=25&raw_json=1"),
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

struct RedditTokenResponse: Decodable {
    let accessToken: String
    let expiresIn: Int?
    enum CodingKeys: String, CodingKey {
        case accessToken = "access_token"
        case expiresIn = "expires_in"
    }
}

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
private struct RedditAboutResponse: Decodable {
    let data: AboutData
    struct AboutData: Decodable {
        let communityIcon: String?
        let iconImg: String?
        enum CodingKeys: String, CodingKey {
            case communityIcon = "community_icon", iconImg = "icon_img"
        }
    }
}
