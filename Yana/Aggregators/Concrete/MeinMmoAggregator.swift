import Foundation
import SwiftSoup

/// Mein-MMO.de gaming news. Ports core/aggregators/mein_mmo/: page-combining, embed strategies
/// (YouTube/Twitter/Reddit/Bluesky/TikTok), Dailymotion conversion, pagination-marker + recirculation removal.
class MeinMmoAggregator: FullWebsiteAggregator, @unchecked Sendable {
    static let defaultFeed = "https://mein-mmo.de/feed/"

    static let identifierChoices: [(value: String, label: String)] = [
        ("https://mein-mmo.de/feed/", "Main Feed (All Articles)"),
    ]

    var meinMmoOptions: MeinMmoOptions {
        if case .meinMmo(let o) = config.options { return o }
        return MeinMmoOptions()
    }

    /// Matches both the current theme (`div.entry-content`) and the legacy GeneratePress
    /// theme (`div.gp-entry-content`) Mein-MMO used before its redesign.
    static let contentDivSelector = "div.entry-content, div.gp-entry-content"

    override var contentSelector: String { Self.contentDivSelector }

    override var selectorsToRemove: [String] {
        // Dailymotion blocks (div.wp-block-mmo-video) are converted to a click-to-play facade by
        // convertDailymotionBlocks() before this pass — unlike the Yana server (commit 1e3afd3),
        // which builds div.dailymotion-embed-container and then strips it. The facade holds no live
        // <iframe> (the player markup lives in its data-embed attribute), so the iframe whitelist
        // below does not touch it; YouTube iframes are still preserved.
        ["div.wp-block-mmo-recirculation-box", "div.wp-block-mmo-hub-box",
         "div.reading-position-indicator-end",
         "label.toggle", "a.wp-block-mmo-content-box",
         // div.page-links is also the pagination container read by detectPagination().
         // This is safe only because detectPagination() is called inside enrich() BEFORE
         // processMeinMmoContent() (which runs selectorsToRemove). Do not reorder these calls.
         "div.page-links", "div.sources-wrapper", "div.feedback-box",
         "div.wp-block-wbd-affiliate-widget", "script", "style",
         "iframe:not([src*='youtube.com']):not([src*='youtu.be'])", "noscript"]
    }

    override func fetchEntries() async throws -> [FeedEntry] {
        let url = config.identifier.isEmpty ? Self.defaultFeed : config.identifier
        guard let u = URL(string: url) else { throw AggregatorError.missingIdentifier }
        let (data, _) = try await HTTPClient.fetchData(u)
        return try FeedParser.parse(data).entries
    }

    /// Overridable seam: JSON fetcher for Bluesky API calls (injectable for tests).
    func fetchJSONForBluesky(_ request: URLRequest) async throws -> Data {
        try await HTTPClient.fetchJSON(request)
    }

    /// Overridable seam: fetch an additional page of a multi-page article.
    func fetchAdditionalPage(_ url: String) async throws -> String {
        guard let u = URL(string: url) else { throw AggregatorError.contentFetch("bad page url") }
        return try await HTTPClient.fetchHTML(u)
    }

    override func enrich(_ article: AggregatedArticle, entry: FeedEntry) async throws -> AggregatedArticle {
        var article = article
        do {
            let first = try await fetchArticleHTML(article.url)
            article.rawContent = first
            let header = await HeaderElementExtractor.extract(
                articleURL: article.url, title: article.title, store: store,
                credentials: credentials, pageHTML: first)

            // Combine pages if enabled and pagination detected.
            var contentDivs: [String] = extractContentDivHTML(from: first).map { [$0] } ?? []
            if meinMmoOptions.combinePages {
                let pages = detectPagination(html: first)
                if pages.count > 1 {
                    contentDivs = []
                    for page in pages.sorted() {
                        let pageURL = page == 1 ? article.url : pageURLFor(base: article.url, page: page)
                        let html = page == 1 ? first : ((try? await fetchAdditionalPage(pageURL)) ?? "")
                        if let div = extractContentDivHTML(from: html) { contentDivs.append(div) }
                    }
                }
            }
            let merged = mergeContentDivs(contentDivs)
            let processed = try await processMeinMmoContent(merged, article: article, header: header)
            article.content = processed
            return article
        } catch let error as AggregatorError {
            if case .articleSkip = error { throw error }
            if Task.isCancelled { throw CancellationError() }   // cancelled run: don't persist feed-only content
            article.content = (try? await processContent(article.content, article: article, headerHTML: nil)) ?? ""
            return article
        } catch {
            if error.isCancellationError || Task.isCancelled { throw CancellationError() }
            article.content = (try? await processContent(article.content, article: article, headerHTML: nil)) ?? ""
            return article
        }
    }

