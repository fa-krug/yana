import Foundation
import SwiftData

/// Resolves an `ArticleSummary` to its live `Article`.
///
/// Primary: a **fresh fetch scoped by `persistentModelID`** when the summary carries one. This
/// gives both freshness *and* exact identity — the fetch forces a store round-trip so a
/// background-committed body update is visible (a held/cached object would be stale), while the
/// pid predicate pins the exact row (`Article.identifier` is NOT globally unique — it's a per-feed
/// dedup key, so two feeds can share an identifier; an unscoped identifier fetch could resolve the
/// wrong article across feeds).
///
/// Fallback (when `persistentID` is nil -- a cache-rehydrated summary, where encode → decode drops
/// the runtime id): a one-row `serverID` fetch when the summary carries one (globally unique once
/// synced, so still immune to the cross-feed collision above), else a one-row `identifier` fetch --
/// so the reader never lands on a blank page for a known article.
@MainActor
enum ArticleResolution {
    static func resolve(_ summary: ArticleSummary, in context: ModelContext) -> Article? {
        if let pid = summary.persistentID {
            var descriptor = FetchDescriptor<Article>(predicate: #Predicate { $0.persistentModelID == pid })
            descriptor.fetchLimit = 1
            if let article = try? context.fetch(descriptor).first { return article }
        }
        if let serverID = summary.serverID, let article = fetchByServerID(serverID, in: context) {
            return article
        }
        return fetchByIdentifier(summary.identifier, in: context)
    }

    static func fetchByServerID(_ serverID: Int, in context: ModelContext) -> Article? {
        var descriptor = FetchDescriptor<Article>(predicate: #Predicate { $0.serverID == serverID })
        descriptor.fetchLimit = 1
        return try? context.fetch(descriptor).first
    }

    static func fetchByIdentifier(_ identifier: String, in context: ModelContext) -> Article? {
        var descriptor = FetchDescriptor<Article>(predicate: #Predicate { $0.identifier == identifier })
        descriptor.fetchLimit = 1
        return try? context.fetch(descriptor).first
    }

    /// The most recently-synced article (by `createdAt`, insertion order — never `date`, which a
    /// feed can backfill out of order), or nil if the library is empty. Used by the launch warmer
    /// when no saved anchor exists (the reader opens to the newest article in that case).
    static func fetchNewest(in context: ModelContext) -> Article? {
        var descriptor = FetchDescriptor<Article>(sortBy: [SortDescriptor(\.createdAt, order: .reverse)])
        descriptor.fetchLimit = 1
        return try? context.fetch(descriptor).first
    }
}
