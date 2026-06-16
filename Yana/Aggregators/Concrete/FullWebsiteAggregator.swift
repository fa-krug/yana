import Foundation
import SwiftSoup

/// Fetches the article page and extracts main content via CSS selectors, hoisting a header
/// element and downloading images. Scrapers (4d) subclass this and override the selectors/hooks.
class FullWebsiteAggregator: RSSPipelineAggregator, @unchecked Sendable {
    override var contentSelector: String { "article, .article-content, .entry-content, main" }
    override var selectorsToRemove: [String] {
        ["script", "style",
         "iframe:not([src*='youtube.com']):not([src*='youtu.be'])",
         "noscript", ".advertisement", ".ad", ".social-share"]
    }

    /// Overridable for tests.
    func fetchArticleHTML(_ url: String) async throws -> String {
        guard let u = URL(string: url) else { throw AggregatorError.missingIdentifier }
        return try await HTTPClient.fetchHTML(u)
    }

    /// The `WebsiteOptions` for this run (scrapers may have their own options; default to RSS-only behavior).
    var websiteOptions: WebsiteOptions {
        if case .fullWebsite(let o) = config.options { return o }
        return WebsiteOptions()
    }

    override func enrich(_ article: AggregatedArticle, entry: FeedEntry) async throws -> AggregatedArticle {
        var article = article
        let opts = websiteOptions
        guard opts.useFullContent else {
            // Keep RSS summary, still localize images + embeds.
            article.content = try await processContent(article.content, article: article, headerHTML: nil)
            return article
        }
        do {
            let header = await HeaderElementExtractor.extract(
                articleURL: article.url, title: article.title, store: store, credentials: credentials)
            let raw = try await fetchArticleHTML(article.url)
            article.rawContent = raw

            let selector = opts.customContentSelector.isEmpty ? contentSelector : opts.customContentSelector
            var removeSelectors = selectorsToRemove
            if !opts.customSelectorsToRemove.isEmpty {
                removeSelectors += opts.customSelectorsToRemove.split(separator: ",")
                    .map { $0.trimmingCharacters(in: .whitespaces) }.filter { !$0.isEmpty }
            }
            let extracted = try HTMLUtils.extractMainContent(raw, selector: selector, removeSelectors: removeSelectors)
            article.content = try await processFullContent(extracted, article: article, header: header)
            return article
        } catch let error as AggregatorError {
            if case .articleSkip = error { throw error }   // propagate 4xx skip to caller
            // Other errors: fall back to RSS content, but still localize images (decision 3).
            article.content = (try? await processContent(article.content, article: article, headerHTML: nil)) ?? ""
            return article
        } catch {
            article.content = (try? await processContent(article.content, article: article, headerHTML: nil)) ?? ""
            return article
        }
    }

    /// Like base processContent but de-dups the header image from the body and prepends the header.
    func processFullContent(_ html: String, article: AggregatedArticle, header: HeaderElement?) async throws -> String {
        let doc = try HTMLUtils.parse(html)
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
