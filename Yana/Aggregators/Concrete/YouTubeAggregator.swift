import Foundation

/// YouTube aggregator. Conforms to `Aggregator` directly (API-based, not an RSS pipeline).
/// Resolves channel → uploads playlist → video details → comments, then builds an article whose
/// content is a YouTube embed + the (escaped) video description + comment blockquotes, wrapped
/// via `ContentFormatter.format`.
final class YouTubeAggregator: Aggregator, @unchecked Sendable {
    private let config: FeedConfig
    private let credentials: AggregatorCredentials
    private let injectedClient: YouTubeClient?

    init(config: FeedConfig, credentials: AggregatorCredentials, client: YouTubeClient? = nil) {
        self.config = config
        self.credentials = credentials
        self.injectedClient = client
    }

    private var options: YouTubeOptions {
        if case .youtube(let o) = config.options { return o }
        return YouTubeOptions()
    }

    func validate() throws {
        guard !config.identifier.trimmingCharacters(in: .whitespaces).isEmpty else {
            throw AggregatorError.missingIdentifier
        }
        guard credentials.youtubeAPIKey != nil else {
            throw AggregatorError.missingAPIKey(.youtube)
        }
    }

    func aggregate() async throws -> [AggregatedArticle] {
        var result: [AggregatedArticle] = []
        try await aggregate { result.append($0) }
        return result
    }

    /// Streaming form: build one video at a time (comments + content) and hand each finished
    /// article to `sink` before fetching the next, so the caller can persist it immediately.
    /// An interrupted run keeps every video already handed off. (`aggregate()` collects it.)
    func aggregate(_ sink: sending (AggregatedArticle) async throws -> Void) async throws {
        try validate()
        let client = try makeClient()
        let limit = max(config.dailyLimit, 1)

        let channelID = try await client.resolveChannelID(config.identifier)
        let channel = try await client.fetchChannelData(channelID)
        guard let uploads = channel.uploadsPlaylistID else {
            throw AggregatorError.contentFetch("Channel has no uploads playlist: \(channelID)")
        }

        let videos = try await client.fetchVideos(playlistID: uploads, max: limit)
        let author = channel.customURL ?? channel.title
        for video in videos {
            if Task.isCancelled { break }                 // cancelled run: stop, keeping handed-off videos
            let url = "https://www.youtube.com/watch?v=\(video.id)"
            let comments = (try? await client.fetchVideoComments(videoID: video.id, max: options.commentLimit)) ?? []
            let body = buildContentHTML(video: video, videoID: video.id, comments: comments)
            let embed = EmbedRewriter.youTubeEmbedHTML(videoID: video.id)
            let content = formatContent(embed: embed, body: body, title: video.title, url: url)
            try await sink(AggregatedArticle(
                title: video.title, identifier: url, url: url,
                rawContent: body, content: content,
                date: video.publishedAt ?? Date(), author: author, iconURL: video.thumbnailURL))
        }
    }

    func refetch(_ seed: AggregatedArticle) async throws -> AggregatedArticle? {
        guard let videoID = EmbedRewriter.extractYouTubeID(from: seed.url) else { return nil }
        let client = try makeClient()
        guard let video = try await client.fetchVideoDetails([videoID]).first else { return nil }
        let url = "https://www.youtube.com/watch?v=\(video.id)"
        let comments = (try? await client.fetchVideoComments(videoID: video.id, max: options.commentLimit)) ?? []
        let body = buildContentHTML(video: video, videoID: video.id, comments: comments)
        let embed = EmbedRewriter.youTubeEmbedHTML(videoID: video.id)
        let content = formatContent(embed: embed, body: body, title: video.title, url: url)
        return AggregatedArticle(
            title: video.title, identifier: url, url: url,
            rawContent: body, content: content,
            date: video.publishedAt ?? Date(), author: seed.author, iconURL: video.thumbnailURL)
    }

    func logoImageURL() async -> String? {
        guard credentials.youtubeAPIKey != nil else { return nil }
        guard let client = try? makeClient() else { return nil }
        guard let channelID = try? await client.resolveChannelID(config.identifier),
              let channel = try? await client.fetchChannelData(channelID) else { return nil }
        return channel.iconURL
    }

    // MARK: - Content building

    /// Wrap the assembled embed + body, running it through the shared sanitization tail first
    /// (mirroring the RSS pipeline's `processContent`). `finishSanitization` stamps the YouTube
    /// facade's classes into `data-sanitized-class`, which is what `BlockParser.embedFacade` keys
    /// on to render a tappable, playable poster — without it the facade degrades to a bare,
    /// inert thumbnail image (no play button, no tap). On a parse failure we fall back to the
    /// unsanitized markup so an article is never dropped.
    private func formatContent(embed: String, body: String, title: String, url: String) -> String {
        let merged = embed + body
        let sanitized: String
        if let doc = try? HTMLUtils.parse(merged), (try? HTMLUtils.finishSanitization(doc)) != nil,
           let html = try? HTMLUtils.bodyHTML(doc) {
            sanitized = html
        } else {
            sanitized = merged
        }
        return ContentFormatter.format(content: sanitized, title: title, url: url,
                                       headerHTML: nil, commentsHTML: nil)
    }

    private func buildContentHTML(video: YouTubeVideo, videoID: String, comments: [YouTubeComment]) -> String {
        var parts: [String] = []

        // Video description is PLAIN TEXT from the API and channel-owner-controlled. Escape it
        // before inserting into the JS-enabled WKWebView (stored-XSS guard), then turn the
        // remaining newlines into the <br> tags we just added.
        let description = video.description.trimmingCharacters(in: .whitespacesAndNewlines)
        if !description.isEmpty {
            let formatted = escape(description).replacingOccurrences(of: "\n", with: "<br>")
            parts.append("<div class=\"youtube-description\">\(formatted)</div>")
        }

        var html = parts.joined()

        if !comments.isEmpty {
            html += "<div class=\"youtube-comments\"><h3>\(String(localized: "Comments"))</h3>"
            for c in comments {
                // c.textHTML comes from the API with textFormat=html and is server-side
                // sanitized by YouTube (safe tags only: <br>, <a>, <b>). Insert as trusted raw
                // HTML to preserve formatting. The author is user-controlled → escape it.
                let url = "https://www.youtube.com/watch?v=\(videoID)&lc=\(c.id)"
                html += """
                <blockquote>
                <p><strong>\(escape(c.author))</strong> | <a href="\(url)" target="_blank" rel="noopener">\(String(localized: "source"))</a></p>
                <div>\(c.textHTML)</div>
                </blockquote>
                """
            }
            html += "</div>"
        }

        return html
    }

    private func escape(_ text: String) -> String {
        text.replacingOccurrences(of: "&", with: "&amp;")
            .replacingOccurrences(of: "<", with: "&lt;")
            .replacingOccurrences(of: ">", with: "&gt;")
    }

    private func makeClient() throws -> YouTubeClient {
        if let injectedClient { return injectedClient }
        guard let key = credentials.youtubeAPIKey else { throw AggregatorError.missingAPIKey(.youtube) }
        return YouTubeClient(apiKey: key)
    }
}
