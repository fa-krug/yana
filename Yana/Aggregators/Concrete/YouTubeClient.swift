import Foundation

/// YouTube Data API v3 client. Injectable fetch closure keeps tests hermetic.
final class YouTubeClient: @unchecked Sendable {
    typealias Fetch = @Sendable (URLRequest) async throws -> Data
    private static let base = "https://www.googleapis.com/youtube/v3"

    private let apiKey: String
    private let fetch: Fetch

    init(apiKey: String, fetch: @escaping Fetch = { try await HTTPClient.fetchJSON($0) }) {
        self.apiKey = apiKey
        self.fetch = fetch
    }

    func resolveChannelID(_ identifier: String) async throws -> String {
        let iden = identifier.trimmingCharacters(in: .whitespaces)
        guard !iden.isEmpty else { throw AggregatorError.missingIdentifier }
        if iden.hasPrefix("UC") && iden.count >= 24 { return iden }

        var handle = iden
        if iden.contains("youtube.com") || iden.contains("youtu.be") {
            if let extracted = extractChannelID(fromURL: iden) { return extracted }
            handle = extractHandle(fromURL: iden) ?? iden
        }
        handle = handle.hasPrefix("@") ? String(handle.dropFirst()) : handle

        // search.list by handle, then resolve to a channel id.
        let q = "@\(handle)"
        let data = try await get("search", ["part": "snippet", "q": q, "type": "channel", "maxResults": "10"])
        let search = try JSONDecoder().decode(SearchResponse.self, from: data)
        guard let firstID = search.items.compactMap({ $0.id.channelId }).first else {
            throw AggregatorError.contentFetch("Channel handle not found: @\(handle)")
        }
        return firstID
    }

    func fetchChannelData(_ channelID: String) async throws -> YouTubeChannelData {
        let data = try await get("channels", ["part": "contentDetails,snippet", "id": channelID])
        let resp = try JSONDecoder().decode(ChannelsResponse.self, from: data)
        guard let item = resp.items.first else { throw AggregatorError.contentFetch("Channel not found: \(channelID)") }
        let thumbs = item.snippet.thumbnails
        var custom = item.snippet.customUrl
        if let c = custom, !c.hasPrefix("@") { custom = "@\(c)" }
        return YouTubeChannelData(
            channelID: item.id,
            title: item.snippet.title ?? "",
            customURL: custom,
            uploadsPlaylistID: item.contentDetails?.relatedPlaylists?.uploads,
            iconURL: thumbs?.high?.url ?? thumbs?.medium?.url ?? thumbs?.defaultThumb?.url)
    }

    func fetchVideos(playlistID: String, max: Int) async throws -> [YouTubeVideo] {
        let data = try await get("playlistItems", ["part": "snippet,contentDetails",
                                                    "playlistId": playlistID, "maxResults": String(min(50, max))])
        let resp = try JSONDecoder().decode(PlaylistResponse.self, from: data)
        let ids = resp.items.compactMap { $0.contentDetails?.videoId }
        guard !ids.isEmpty else { return [] }
        return try await fetchVideoDetails(Array(ids.prefix(max)))
    }

    func fetchVideoDetails(_ ids: [String]) async throws -> [YouTubeVideo] {
        let data = try await get("videos", ["part": "snippet,statistics,contentDetails", "id": ids.joined(separator: ",")])
        let resp = try JSONDecoder().decode(VideosResponse.self, from: data)
        return resp.items.map { item in
            let t = item.snippet.thumbnails
            return YouTubeVideo(
                id: item.id,
                title: item.snippet.title ?? "",
                description: item.snippet.description ?? "",
                publishedAt: item.snippet.publishedAt.flatMap { ISO8601DateFormatter().date(from: $0) },
                thumbnailURL: t?.maxres?.url ?? t?.high?.url ?? t?.medium?.url)
        }
    }

    func fetchVideoComments(videoID: String, max: Int) async throws -> [YouTubeComment] {
        guard max > 0 else { return [] }
        let data = (try? await get("commentThreads", ["part": "snippet", "videoId": videoID,
                                                       "maxResults": String(min(100, max)),
                                                       "order": "relevance", "textFormat": "html"])) ?? Data("{}".utf8)
        let resp = (try? JSONDecoder().decode(CommentThreadsResponse.self, from: data)) ?? CommentThreadsResponse(items: [])
        return resp.items.compactMap { thread in
            let s = thread.snippet.topLevelComment.snippet
            guard let text = s.textDisplay, text != "[deleted]", text != "[removed]" else { return nil }
            return YouTubeComment(id: thread.id, author: s.authorDisplayName ?? "Unknown", textHTML: text)
        }.prefix(max).map { $0 }
    }

