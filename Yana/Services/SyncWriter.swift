import Foundation
import SwiftData

struct SyncArticleSummaryWire: Decodable, Sendable {
    let id: Int
    let feedId: Int
    let name: String
    let identifier: String
    let date: Date
    let author: String
    let icon: String?
    let read: Bool
    let starred: Bool
    let createdAt: Date
    let updatedAt: Date
}

struct SyncFeedWire: Decodable, Sendable {
    let id: Int
    let name: String
    let aggregator: String
    let identifier: String
    let enabled: Bool
    let dailyLimit: Int
    let tagIds: [Int]
    let logoImageHash: String?
    let updatedAt: Date
}

/// The `SyncEngine`'s write path. Mirrors `AggregationWriter`'s role exactly -- everything it
/// does is a plain `ModelContext` write, so `ArticleStore`'s `ModelContext.didSave` observer
/// picks up every change with no changes needed on that side (see `ArticleStore.swift`).
@ModelActor
actor SyncWriter {
    /// Upserts by `Article.serverID`. Preserves `createdAt` on update (matches the existing
    /// "an article's timeline position never jumps on re-fetch" rule). Returns the touched rows'
    /// `PersistentIdentifier`s so the caller can report progress without a second fetch.
    @discardableResult
    func upsertSummaries(_ summaries: [SyncArticleSummaryWire]) -> [PersistentIdentifier] {
        var touched: [PersistentIdentifier] = []
        for summary in summaries {
            // Both values are precomputed as plain local `let`s -- matching the pattern
            // `FeedsView.refreshArticleCounts()` already uses (`let id = feed.persistentModelID`
            // before the predicate) -- rather than doing the member access inline inside the
            // closure. Two independent reasons: comparing `Article.serverID` (`Int?`) directly
            // against a captured struct's `.id` member-access expression makes the #Predicate
            // macro treat that member access as its own KeyPath expression, which then fails to
            // unify with the Optional side ("KeyPath<SyncArticleSummaryWire, Int>" vs
            // "...Int?"); and `.description` isn't representable inside `#Predicate` at all (not
            // a `StandardPredicateExpression`) -- same pattern `replaceFeeds` below uses for
            // `idString`.
            let targetServerID = summary.id
            let existingDescriptor = FetchDescriptor<Article>(predicate: #Predicate { $0.serverID == targetServerID })
            let feedIdString = summary.feedId.description
            let feedDescriptor = FetchDescriptor<Feed>(predicate: #Predicate { $0.identifier == feedIdString })
            // Feeds are looked up by their own serverID equivalent -- see `replaceFeeds` below,
            // which stores the server feed id into `Feed.identifier` verbatim (feeds have no
            // separate natural identifier client-side any more; the server's id *is* the identity).
            let feed = try? modelContext.fetch(feedDescriptor).first

            if let article = try? modelContext.fetch(existingDescriptor).first {
                article.title = summary.name
                article.author = summary.author
                // The wire's `identifier` IS the article's URL/permalink for every aggregator type
                // on the server (confirmed against yana-server's aggregators -- `website`/`reddit`
                // set `identifier` to the scraped/post URL directly, `youtube` to the watch URL).
                // There is no separate `url` field on `ArticleSummaryWire`.
                article.url = summary.identifier
                article.starred = summary.starred
                article.feed = feed
                // A content update on the server (title/body edit, or just a re-fetch that
                // changed something) must be re-pulled -- reset unconditionally on every update
                // hit so `SyncEngine.backfillMissingContent()`'s `hasContent == false` scan picks
                // it up again. Idempotent and bounded, so doing this even when the update didn't
                // touch the body is harmless: worst case is one redundant `/content` refetch.
                article.hasContent = false
                touched.append(article.persistentModelID)
            } else {
                let article = Article(
                    title: summary.name, identifier: summary.identifier, url: summary.identifier,
                    date: summary.date, author: summary.author, iconURL: summary.icon
                )
                article.serverID = summary.id
                article.starred = summary.starred
                article.createdAt = summary.createdAt
                article.feed = feed
                modelContext.insert(article)
                touched.append(article.persistentModelID)
            }
        }
        try? modelContext.save()
        return touched
    }

    /// Decodes `document` into `[Block]` and writes it to the matching article, marking
    /// `hasContent`. Returns `false` (no throw) if no local article with this `serverID` exists
    /// yet -- a race between a summary upsert and its content fetch landing out of order is a
    /// normal, expected condition in a bounded-concurrency pipeline, not an error.
    @discardableResult
    func applyContent(articleServerID: Int, document: WireDocument) -> Bool {
        let descriptor = FetchDescriptor<Article>(predicate: #Predicate { $0.serverID == articleServerID })
        guard let article = try? modelContext.fetch(descriptor).first else { return false }
        article.blocks = document.blocks
        article.hasContent = true
        try? modelContext.save()
        return true
    }

    /// Deletes one article per given `serverID`, if a local match exists. Looked up one id at a
    /// time (via the same proven `$0.serverID == <plain captured Int>` shape `upsertSummaries`
    /// uses, backed by the `serverID` `#Index`) rather than a single
    /// `serverIDs.contains($0.serverID ?? <sentinel>)` predicate: that shape compiles, but its
    /// `?? `-coalesce lowers to a SQL `TERNARY`, and CoreData's SQL generator cannot use a
    /// `TERNARY` as the left-hand side of an `IN` test -- it throws
    /// `NSInvalidArgumentException: unimplemented SQL generation ... (bad LHS)` at fetch time, a
    /// runtime crash a `try?` around the fetch would silently swallow into "removals did
    /// nothing". Caught by actually running `SyncWriterTests` (see task-9-report.md), not by
    /// reading the code -- it compiles cleanly.
    func applyRemovals(_ serverIDs: [Int]) {
        guard !serverIDs.isEmpty else { return }
        for id in serverIDs {
            let descriptor = FetchDescriptor<Article>(predicate: #Predicate { $0.serverID == id })
            if let article = try? modelContext.fetch(descriptor).first {
                modelContext.delete(article)
            }
        }
        try? modelContext.save()
    }

    /// Full replace-by-upsert of every feed the server returned (the `/feeds` response is small
    /// and unpaginated, so there's no incremental-delta protocol to speak of here -- unlike
    /// articles). Stores the server's feed id as `Feed.identifier` (string form), since feeds
    /// have no other natural identity worth keeping client-side any more.
    @discardableResult
    func replaceFeeds(_ feeds: [SyncFeedWire]) -> [PersistentIdentifier] {
        var touched: [PersistentIdentifier] = []
        for wire in feeds {
            let idString = String(wire.id)
            let descriptor = FetchDescriptor<Feed>(predicate: #Predicate { $0.identifier == idString })
            if let feed = try? modelContext.fetch(descriptor).first {
                feed.name = wire.name
                feed.aggregator = wire.aggregator
                feed.enabled = wire.enabled
                feed.dailyLimit = wire.dailyLimit
                feed.tagIDs = wire.tagIds
                feed.logoImageHash = wire.logoImageHash
                feed.updatedAt = wire.updatedAt
                touched.append(feed.persistentModelID)
            } else {
                let feed = Feed(name: wire.name, aggregator: wire.aggregator, identifier: idString,
                                 dailyLimit: wire.dailyLimit, enabled: wire.enabled)
                feed.tagIDs = wire.tagIds
                feed.logoImageHash = wire.logoImageHash
                feed.updatedAt = wire.updatedAt
                modelContext.insert(feed)
                touched.append(feed.persistentModelID)
            }
        }
        try? modelContext.save()
        return touched
    }

    /// The content-backfill candidate list: every locally-known article whose body hasn't
    /// synced yet, oldest-`createdAt`-first, capped at `limit` so one pass never tries to fetch
    /// an unbounded backlog.
    func articlesMissingContent(limit: Int) -> [(persistentID: PersistentIdentifier, serverID: Int)] {
        var descriptor = FetchDescriptor<Article>(
            predicate: #Predicate { $0.hasContent == false && $0.serverID != nil },
            sortBy: [SortDescriptor(\.createdAt)]
        )
        descriptor.fetchLimit = limit
        guard let articles = try? modelContext.fetch(descriptor) else { return [] }
        return articles.compactMap { article in
            guard let serverID = article.serverID else { return nil }
            return (article.persistentModelID, serverID)
        }
    }
}
