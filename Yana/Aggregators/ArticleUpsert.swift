import Foundation
import SwiftData

/// Inserts or updates `Article`s from aggregated results, deduping by `(feed, identifier)`.
/// Tags are snapshotted from the feed at import; the user's Starred tag survives re-imports.
enum ArticleUpsert {
    @MainActor
    static func apply(
        _ aggregated: [AggregatedArticle],
        to feed: Feed,
        starredTag: Tag?,
        context: ModelContext,
        now: Date
    ) {
        for item in aggregated {
            if let existing = feed.articles.first(where: { $0.identifier == item.identifier }) {
                // Update: refresh content; re-snapshot feed tags; preserve Starred.
                let wasStarred = existing.isStarred
                existing.title = item.title
                existing.url = item.url
                existing.rawContent = item.rawContent
                existing.content = item.content
                existing.author = item.author
                existing.iconURL = item.iconURL
                existing.date = item.date
                existing.tags = feed.tags
                if wasStarred, let starredTag, !existing.tags.contains(where: { $0.id == starredTag.id }) {
                    existing.tags.append(starredTag)
                }
                // createdAt left untouched — preserves the reader's timeline position.
            } else {
                // Insert: snapshot the feed's current tags.
                let article = Article(
                    title: item.title,
                    identifier: item.identifier,
                    url: item.url,
                    rawContent: item.rawContent,
                    content: item.content,
                    date: item.date,
                    author: item.author,
                    iconURL: item.iconURL
                )
                article.createdAt = now
                article.feed = feed
                context.insert(article)
                article.tags = feed.tags
            }
        }
    }
}
