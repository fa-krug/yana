import Foundation
import SwiftSoup

/// Reddit aggregator (application-only OAuth). Conforms to `Aggregator` directly (API-based,
/// not an RSS pipeline). Reproduces the server's post content + comments + header-image shape.
final class RedditAggregator: Aggregator, @unchecked Sendable {
    private let config: FeedConfig
    private let credentials: AggregatorCredentials
    private let store: ImageStore
    private let injectedClient: RedditClient?

    init(config: FeedConfig, credentials: AggregatorCredentials, store: ImageStore = .shared,
         client: RedditClient? = nil) {
        self.config = config
        self.credentials = credentials
        self.store = store
        self.injectedClient = client
    }

    private var options: RedditOptions {
        if case .reddit(let o) = config.options { return o }
        return RedditOptions()
    }

    func validate() throws {
        guard !normalizedSubreddit.isEmpty else { throw AggregatorError.missingIdentifier }
        guard credentials.redditClientID != nil, credentials.redditClientSecret != nil else {
            throw AggregatorError.missingAPIKey(.reddit)
        }
    }

    func aggregate() async throws -> [AggregatedArticle] {
        try validate()
        let client = try await makeClient()
        let opts = options
        let limit = max(config.dailyLimit, 1)
        let fetchLimit = min(limit * 3, 100)

        let posts = try await client.fetchListing(subreddit: normalizedSubreddit, sort: opts.subredditSort, limit: fetchLimit)
        let cutoff = Date().addingTimeInterval(-Double(opts.minAgeHours) * 3600)
        let twoMonths = Date().addingTimeInterval(-60 * 24 * 3600)

        var result: [AggregatedArticle] = []
        for post in posts {
            let original = post.crosspostParentList?.first ?? post
            let date = Date(timeIntervalSince1970: original.createdUTC)
            if date < twoMonths { continue }
            if opts.minAgeHours > 0 && date > cutoff { continue }
            if post.author == "AutoModerator" { continue }
            if opts.minComments > 0 && post.numComments < opts.minComments { continue }
            if result.count >= limit { break }

            let permalink = "https://reddit.com\(RedditMarkdown.decodeEntities(original.permalink))"
            let isCrossPost = post.crosspostParentList?.isEmpty == false
            var body = try await buildContent(post: original, isCrossPost: isCrossPost, client: client)
            let headerURL = headerImageURL(for: original)

            if let headerURL { body = stripImage(from: body, url: headerURL) }
            var headerHTML: String?
            if opts.includeHeaderImage, let headerURL {
                headerHTML = try await makeHeaderHTML(headerURL, title: original.title)
            }
            let content = ContentFormatter.format(content: body, title: original.title, url: permalink,
                                                  headerHTML: headerHTML, commentsHTML: nil)
            result.append(AggregatedArticle(
                title: original.title, identifier: permalink, url: permalink,
                rawContent: body, content: content,
                date: date, author: post.author, iconURL: nil))
        }
        return result
    }

    func logoImageURL() async -> String? {
        guard let client = try? await makeClient() else { return nil }
        return await client.fetchSubredditAbout(normalizedSubreddit)
    }

    // MARK: - Content building (ports reddit/content.py)

    private func buildContent(post: RedditPostData, isCrossPost: Bool, client: RedditClient) async throws -> String {
        var parts: [String] = []
        if !post.selftext.isEmpty { parts.append("<div>\(RedditMarkdown.toHTML(post.selftext))</div>") }
        addGalleryMedia(post, &parts)
        addLinkMedia(post, &parts, isCrossPost: isCrossPost)
        try await addComments(post, &parts, client: client)
        return parts.joined()
    }

    private func addGalleryMedia(_ post: RedditPostData, _ parts: inout [String]) {
        guard post.isGallery, let meta = post.mediaMetadata, let gallery = post.galleryData else { return }
        for item in gallery.items {
            guard let mid = item.mediaID, let info = meta[mid] else { continue }
            let animated = info.e == "AnimatedImage"
            let raw = animated ? (info.s?.gif ?? info.s?.mp4) : (info.e == "Image" ? info.s?.u : nil)
            guard let raw else { continue }
            let url = RedditMarkdown.decodeEntities(raw)
            let alt = item.caption.map { RedditMarkdown.escape($0) } ?? (animated ? "Animated GIF" : "Gallery image")
            if let caption = item.caption, !caption.isEmpty {
                parts.append("<figure><img src=\"\(url)\" alt=\"\(alt)\"><figcaption>\(alt)</figcaption></figure>")
            } else {
                parts.append("<p><img src=\"\(url)\" alt=\"\(alt)\"></p>")
            }
        }
    }

