import Foundation
import SwiftSoup

/// Fetches the article page and extracts main content via CSS selectors, hoisting a header
/// element and downloading images. Scrapers (4d) subclass this and override the selectors/hooks.
class FullWebsiteAggregator: RSSPipelineAggregator, @unchecked Sendable {
    override var contentSelector: String { WebsiteOptions.defaultContentSelectors.joined(separator: ", ") }
    /// Mandatory security/sanitization removals, always applied regardless of the user's ignore
    /// list. Editorial-noise selectors (.advertisement/.ad/.social-share) now live in the
    /// user-editable `WebsiteOptions.ignoreSelectors` defaults instead.
    override var selectorsToRemove: [String] {
        ["script", "style",
         "iframe:not([src*='youtube.com']):not([src*='youtu.be'])",
         "noscript"]
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
        do {
            let raw = try await fetchArticleHTML(article.url)
            article.rawContent = raw
            let header = await HeaderElementExtractor.extract(
                articleURL: article.url, title: article.title, store: store,
                credentials: credentials, pageHTML: raw)

            // Fall back to the built-in defaults when the user cleared the content list entirely.
            let contentSelectors = opts.contentSelectors.isEmpty
                ? WebsiteOptions.defaultContentSelectors : opts.contentSelectors
            // Always-applied security removals + the user's editable ignore list.
            let removeSelectors = selectorsToRemove + opts.ignoreSelectors
            let extracted = try HTMLUtils.extractMainContent(raw, contentSelectors: contentSelectors, removeSelectors: removeSelectors)
            article.content = try await processFullContent(extracted, article: article, header: header)
            return article
        } catch let error as AggregatorError {
            if case .articleSkip = error { throw error }   // propagate 4xx skip to caller
            if Task.isCancelled { throw CancellationError() }   // cancelled run: don't persist degraded content
            // Other errors: fall back to RSS content, but still localize images (decision 3).
            article.content = (try? await processContent(article.content, article: article, headerHTML: nil)) ?? ""
            return article
        } catch {
            // A cancelled run (e.g. an expired background-refresh window) surfaces here as
            // URLError.cancelled / CancellationError. Falling back to RSS feed content would
            // persist a feed-only article masquerading as the full scrape (the user then sees
            // "just the feed content" until a manual reload); rethrow so the run stops cleanly.
            if error.isCancellationError || Task.isCancelled { throw CancellationError() }
            article.content = (try? await processContent(article.content, article: article, headerHTML: nil)) ?? ""
            return article
        }
    }

    /// Re-fetch one known article by re-running the per-article enrich path on its URL.
    /// `enrich` is fully URL-driven here, so the (unused) `entry` is a throwaway.
    override func refetch(_ seed: AggregatedArticle) async throws -> AggregatedArticle? {
        try await enrich(seed, entry: FeedEntry())
    }

    /// Like base processContent but de-dups the header image from the body and prepends the header.
    func processFullContent(_ html: String, article: AggregatedArticle, header: HeaderElement?) async throws -> String {
        let doc = try HTMLUtils.parse(html)
        // The reader shows the title as its masthead; drop a duplicate headline at the top of the body.
        try? HTMLUtils.removeDuplicateTitleHeading(doc, title: article.title)
        try EmbedRewriter.rewriteEmbeds(in: doc)
        if let dedup = header?.dedupURL { try? HTMLUtils.removeImageByURL(doc, url: dedup) }
        try HTMLUtils.removeUnsafeTags(doc)
        try HTMLUtils.removeTrackingPixels(doc)
        try await rewriteImages(in: doc, store: store, baseURL: URL(string: article.url))
        try HTMLUtils.finishSanitization(doc)
        let body = try HTMLUtils.bodyHTML(doc)
        return ContentFormatter.format(content: body, title: article.title, url: article.url,
                                       headerHTML: header?.html, commentsHTML: nil)
    }
}
