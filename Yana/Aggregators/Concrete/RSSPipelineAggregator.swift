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
        try validate()
        let entries = try await fetchEntries()
        let limited = Array(entries.prefix(max(config.dailyLimit, 1)))
        var result: [AggregatedArticle] = []
        for entry in limited {
            let base = makeArticle(from: entry)
            guard shouldInclude(base) else { continue }
            do {
                let enriched = try await enrich(base, entry: entry)
                guard postFilter(enriched) else { continue }
                result.append(enriched)
            } catch AggregatorError.articleSkip {
                continue                                  // 4xx / explicit skip → omit article
            }
        }
        return try await finalize(result)
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
        try await rewriteImages(in: doc, store: store, baseURL: URL(string: article.url))
        try HTMLUtils.sanitizeClassNames(doc)
        try HTMLUtils.removeComments(doc)
        let body = try HTMLUtils.bodyHTML(doc)
        return ContentFormatter.format(content: body, title: article.title, url: article.url,
                                       headerHTML: headerHTML, commentsHTML: nil)
    }

    func finalize(_ articles: [AggregatedArticle]) async throws -> [AggregatedArticle] { articles }

    var contentSelector: String { "" }
    var selectorsToRemove: [String] { [] }
}