    private func addLinkMedia(_ post: RedditPostData, _ parts: inout [String], isCrossPost: Bool) {
        guard !post.url.isEmpty, !post.isGallery else { return }
        let url = RedditMarkdown.decodeEntities(post.url)
        let lower = url.lowercased()
        if lower.hasSuffix(".gif") || lower.hasSuffix(".gifv") {
            let gif = lower.hasSuffix(".gifv") ? String(url.dropLast()) : url
            parts.append("<p><img src=\"\(gif)\" alt=\"Animated GIF\"></p>"); return
        }
        let isImage = [".jpg", ".jpeg", ".png", ".webp"].contains { lower.contains($0) } || lower.contains("i.redd.it")
        if isImage {
            parts.append("<p><a href=\"\(url)\" target=\"_blank\" rel=\"noopener\">\(RedditMarkdown.escape(url))</a></p>"); return
        }
        if lower.contains("v.redd.it") { return }            // handled in header
        if lower.contains("youtube.com") || lower.contains("youtu.be") {
            parts.append("<p><a href=\"\(url)\" target=\"_blank\" rel=\"noopener\">▶ View Video on YouTube</a></p>"); return
        }
        if lower.contains("twitter.com") || lower.contains("x.com") { return }   // header embed
        if !isCrossPost && !post.isSelf {
            parts.append("<p><a href=\"\(url)\" target=\"_blank\" rel=\"noopener\">\(RedditMarkdown.escape(url))</a></p>")
        }
    }

    private func addComments(_ post: RedditPostData, _ parts: inout [String], client: RedditClient) async throws {
        let permalink = "https://reddit.com\(RedditMarkdown.decodeEntities(post.permalink))"
        var section = ["<h3><a href=\"\(permalink)\" target=\"_blank\" rel=\"noopener\">Comments</a></h3>"]
        let limit = options.commentLimit
        if limit > 0 {
            let comments = (try? await client.fetchComments(subreddit: normalizedSubreddit, postID: post.id)) ?? []
            if comments.isEmpty {
                section.append("<p><em>No comments yet.</em></p>")
            } else {
                section.append(comments.prefix(limit).map(commentHTML).joined())
            }
        } else {
            section.append("<p><em>Comments disabled.</em></p>")
        }
        parts.append("<section>\(section.joined())</section>")
    }

    private func commentHTML(_ comment: RedditComment) -> String {
        let author = comment.author.isEmpty ? "[deleted]" : comment.author
        let body = RedditMarkdown.toHTML(comment.body)
        let url = "https://reddit.com\(comment.permalink)"
        return """
        <blockquote>
        <p><strong>\(RedditMarkdown.escape(author))</strong> | <a href="\(url)" target="_blank" rel="noopener">source</a></p>
        <div>\(body)</div>
        </blockquote>
        """
    }

    // MARK: - Header image (ports reddit/images.py priority chain, minus link-page scraping)

    /// Returns true if `url` is a Twitter/X status URL (mirrors server's `is_twitter_url`).
    private func isTwitterURL(_ url: String) -> Bool {
        guard let components = URLComponents(string: url),
              let host = components.host?.lowercased() else { return false }
        let isTwitterHost = host == "twitter.com" || host == "www.twitter.com"
            || host == "mobile.twitter.com"
            || host == "x.com" || host == "www.x.com"
        return isTwitterHost && components.path.contains("/status/")
    }

