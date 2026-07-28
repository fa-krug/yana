import Foundation
import SwiftData

/// Splices a small set of changed/removed rows into the timeline index, so a save costs work
/// proportional to what changed rather than to the size of the library.
///
/// The index is the `createdAt`-ascending order `ArticleSummaryLoader.load()` produces, and this
/// preserves it: one linear merge pass, no re-sort. Rows are identified by `persistentID` —
/// `identifier` is only a per-feed dedup key, so two feeds can legitimately share one.
///
/// Pure, so the ordering rules below are unit-tested without a store.
enum SummaryIndexMerge {

    /// Apply `changed` (re-read rows) and `removed` (deleted rows) to a `createdAt`-ascending index.
    ///
    /// Ties on `createdAt` keep the incoming row *after* the existing ones. SQLite gives no
    /// guarantee for tied sort keys either, and inserts are jittered across a window
    /// (`ArticleUpsert.importJitterWindow`), so exact ties are rare; a later full reconcile settles
    /// any disagreement.
    static func apply(
        to index: [ArticleSummary],
        changed: [ArticleSummary],
        removed: Set<PersistentIdentifier>
    ) -> [ArticleSummary] {
        // Every changed row is re-inserted at its (possibly new) position, so drop the old copy too.
        var dropped = removed
        for summary in changed { if let id = summary.persistentID { dropped.insert(id) } }

        let kept = dropped.isEmpty
            ? index
            : index.filter { $0.persistentID.map { !dropped.contains($0) } ?? true }
        guard !changed.isEmpty else { return kept }

        let incoming = changed.sorted { $0.createdAt < $1.createdAt }
        var merged: [ArticleSummary] = []
        merged.reserveCapacity(kept.count + incoming.count)
        var i = 0, j = 0
        while i < kept.count, j < incoming.count {
            if kept[i].createdAt <= incoming[j].createdAt {
                merged.append(kept[i]); i += 1
            } else {
                merged.append(incoming[j]); j += 1
            }
        }
        merged.append(contentsOf: kept[i...])
        merged.append(contentsOf: incoming[j...])
        return merged
    }

    /// Whether `index` can be spliced at all. A disk-cache-hydrated index carries no
    /// `persistentID`s (they are runtime-only and deliberately not persisted), so rows in it cannot
    /// be matched against a change set and the caller must fall back to a full load.
    static func isSpliceable(_ index: [ArticleSummary]) -> Bool {
        !index.contains { $0.persistentID == nil }
    }
}
