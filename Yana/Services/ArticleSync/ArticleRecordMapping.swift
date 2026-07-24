import Foundation
import SwiftData

extension SyncedArticleRecord {
    /// Build a record from a local article. Returns nil when the article has no feed (its triple
    /// can't be formed). Runs on the main actor — reads the non-Sendable `Article`.
    @MainActor
    init?(article: Article) {
        guard let feed = article.feed else { return nil }
        let blocks = article.blocks
        self.init(
            uid: ArticleUID.make(
                feedIdentifier: feed.identifier, aggregatorType: feed.aggregatorType,
                articleIdentifier: article.identifier, date: article.date, title: article.title),
            feedIdentifier: feed.identifier,
            aggregatorType: feed.aggregatorType,
            articleIdentifier: article.identifier,
            title: article.title,
            url: article.url,
            author: article.author,
            summary: article.summary,
            plainText: article.plainText,
            leadImageRef: article.leadImageRef,
            iconURL: article.iconURL,
            date: article.date,
            createdAt: article.createdAt,
            blockData: article.blockData,
            isStarred: article.isStarred,
            tagNames: article.tags.map(\.name),
            imageHashes: ArticleImageRefs.hashes(in: blocks)
        )
    }
}

/// Upserts a single `SyncedArticleRecord` into local SwiftData. `createdAt` is first-writer-wins
/// (an existing article keeps its own); everything else is last-writer-wins. The feed is linked by
/// its `(identifier|aggregatorType)` key from `feedsByKey`, or left nil (held unlinked) when the
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

        // Find an existing local article with this UID's identifier under the same feed.
        let identifier = record.articleIdentifier
        let existing: Article?
        if let feed {
            existing = feed.articles.first { $0.identifier == identifier }
        } else {
            let descriptor = FetchDescriptor<Article>(predicate: #Predicate { $0.identifier == identifier })
            existing = (try? context.fetch(descriptor))?.first { $0.feed == nil }
        }

        let article = existing ?? {
            let created = Article(
                title: record.title, identifier: record.articleIdentifier, url: record.url,
                date: record.date, author: record.author, iconURL: record.iconURL, summary: record.summary)
            created.createdAt = record.createdAt       // first-writer value adopted on create
            context.insert(created)
            return created
        }()

        // Last-writer-wins body/metadata (createdAt intentionally untouched on update).
        article.title = record.title
        article.url = record.url
        article.author = record.author
        article.iconURL = record.iconURL
        article.summary = record.summary
        article.blockData = record.blockData
        article.plainText = record.plainText
        article.leadImageRef = record.leadImageRef
        article.date = record.date
        if let feed { article.feed = feed }

        // Tags: snapshot the feed's tags (the article's tagNames ride for reference/future use),
        // then reconcile Starred from the record.
        if let feed { article.tags = feed.tags }
        if let starredTag {
            article.setStarred(record.isStarred, using: starredTag)
        }
        return article
    }
}