    private func headerImageURL(for post: RedditPostData) -> String? {
        // Priority 0 (highest): domain image override wins over all other strategies.
        if !post.url.isEmpty, let overrideURL = DomainImageOverrides.overrideImageURL(for: post.url) {
            return overrideURL
        }
        // YouTube videos embed via header strategy elsewhere; here we surface direct images.
        if !post.url.isEmpty, EmbedRewriter.extractYouTubeID(from: post.url) != nil {
            return RedditMarkdown.decodeEntities(post.url)
        }
        // Priority 0.6: Twitter/X URL in selftext (return URL for header embed)
        if post.isSelf, !post.selftext.isEmpty {
            let detector = try? NSDataDetector(types: NSTextCheckingResult.CheckingType.link.rawValue)
            let range = NSRange(post.selftext.startIndex..<post.selftext.endIndex, in: post.selftext)
            let matches = detector?.matches(in: post.selftext, range: range) ?? []
            for match in matches {
                guard let url = match.url?.absoluteString else { continue }
                if isTwitterURL(url) { return url }
            }
        }
        // Gallery first image
        if post.isGallery, let meta = post.mediaMetadata, let first = post.galleryData?.items.first,
           let mid = first.mediaID, let info = meta[mid] {
            if info.e == "AnimatedImage", let raw = info.s?.gif ?? info.s?.mp4 { return RedditMarkdown.decodeEntities(raw) }
            if info.e == "Image", let raw = info.s?.u { return RedditMarkdown.decodeEntities(raw) }
        }
        // Direct image post
        if !post.url.isEmpty {
            let decoded = RedditMarkdown.decodeEntities(post.url)
            let lower = decoded.lowercased()
            let isDirect = [".jpg", ".jpeg", ".png", ".webp", ".gif", ".gifv"].contains { lower.contains($0) }
                || lower.contains("i.redd.it")
            if isDirect { return decoded }
        }
        // Preview source
        if let src = post.preview?.images.first?.source?.url {
            return RedditMarkdown.decodeEntities(src)
        }
        // Thumbnail fallback
        if let thumb = post.thumbnail, thumb.hasPrefix("http"),
           !["self", "default", "nsfw", "spoiler"].contains(thumb) {
            return RedditMarkdown.decodeEntities(thumb)
        }
        return nil
    }

    private func makeHeaderHTML(_ url: String, title: String) async throws -> String {
        // YouTube / Twitter headers embed; here we localize a direct image.
        if let id = EmbedRewriter.extractYouTubeID(from: url) {
            return "<header style=\"margin-bottom: 1.5em;\">\(EmbedRewriter.youTubeEmbedHTML(videoID: id))</header>"
        }
        if isTwitterURL(url), let html = await EmbedRewriter.tweetEmbedHTML(for: url) {
            return "<header style=\"margin-bottom: 1.5em;\">\(html)</header>"
        }
        guard let remote = URL(string: url), let hash = await store.store(remoteURL: remote, isHeader: true) else {
            return ""
        }
        return ContentFormatter.headerImageHTML(src: "\(ReaderWeb.imageScheme)://\(hash)", alt: title)
    }

    private func stripImage(from html: String, url: String) -> String {
        guard let doc = try? HTMLUtils.parse(html) else { return html }
        try? HTMLUtils.removeImageByURL(doc, url: url)
        // Also drop a bare anchor whose href equals the header url (direct-image link posts).
        if let anchors = try? doc.select("a[href]") {
            for a in anchors where (try? a.attr("href")) == url { try? a.remove() }
        }
        return (try? HTMLUtils.bodyHTML(doc)) ?? html
    }

    // MARK: - Helpers

    private var normalizedSubreddit: String {
        var id = config.identifier.trimmingCharacters(in: .whitespaces)
        if let r = id.range(of: #"(?:reddit\.com)?/?r/(\w+)"#, options: .regularExpression) {
            let match = String(id[r])
            if let nameRange = match.range(of: #"\w+$"#, options: .regularExpression) { return String(match[nameRange]) }
        }
        if id.hasPrefix("/r/") { id = String(id.dropFirst(3)) } else if id.hasPrefix("r/") { id = String(id.dropFirst(2)) }
        return id.split(whereSeparator: { $0 == "/" || $0 == ":" || $0 == " " }).first.map(String.init) ?? id
    }

    private func makeClient() async throws -> RedditClient {
        if let injectedClient { return injectedClient }
        guard let id = credentials.redditClientID, let secret = credentials.redditClientSecret else {
            throw AggregatorError.missingAPIKey(.reddit)
        }
        let userAgent = await MainActor.run { AppSettings().redditUserAgent }
        return RedditClient(clientID: id, clientSecret: secret, userAgent: userAgent)
    }
}
