import Foundation
import SwiftSoup

/// Ports the server's RssAggregator template method. Subclasses override hooks, not `aggregate()`.
/// `@unchecked Sendable`: instances are created per-run and not shared across tasks.
class RSSPipelineAggregator: Aggregator, @unchecked Sendable {
    let config: FeedConfig
    let credentials: AggregatorCredentials
    let store: ImageStore

    init(config: FeedConfig, credentials: AggregatorCredentials, store: ImageStore = .shared) {
        self.config = config
        self.credentials = credentials
        self.store = store
    }

    func validate() throws {
        if config.identifier.trimmingCharacters(in: .whitespaces).isEmpty {
            throw AggregatorError.missingIdentifier
        }
    }

    func aggregate() async throws -> [AggregatedArticle] {
        var result: [AggregatedArticle] = []
        try await aggregate { result.append($0) }
        return try await finalize(result)
    }

    /// Streaming form: enrich one entry at a time and hand each finished article to `sink` before
    /// moving on, so the caller can persist it immediately. (`aggregate()` collects this stream.)
    func aggregate(_ sink: (AggregatedArticle) async throws -> Void) async throws {
        try validate()
        let entries = try await fetchEntries()
        let limited = Array(entries.prefix(max(config.dailyLimit, 1)))
        for entry in limited {
            if Task.isCancelled { break }                 // cancelled run: stop before degrading more entries
            let base = makeArticle(from: entry)
            guard shouldInclude(base) else { continue }
            do {
                let enriched = try await enrich(base, entry: entry)
                guard postFilter(enriched) else { continue }
                try await sink(enriched)
            } catch AggregatorError.articleSkip {
                continue                                  // 4xx / explicit skip → omit article
            } catch {
                // A cancelled run stops here with the fully-enriched items handed off so far,
                // rather than persisting feed-only fallbacks for the remaining entries.
                if error.isCancellationError || Task.isCancelled { break }
                throw error
            }
        }
    }

    /// Re-fetch one known article by re-downloading the feed and enriching only the entry whose
    /// link matches the seed identifier. The network fetch pulls the whole feed (RSS content lives
    /// in the feed payload), but only the matching entry is returned. `nil` when the entry is gone.
    /// `FullWebsiteAggregator` overrides this with a per-URL re-scrape.
    func refetch(_ seed: AggregatedArticle) async throws -> AggregatedArticle? {
        let entries = try await fetchEntries()
        guard let entry = entries.first(where: { $0.link == seed.identifier }) else { return nil }
        return try await enrich(makeArticle(from: entry), entry: entry)
    }

    // MARK: - Hooks

    func shouldInclude(_ article: AggregatedArticle) -> Bool { true }
    func postFilter(_ article: AggregatedArticle) -> Bool { true }

    func fetchEntries() async throws -> [FeedEntry] {
        guard let url = URL(string: config.identifier) else { throw AggregatorError.missingIdentifier }
        let (data, _) = try await HTTPClient.fetchData(url)
        return try FeedParser.parse(data).entries
    }

    func makeArticle(from entry: FeedEntry) -> AggregatedArticle {
        let content = entry.content ?? entry.summary ?? entry.entryDescription ?? ""
        return AggregatedArticle(
            title: entry.title,
            identifier: entry.link,
            url: entry.link,
            rawContent: content,
            content: content,
            date: entry.published ?? .now,
            author: entry.author,
            iconURL: nil
        )
    }

    func enrich(_ article: AggregatedArticle, entry: FeedEntry) async throws -> AggregatedArticle {
        var article = article
        article.content = try await processContent(article.content, article: article, headerHTML: nil)
        return article
    }

    func processContent(_ html: String, article: AggregatedArticle, headerHTML: String?) async throws -> String {
        let doc = try HTMLUtils.parse(html)
        try EmbedRewriter.rewriteEmbeds(in: doc)
        try HTMLUtils.removeUnsafeTags(doc)
        try HTMLUtils.removeTrackingPixels(doc)
        try await rewriteImages(in: doc, store: store, baseURL: URL(string: article.url))
        try HTMLUtils.finishSanitization(doc)
        let body = try HTMLUtils.bodyHTML(doc)
        return ContentFormatter.format(content: body, title: article.title, url: article.url,
                                       headerHTML: headerHTML, commentsHTML: nil)
    }

    func finalize(_ articles: [AggregatedArticle]) async throws -> [AggregatedArticle] { articles }

    var contentSelector: String { "" }
    var selectorsToRemove: [String] { [] }
}