    static func searchChannels(query: String, apiKey: String,
                               fetch: @escaping Fetch = { try await HTTPClient.fetchJSON($0) }) async -> [YouTubeChannelResult] {
        guard !query.isEmpty, !apiKey.isEmpty else { return [] }
        let client = YouTubeClient(apiKey: apiKey, fetch: fetch)
        guard let data = try? await client.get("search", ["part": "id", "q": query, "type": "channel", "maxResults": "10"]),
              let search = try? JSONDecoder().decode(SearchResponse.self, from: data) else { return [] }
        let ids = search.items.compactMap { $0.id.channelId }
        guard !ids.isEmpty,
              let cData = try? await client.get("channels", ["part": "snippet", "id": ids.joined(separator: ",")]),
              let resp = try? JSONDecoder().decode(ChannelsResponse.self, from: cData) else { return [] }
        return resp.items.map {
            var custom = $0.snippet.customUrl
            if let c = custom, !c.hasPrefix("@") { custom = "@\(c)" }
            return YouTubeChannelResult(channelID: $0.id, title: $0.snippet.title ?? "", handle: custom)
        }
    }

    /// Minimal key check: a cheap `channels` lookup against a known public channel id.
    /// A valid key returns 2xx (items may be empty); an invalid key returns 400/403.
    /// Returns nil when the key is accepted.
    func verifyKey() async -> CredentialTestError? {
        do {
            _ = try await get("channels", ["part": "id", "id": "UCBR8-60-B28hp2BmDPdntcQ"])
            return nil
        } catch AggregatorError.articleSkip {
            return .invalidCredentials                       // 400 bad key / 403 forbidden / quota
        } catch is AggregatorError {
            return .network                                  // 5xx / size cap
        } catch {
            return .network                                  // transport (URLError) etc.
        }
    }

    // MARK: - Request + URL helpers

    private func get(_ endpoint: String, _ params: [String: String]) async throws -> Data {
        var comps = URLComponents(string: "\(Self.base)/\(endpoint)")!
        comps.queryItems = params.map { URLQueryItem(name: $0.key, value: $0.value) } + [URLQueryItem(name: "key", value: apiKey)]
        return try await fetch(URLRequest(url: comps.url!))
    }

    private func extractChannelID(fromURL url: String) -> String? {
        if let r = url.range(of: #"channel/(UC[A-Za-z0-9_-]+)"#, options: .regularExpression) {
            return String(url[r]).replacingOccurrences(of: "channel/", with: "")
        }
        return nil
    }
    private func extractHandle(fromURL url: String) -> String? {
        if let r = url.range(of: #"@([A-Za-z0-9_.-]+)"#, options: .regularExpression) {
            return String(url[r]).replacingOccurrences(of: "@", with: "")
        }
        return nil
    }
}

// MARK: - Decoding

private struct Thumbnails: Decodable {
    var maxres: Thumb?; var high: Thumb?; var medium: Thumb?; var defaultThumb: Thumb?
    struct Thumb: Decodable { var url: String? }
    enum CodingKeys: String, CodingKey { case maxres, high, medium, defaultThumb = "default" }
}
private struct SearchResponse: Decodable {
    var items: [Item]
    struct Item: Decodable { var id: ItemID }
    struct ItemID: Decodable { var channelId: String? }
}
private struct ChannelsResponse: Decodable {
    var items: [Item]
    struct Item: Decodable {
        var id: String
        var snippet: Snippet
        var contentDetails: ContentDetails?
    }
    struct Snippet: Decodable { var title: String?; var customUrl: String?; var thumbnails: Thumbnails? }
    struct ContentDetails: Decodable { var relatedPlaylists: Related? }
    struct Related: Decodable { var uploads: String? }
}
private struct PlaylistResponse: Decodable {
    var items: [Item]
    struct Item: Decodable { var contentDetails: CD? }
    struct CD: Decodable { var videoId: String? }
}
private struct VideosResponse: Decodable {
    var items: [Item]
    struct Item: Decodable { var id: String; var snippet: Snippet }
    struct Snippet: Decodable { var title: String?; var description: String?; var publishedAt: String?; var thumbnails: Thumbnails? }
}
private struct CommentThreadsResponse: Decodable {
    var items: [Item]
    struct Item: Decodable { var id: String; var snippet: Snippet }
    struct Snippet: Decodable { var topLevelComment: Top }
    struct Top: Decodable { var snippet: CommentSnippet }
    struct CommentSnippet: Decodable { var authorDisplayName: String?; var textDisplay: String? }
}
