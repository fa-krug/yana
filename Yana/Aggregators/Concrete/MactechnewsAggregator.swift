import Foundation
import SwiftSoup

/// MacTechNews (mactechnews.de). Ports core/aggregators/mactechnews/aggregator.py:
/// forced News feed, `.MtnArticle` content, numeric-image-ID dedup, relative-URL resolution.
class MactechnewsAggregator: FullWebsiteAggregator, @unchecked Sendable {
    static let forcedFeed = "https://www.mactechnews.de/Rss/News.x"

    static let identifierChoices: [(value: String, label: String)] = []   // forced, no choices

    /// The feed is forced (`forcedFeed`), so `config.identifier` is irrelevant and not required.
    override func validate() throws {}

    override var contentSelector: String { ".MtnArticle" }

    override var selectorsToRemove: [String] {
        [".NewsPictureMobile", "aside", "script", "style", "iframe", "noscript", "svg",
         "header", ".TexticonBox.Right"]
    }

    /// Overridable seam for tests to inject feed data.
    func fetchFeedData(_ url: String) async throws -> Data {
        guard let u = URL(string: url) else { throw AggregatorError.missingIdentifier }
        return try await HTTPClient.fetchData(u).data
    }

    override func fetchEntries() async throws -> [FeedEntry] {
        let data = try await fetchFeedData(Self.forcedFeed)   // identifier is ignored — feed forced
        return try FeedParser.parse(data).entries
    }

    /// The header image URL for dedup, normally discovered from the page's og:image.
    /// Overridable so tests can supply it directly.
    func makeHeaderImageURL(forPage html: String) -> String? {
        guard let doc = try? HTMLUtils.parse(html),
              let meta = try? doc.select("meta[property=og:image]").first(),
              let content = try? meta.attr("content"), !content.isEmpty else { return nil }
        return content
    }

    static func extractImageID(_ url: String) -> String? {
        guard let r = url.range(of: #"\.(\d{5,})\.\w+$"#, options: .regularExpression) else { return nil }
        let match = String(url[r])
        if let idRange = match.range(of: #"\d{5,}"#, options: .regularExpression) {
            return String(match[idRange])
        }
        return nil
    }

    override func processFullContent(_ html: String, article: AggregatedArticle, header: HeaderElement?) async throws -> String {
        let doc = try HTMLUtils.parse(html)
        let base = URL(string: article.url)

        // Numeric-image-ID dedup against the header image.
        if let headerURL = makeHeaderImageURL(forPage: article.rawContent),
           let headerID = Self.extractImageID(headerURL) {
            for img in try doc.select("img") {
                let src = try img.attr("src")
                if !src.isEmpty, Self.extractImageID(src) == headerID { try img.remove() }
            }
        }

        // Resolve relative URLs.
        for img in try doc.select("img") {
            let src = try img.attr("src")
            if !src.isEmpty, !src.hasPrefix("http://"), !src.hasPrefix("https://"), !src.hasPrefix("data:") {
                if let abs = URL(string: src, relativeTo: base)?.absoluteString { try img.attr("src", abs) }
            }
        }
        for a in try doc.select("a") {
            let href = try a.attr("href")
            if !href.isEmpty, !["http://", "https://", "mailto:", "tel:", "#"].contains(where: { href.hasPrefix($0) }) {
                if let abs = URL(string: href, relativeTo: base)?.absoluteString { try a.attr("href", abs) }
            }
        }

        try EmbedRewriter.rewriteEmbeds(in: doc)
        if let dedup = header?.dedupURL { try? HTMLUtils.removeImageByURL(doc, url: dedup) }
        try await rewriteImages(in: doc, store: store, baseURL: base)
        try HTMLUtils.sanitizeClassNames(doc)
        try HTMLUtils.removeComments(doc)
        let body = try HTMLUtils.bodyHTML(doc)
        return ContentFormatter.format(content: body, title: article.title, url: article.url,
                                       headerHTML: header?.html, commentsHTML: nil)
    }
}
