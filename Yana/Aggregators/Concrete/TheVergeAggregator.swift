import Foundation
import SwiftSoup

/// The Verge (theverge.com) US tech/culture news. WordPress-backed with the Vox "Duet" design
/// system; the article body is `.duet--article--article-body-component`. The page also embeds
/// related/"stream" article bodies sharing that class, so we keep only the first (main-article)
/// block — the base `FullWebsiteAggregator` extraction already takes `.first()`.
class TheVergeAggregator: FullWebsiteAggregator, @unchecked Sendable {
    static let defaultFeed = "https://www.theverge.com/rss/index.xml"

    static let identifierChoices: [(value: String, label: String)] = [
        ("https://www.theverge.com/rss/index.xml", "Main Feed"),
    ]

    override var contentSelector: String { ".duet--article--article-body-component" }

    /// The page repeats `.duet--article--article-body-component` for related/"stream" stories, so
    /// extract only the first (main-article) block rather than the OR-union of all matches.
    override var usesFirstContentMatch: Bool { true }

    override var selectorsToRemove: [String] {
        ["script", "style", "noscript",
         "iframe:not([src*='youtube.com']):not([src*='youtu.be'])",
         "aside",
         "[class*='duet--recirculation']",
         "[class*='duet--ad']",
         "[class*='newsletter']"]
    }

    override func fetchEntries() async throws -> [FeedEntry] {
        let url = config.identifier.isEmpty ? Self.defaultFeed : config.identifier
        guard let u = URL(string: url) else { throw AggregatorError.missingIdentifier }
        let (data, _) = try await HTTPClient.fetchData(u)
        return try FeedParser.parse(data).entries
    }

    override func processFullContent(_ html: String, article: AggregatedArticle, header: HeaderElement?) async throws -> String {
        let doc = try HTMLUtils.parse(html)
        try HTMLUtils.removeEmptyElements(doc, tags: ["p", "div", "span"])
        try EmbedRewriter.rewriteEmbeds(in: doc)
        if let dedup = header?.dedupURL { _ = try? HTMLUtils.removeImageByURL(doc, url: dedup) }
        try await rewriteImages(in: doc, store: store, baseURL: URL(string: article.url))
        try HTMLUtils.sanitizeClassNames(doc)
        try HTMLUtils.removeComments(doc)
        let body = try HTMLUtils.bodyHTML(doc)
        return ContentFormatter.format(content: body, title: article.title, url: article.url,
                                       headerHTML: header?.html, commentsHTML: nil)
    }
}
