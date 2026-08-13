import Foundation
import SwiftData

/// One-time sweep that removes duplicate `Article` rows sharing the same `serverID`. Existed
/// because overlapping, unserialized `SyncEngine.sync()` calls (launch, Mac's repeating refresh
/// loop, pull-to-refresh) could each independently pass `SyncWriter.upsertSummaries`'s
/// fetch-then-insert-if-not-found check for the same server article before either had saved, and
/// each insert their own copy. `SyncEngine.sync()` now serializes overlapping calls per container
/// so no new duplicates form; this sweep cleans up ones a device already accumulated. Self-
/// terminating like `BlockMigrator`: once no `serverID` has more than one row, it finds nothing on
/// the next pass.
@ModelActor
actor ArticleDeduplicator {
    /// Keeps the oldest row (earliest `createdAt`) per duplicated `serverID` and deletes the rest.
    /// Returns the number of rows removed.
    func deduplicate() throws -> Int {
        let rows = try modelContext.fetch(FetchDescriptor<Article>())

        var byServerID: [Int: [Article]] = [:]
        for article in rows {
            guard let serverID = article.serverID else { continue }
            byServerID[serverID, default: []].append(article)
        }

        var removed = 0
        for duplicates in byServerID.values where duplicates.count > 1 {
            let sorted = duplicates.sorted { $0.createdAt < $1.createdAt }
            let kept = sorted[0]
            for extra in sorted.dropFirst() {
                // Reconcile onto the surviving row before deleting the duplicate -- a star or
                // read mark that only landed on this copy (from before the overlapping-sync bug
                // that created the duplicate was fixed) must not be silently reverted by keeping
                // the other, un-starred/unread copy.
                if extra.starred { kept.starred = true }
                if extra.read { kept.setRead(true) }
                modelContext.delete(extra)
                removed += 1
            }
        }
        if removed > 0 { try modelContext.save() }
        return removed
    }
}

/// Kicks the one-time duplicate-article cleanup as a low-priority background task.
enum ArticleDedup {
    static func run(container: ModelContainer) {
        Task.detached(priority: .utility) {
            let deduplicator = ArticleDeduplicator(modelContainer: container)
            _ = try? await deduplicator.deduplicate()
        }
    }
}
