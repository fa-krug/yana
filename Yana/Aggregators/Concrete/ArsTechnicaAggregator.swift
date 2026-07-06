import Foundation
import SwiftSoup

/// Ars Technica (arstechnica.com) US tech/science news. Multi-"page" articles are served whole in a
/// single fetch as sibling `div.post-content` blocks separated by `<a data-page="N">` trackers (the
/// `/N/` URLs are same-page `#page-N` anchors). Even single-page articles split into multiple
/// `.post-content` blocks, so we merge ALL of them — the base extraction keeps only `.first()`,
/// which would truncate the article.
class ArsTechnicaAggregator: FullWebsiteAggregator, @unchecked Sendable {
    static let defaultFeed = "https://arstechnica.com/feed/"

    static let identifierChoices: [(value: String, label: String)] = [
        ("https://arstechnica.com/feed/", "Main Feed"),
        ("https://arstechnica.com/gadgets/feed/", "Gadgets"),
        ("https://arstechnica.com/science/feed/", "Science"),
        ("https://arstechnica.com/gaming/feed/", "Gaming"),
    ]

    override var contentSelector: String { ".post-content" }

    override var selectorsToRemove: [String] {
        [".ad", "[class*='ad-wrapper']", ".ad--mid-content", ".ad--rail",
         ".social-share", "aside", "script", "style", "noscript",
         "iframe:not([src*='youtube.com']):not([src*='youtu.be'])"]
    }

    override func fetchEntries() async throws -> [FeedEntry] {
        let url = config.identifier.isEmpty ? Self.defaultFeed : config.identifier
        guard let u = URL(string: url) else { throw AggregatorError.missingIdentifier }
        let (data, _) = try await HTTPClient.fetchData(u)
        return try FeedParser.parse(data).entries
    }

    /// Merge every `.post-content` block in the fetched page into one wrapped HTML string
    /// (document order). Returns nil when none are present so the caller falls back to RSS content.
    func mergedContentHTML(from pageHTML: String) -> String? {
        guard let doc = try? HTMLUtils.parse(pageHTML) else { return nil }
        let blocks = (try? doc.select(".post-content").array()) ?? []
        let inner = blocks.compactMap { try? $0.html() }.filter { !$0.isEmpty }
        guard !inner.isEmpty else { return nil }
        return "<div class=\"post-content\">\(inner.joined(separator: "\n\n"))</div>"
    }

    /// Like the base enrich, but sources content from the merged in-page blocks instead of the
    /// single `.first()` match. Keeps the base's RSS/cancellation fallback shape.
    override func enrich(_ article: AggregatedArticle, entry: FeedEntry) async throws -> AggregatedArticle {
        var article = article
        do {
            let raw = try await fetchArticleHTML(article.url)
            article.rawContent = raw
            let header = await HeaderElementExtractor.extract(
                articleURL: article.url, title: article.title, store: store,
                credentials: credentials, pageHTML: raw)
            guard let merged = mergedContentHTML(from: raw) else {
                article.content = try await processContent(article.content, article: article, headerHTML: nil)
                return article
            }
            let extracted = try HTMLUtils.extractMainContent(merged, selector: ".post-content",
                                                             removeSelectors: selectorsToRemove)
            article.content = try await processFullContent(extracted, article: article, header: header)
            return article
        } catch let error as AggregatorError {
            if case .articleSkip = error { throw error }
            if Task.isCancelled { throw CancellationError() }
            article.content = (try? await processContent(article.content, article: article, headerHTML: nil)) ?? ""
            return article
        } catch {
            if error.isCancellationError || Task.isCancelled { throw CancellationError() }
            article.content = (try? await processContent(article.content, article: article, headerHTML: nil)) ?? ""
            return article
        }
    }

    override func processFullContent(_ html: String, article: AggregatedArticle, header: HeaderElement?) async throws -> String {
        let doc = try HTMLUtils.parse(html)
        try HTMLUtils.removeEmptyElements(doc, tags: ["p", "div", "span"])
        try EmbedRewriter.rewriteEmbeds(in: doc)
        if let dedup = header?.dedupURL { try? HTMLUtils.removeImageByURL(doc, url: dedup) }
        try await rewriteImages(in: doc, store: store, baseURL: URL(string: article.url))
        try HTMLUtils.sanitizeClassNames(doc)
        try HTMLUtils.removeComments(doc)
        let body = try HTMLUtils.bodyHTML(doc)
        return ContentFormatter.format(content: body, title: article.title, url: article.url,
                                       headerHTML: header?.html, commentsHTML: nil)
    }
}
