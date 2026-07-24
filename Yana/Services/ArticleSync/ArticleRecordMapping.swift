import Foundation
import SwiftData

extension SyncedArticleRecord {
    /// Build a record from a local article. Returns nil when the article has no feed (its triple
    /// can't be formed). Runs on the main actor — reads the non-Sendable `Article`.
    @MainActor
    init?(article: Article) {
        let feedIdentifier = article.syncFeedIdentifier.isEmpty ? article.feed?.identifier : article.syncFeedIdentifier
        let aggregatorType = article.syncAggregatorType.isEmpty ? article.feed?.aggregatorType : article.syncAggregatorType
        guard let feedIdentifier, let aggregatorType else { return nil }
        let blocks = article.blocks
        self.init(
            uid: ArticleUID.make(feedIdentifier: feedIdentifier, aggregatorType: aggregatorType,
                                 articleIdentifier: article.identifier, date: article.date, title: article.title),
            feedIdentifier: feedIdentifier,
            aggregatorType: aggregatorType,
            articleIdentifier: article.identifier,
            title: article.title, url: article.url, author: article.author, summary: article.summary,
            plainText: article.plainText, leadImageRef: article.leadImageRef, iconURL: article.iconURL,
            date: article.date, createdAt: article.createdAt, blockData: article.blockData,
            isStarred: article.isStarred, tagNames: article.tags.map(\.name),
            imageHashes: ArticleImageRefs.hashes(in: blocks))
    }
}

/// Upserts a single `SyncedArticleRecord` into local SwiftData. `createdAt` converges to the
/// earliest value seen (min-wins) so independently-aggregated copies of the same article settle on
/// the same timeline slot; everything else is last-writer-wins. The feed is linked by its
/// `(identifier|aggregatorType)` key from `feedsByKey`, or left nil (held unlinked) when the
/// feed hasn't synced yet.
enum ArticleRecordApply {
    static func feedKey(feedIdentifier: String, aggregatorType: String) -> String {
        "\(feedIdentifier)|\(aggregatorType)"
    }

    @MainActor
    @discardableResult
    static func apply(
        _ record: SyncedArticleRecord,
        into context: ModelContext,
        starredTag: Tag?,
        feedsByKey: [String: Feed]
    ) -> Article {
        let feed = feedsByKey[feedKey(feedIdentifier: record.feedIdentifier, aggregatorType: record.aggregatorType)]
        let identifier = record.articleIdentifier

        // An unlinked orphan for this exact identity (a record that synced before its feed existed)
        // is promoted rather than duplicated: prefer a linked article under the feed, else adopt a
        // feed-less article whose stored identity matches.
        let orphanDescriptor = FetchDescriptor<Article>(predicate: #Predicate { $0.identifier == identifier })
        let unlinkedMatch = (try? context.fetch(orphanDescriptor))?.first {
            $0.feed == nil
                && $0.syncFeedIdentifier == record.feedIdentifier
                && $0.syncAggregatorType == record.aggregatorType
        }
        let existing = (feed?.articles.first { $0.identifier == identifier }) ?? unlinkedMatch

        let article = existing ?? {
            let created = Article(
                title: record.title, identifier: record.articleIdentifier, url: record.url,
                date: record.date, author: record.author, iconURL: record.iconURL, summary: record.summary)
            created.createdAt = record.createdAt       // first-writer value adopted on create
            context.insert(created)
            return created
        }()

        // Last-writer-wins body/metadata.
        article.title = record.title
        article.url = record.url
        article.author = record.author
        article.iconURL = record.iconURL
        article.summary = record.summary
        article.blockData = record.blockData
        article.plainText = record.plainText
        article.leadImageRef = record.leadImageRef
        article.date = record.date
        article.syncFeedIdentifier = record.feedIdentifier
        article.syncAggregatorType = record.aggregatorType
        if let feed { article.feed = feed }

        // First-writer-wins by convergence: both devices settle on the earliest createdAt seen,
        // so independently-aggregated copies of the same article end up in the same timeline slot.
        article.createdAt = min(article.createdAt, record.createdAt)

        // Tags: snapshot the feed's tags (the article's tagNames ride for reference/future use),
        // then reconcile Starred from the record.
        if let feed { article.tags = feed.tags }
        if let starredTag {
            article.setStarred(record.isStarred, using: starredTag)
        }
        return article
    }
}

extension ArticleUID {
    /// Derive the canonical UID from an article's stored feed identity (falling back to its linked
    /// feed). Returns nil for a legacy article with neither stored identity nor a linked feed.
    @MainActor
    static func make(for article: Article) -> String? {
        let feedIdentifier = article.syncFeedIdentifier.isEmpty ? article.feed?.identifier : article.syncFeedIdentifier
        let aggregatorType = article.syncAggregatorType.isEmpty ? article.feed?.aggregatorType : article.syncAggregatorType
        guard let feedIdentifier, let aggregatorType else { return nil }
        return make(feedIdentifier: feedIdentifier, aggregatorType: aggregatorType,
                    articleIdentifier: article.identifier, date: article.date, title: article.title)
    }
}
