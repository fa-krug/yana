import Foundation
import SwiftData

/// Inserts or updates `Article`s from aggregated results, deduping by `(feed, identifier)`.
/// Tags are snapshotted from the feed at import; the user's Starred tag survives re-imports.
enum ArticleUpsert {
    /// Width of the random window used to back-date a newly inserted article's `createdAt`.
    /// Each insert is shifted earlier by a random offset in `0..<importJitterWindow`, scattering a
    /// single run's inserts across a few minutes so articles from different feeds interleave on the
    /// timeline instead of clustering into per-feed blocks. The window stays well under the minimum
    /// refresh cadence (300s) so separate runs never reorder relative to each other.
    static let importJitterWindow: TimeInterval = 180

    /// Default block converter: the SwiftSoup HTML → `[Block]` parse. It runs on the main actor
    /// when `apply` is called directly (tests, single-article reload), which is fine for one item.
    /// The bulk refresh path instead pre-parses every article **off the main actor** and injects
    /// the result via `blocksFor`, so the heavy parse never runs on the main thread during a run
    /// (see `AggregationService.parseBlocks`).
    static func defaultBlocks(for item: AggregatedArticle) -> [Block] {
        BlockParser.blocks(fromHTML: item.content, baseURL: URL(string: item.url))
    }

    @discardableResult
    @MainActor
    static func apply(
        _ aggregated: [AggregatedArticle],
        to feed: Feed,
        starredTag: Tag?,
        starredIdentifiers: Set<String> = [],
        context: ModelContext,
        now: Date,
        jitter: () -> TimeInterval = { .random(in: 0..<importJitterWindow) },
        blocksFor: (AggregatedArticle) -> [Block] = ArticleUpsert.defaultBlocks,
        canonicalCreatedAt: (String) -> Date? = { _ in nil }
    ) -> Int {
        // Build the dedup index once (O(n)) instead of scanning the relationship per item.
        var byIdentifier: [String: Article] = [:]
        for article in feed.articles { byIdentifier[article.identifier] = article }

        var inserted = 0
        for item in aggregated {
            // The pipeline's sanitized HTML is converted to native blocks here — the single
            // import-time conversion point (also covers AI improve/translate output, which arrives
            // as HTML in `item.content`). The bulk refresh path supplies these blocks pre-parsed
            // off the main actor; direct callers fall back to parsing inline (`defaultBlocks`).
            let blocks = blocksFor(item)
            if let existing = byIdentifier[item.identifier] {
                // Update: refresh content; re-snapshot feed tags; preserve Starred.
                let wasStarred = existing.isStarred
                existing.title = item.title
                existing.url = item.url
                existing.blocks = blocks          // updates blockData + plainText
                existing.content = ""             // drop any legacy HTML once converted
                existing.author = item.author
                existing.iconURL = item.iconURL
                existing.summary = item.summary
                // date left untouched — an article's publication date is immutable, and
                // re-stamping it on every refresh would let a missing/unparseable date
                // (which falls back to "now") drift the article to the top of the timeline.
                existing.tags = feed.tags
                if wasStarred, let starredTag, !existing.tags.contains(where: { $0.id == starredTag.id }) {
                    existing.tags.append(starredTag)
                }
                // createdAt left untouched — preserves the reader's timeline position.
                existing.syncFeedIdentifier = feed.identifier
                existing.syncAggregatorType = feed.aggregatorType
            } else {
                // Insert: snapshot the feed's current tags.
                let article = Article(
                    title: item.title,
                    identifier: item.identifier,
                    url: item.url,
                    date: item.date,
                    author: item.author,
                    iconURL: item.iconURL,
                    summary: item.summary
                )
                article.blocks = blocks           // sets blockData + plainText
                // Adopt the canonical (first-writer) createdAt when article sync already knows this
                // UID — i.e. another device created it in the meantime — so ordering stays stable
                // across devices. Otherwise back-date by jitter as usual.
                let uid = ArticleUID.make(
                    feedIdentifier: feed.identifier, aggregatorType: feed.aggregatorType,
                    articleIdentifier: item.identifier, date: item.date, title: item.title)
                article.createdAt = canonicalCreatedAt(uid) ?? now.addingTimeInterval(-jitter())
                article.feed = feed
                article.syncFeedIdentifier = feed.identifier
                article.syncAggregatorType = feed.aggregatorType
                context.insert(article)
                article.tags = feed.tags
                // If the sync registry already has a starred mark for this article, star it on insert.
                if !starredIdentifiers.isEmpty,
                   starredIdentifiers.contains(item.identifier),
                   let starredTag,
                   !article.tags.contains(where: { $0.id == starredTag.id }) {
                    article.tags.append(starredTag)
                }
                // Track it so a duplicate identifier later in the same batch updates, not re-inserts.
                byIdentifier[item.identifier] = article
                inserted += 1
            }
        }
        return inserted
    }
}