    // MARK: - Pagination

    func detectPagination(html: String) -> Set<Int> {
        var pages: Set<Int> = [1]
        guard let doc = try? HTMLUtils.parse(html) else { return pages }
        let contentDiv = try? doc.select(Self.contentDivSelector).first()
        let inContent = (try? contentDiv?.select("div.page-links").first()).flatMap { $0 }
        let inDoc = (try? doc.select("div.page-links").first()).flatMap { $0 }
        let container = inContent ?? inDoc
        guard let pagination = container else { return pages }
        for link in (try? pagination.select("a.post-page-numbers").array()) ?? [] {
            if let text = try? link.text(), let n = Int(text) { pages.insert(n) }
            if let href = try? link.attr("href"),
               let r = href.range(of: #"/(\d+)/?$"#, options: .regularExpression),
               let n = Int(href[r].filter(\.isNumber)) { pages.insert(n) }
        }
        for span in (try? pagination.select("span.post-page-numbers").array()) ?? [] {
            if let text = try? span.text(), let n = Int(text) { pages.insert(n) }
        }
        return pages
    }

    private func pageURLFor(base: String, page: Int) -> String {
        base.hasSuffix("/") ? "\(base)\(page)/" : "\(base)/\(page)/"
    }

    private func extractContentDivHTML(from html: String) -> String? {
        guard let doc = try? HTMLUtils.parse(html),
              let div = try? doc.select(Self.contentDivSelector).first() else { return nil }
        return try? div.html()
    }

    private func mergeContentDivs(_ divs: [String]) -> String {
        "<div class=\"gp-entry-content\">\(divs.joined(separator: "\n\n"))</div>"
    }

    // MARK: - Content processing

    func processMeinMmoContent(_ html: String, article: AggregatedArticle, header: HeaderElement?) async throws -> String {
        let doc = try HTMLUtils.parse(html)
        guard let content = try doc.select(Self.contentDivSelector).first() ?? doc.body() else {
            return ""
        }

        // Dailymotion blocks → direct embed (before removal selectors strip leftovers).
        try convertDailymotionBlocks(content)

        // Remove unwanted elements.
        for selector in selectorsToRemove {
            for el in try content.select(selector) { try el.remove() }
        }

        // Remove "Weiter geht es auf Seite" pagination markers.
        for em in try content.select("em") where try em.text().contains("Weiter geht es auf Seite") {
            if let p = em.parent(), p.tagName() == "p" { try p.remove() } else { try em.remove() }
        }

        // Embed-processor strategies on <figure>.
        try await processEmbedFigures(content)

        try HTMLUtils.removeEmptyElements(doc, tags: ["p", "div"])
        try EmbedRewriter.rewriteEmbeds(in: doc)   // normalize any remaining YouTube iframes
        // Drop the lead image from the body when it's promoted to the header (avoids a dupe).
        if let dedup = header?.dedupURL { try? HTMLUtils.removeImageByURL(doc, url: dedup) }
        try await rewriteImages(in: doc, store: store, baseURL: URL(string: article.url))
        try HTMLUtils.sanitizeClassNames(doc)
        try HTMLUtils.removeComments(doc)
        let body = try HTMLUtils.bodyHTML(doc)
        return ContentFormatter.format(content: body, title: article.title, url: article.url,
                                       headerHTML: header?.html, commentsHTML: nil)
    }

    // Converts div.wp-block-mmo-video (Dailymotion player, dmVideoId in an inline script) into a
    // click-to-play facade. Runs before selectorsToRemove, which no longer strips the result.
    private func convertDailymotionBlocks(_ content: Element) throws {
        for block in try content.select("div.wp-block-mmo-video") {
            guard let id = dailymotionVideoID(block) else { continue }
            let container = parse(EmbedRewriter.dailymotionEmbedHTML(videoID: id))
            // Append the video title as a caption (text set via SwiftSoup so it is escaped).
            if let title = try? block.select("div.title").first()?.text(), !title.isEmpty {
                let caption = try container.appendElement("p").addClass("dailymotion-caption")
                try caption.text(title)
            }
            try block.replaceWith(container)
        }
    }

    private func dailymotionVideoID(_ block: Element) -> String? {
        for script in (try? block.select("script").array()) ?? [] {
            let text = (try? script.html()) ?? ""
            if let r = text.range(of: #"dmVideoId:\s*'([^']+)'"#, options: .regularExpression) {
                let match = String(text[r])
                if let idRange = match.range(of: #"'([^']+)'"#, options: .regularExpression) {
                    return String(match[idRange]).trimmingCharacters(in: CharacterSet(charactersIn: "'"))
                }
            }
        }
        return nil
    }

    /// Strategy chain over <figure>: YouTube (class/link) → Twitter → Reddit → Bluesky → TikTok → YouTube-link fallback.
    private func processEmbedFigures(_ content: Element) async throws {
        for figure in try content.select("figure").array() {
            let classStr = ((try? figure.classNames()) ?? []).joined(separator: " ")
            if classStr.contains("youtube") || classStr.contains("is-provider-youtube") {
                if let id = youTubeIDInFigure(figure) {
                    try figure.replaceWith(parse(EmbedRewriter.youTubeEmbedHTML(videoID: id))); continue
                }
            }
            if let twitter = linkMatching(figure, hosts: ["twitter.com", "x.com"]) {
                let clean = twitter.split(separator: "?").first.map(String.init) ?? twitter
                let link = "<p><a href=\"\(clean)\" target=\"_blank\" rel=\"noopener\">"
                    + "View on X/Twitter: \(clean)</a></p>"
                try figure.replaceWith(parse(link)); continue
            }
            if classStr.contains("provider-reddit") || classStr.contains("embed-reddit"),
               let reddit = linkMatching(figure, hosts: ["reddit.com"]) {
                let clean = reddit.split(separator: "?").first.map(String.init) ?? reddit
                try figure.replaceWith(parse("<p><a href=\"\(clean)\" target=\"_blank\" rel=\"noopener\">View on Reddit</a></p>")); continue
            }
            if let bsky = linkMatching(figure, hosts: ["bsky.app"]) {
                if let html = await BlueskyEmbed.buildEmbedHTML(for: bsky, fetchJSON: fetchJSONForBluesky) {
                    try figure.replaceWith(parse("<div data-sanitized-class=\"bluesky-embed\">\(html)</div>"))
                }
                // On failure, leave figure unchanged (graceful fallback).
                continue
            }
            if classStr.contains("tiktok"), let tiktok = linkMatching(figure, hosts: ["tiktok.com"]),
               let r = tiktok.range(of: #"/video/(\d+)"#, options: .regularExpression) {
                let id = String(tiktok[r]).filter(\.isNumber)
                let tiktokHTML = "<div data-sanitized-class=\"tiktok-embed\"><iframe "
                    + "src=\"https://www.tiktok.com/embed/v3/\(id)\" width=\"325\" height=\"605\" "
                    + "allowfullscreen allow=\"autoplay; encrypted-media\"></iframe></div>"
                try figure.replaceWith(parse(tiktokHTML)); continue
            }
            // Fallback: any YouTube link.
            if let id = youTubeIDInFigure(figure) {
                try figure.replaceWith(parse(EmbedRewriter.youTubeEmbedHTML(videoID: id)))
            }
        }
    }

    private func youTubeIDInFigure(_ figure: Element) -> String? {
        for link in (try? figure.select("a[href]").array()) ?? [] {
            if let href = try? link.attr("href"), let id = EmbedRewriter.extractYouTubeID(from: href) { return id }
        }
        return nil
    }

    private func linkMatching(_ figure: Element, hosts: [String]) -> String? {
        for link in (try? figure.select("a[href]").array()) ?? [] {
            if let href = try? link.attr("href"), hosts.contains(where: { href.contains($0) }) { return href }
        }
        return nil
    }

    private func parse(_ html: String) -> Element {
        if let parsed = try? SwiftSoup.parseBodyFragment(html).body()?.child(0) {
            return parsed
        }
        // Detached empty element — no throwing, no force-unwrap.
        return Element(SwiftSoup.Tag("span"), "")
    }
}
