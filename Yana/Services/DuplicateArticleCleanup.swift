import Foundation
import SwiftData

/// One-time-per-launch sweep that collapses duplicate `Article` rows sharing the same non-nil
/// `serverID` down to one. `Article.serverID` has no `@Attribute(.unique)` (adding one now would
/// be a risky migration for exactly the devices that already have duplicates), so two independent
/// `SyncWriter` upserts racing the same server article -- a background refresh and a manual
/// pull-to-refresh both reaching `upsertSummaries` for the same article before either had saved --
/// could each insert their own row instead of one updating the other's. `SyncCoordinator` (added
/// alongside this) stops that race going forward; this sweep cleans up whatever a device already
/// accumulated before the fix, and is a cheap no-op single fetch once no duplicates remain.
@ModelActor
actor DuplicateArticleCleaner {
    /// Collapses every group of articles sharing a `serverID` down to one survivor: prefers a row
    /// that already has its content synced (`hasContent == true`) over one that doesn't, then the
    /// earliest `createdAt` -- matching the "timeline position never jumps" rule the rest of
    /// `SyncWriter` follows. `starred`/`read` are OR'd into the survivor before the losing rows are
    /// deleted, so a star or a read mark the user set on whichever duplicate happened to be visible
    /// is never silently dropped. Returns the number of rows deleted.
    @discardableResult
    func deduplicate() throws -> Int {
        let descriptor = FetchDescriptor<Article>(predicate: #Predicate { $0.serverID != nil })
        let articles = try modelContext.fetch(descriptor)

        var byServerID: [Int: [Article]] = [:]
        for article in articles {
            guard let serverID = article.serverID else { continue }
            byServerID[serverID, default: []].append(article)
        }

        var deleted = 0
        for group in byServerID.values where group.count > 1 {
            let survivor = group.min { lhs, rhs in
                if lhs.hasContent != rhs.hasContent { return lhs.hasContent }
                return lhs.createdAt < rhs.createdAt
            }!
            let losers = group.filter { $0.persistentModelID != survivor.persistentModelID }
            if losers.contains(where: \.starred) { survivor.starred = true }
            if losers.contains(where: \.read) { survivor.setRead(true) }
            for loser in losers {
                modelContext.delete(loser)
                deleted += 1
            }
        }
        if deleted > 0 { try modelContext.save() }
        return deleted
    }
}

/// Kicks the one-time duplicate-article sweep as a low-priority background task, mirroring
/// `BlockMigration.run`.
enum DuplicateArticleCleanup {
    static func run(container: ModelContainer) {
        Task.detached(priority: .utility) {
            let cleaner = DuplicateArticleCleaner(modelContainer: container)
            _ = try? await cleaner.deduplicate()
        }
    }
}
