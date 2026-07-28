import Foundation
import SwiftData

/// Pure decision logic for which orphaned image hashes are safe to delete right now. Extracted
/// as a `nonisolated`, SwiftData-free type so the interesting behaviour is unit-testable directly
/// (see `ImagePruneTests`); the SwiftData/disk plumbing lives in `ImagePruneRunner` below.
///
/// **Why a two-phase quarantine.** A `StoredImage` delete propagates through CloudKit to every
/// other device. If this device's article set is momentarily incomplete — mid-import, partially
/// synced, a fresh install still pulling down — a hash can look unreferenced *here* while another
/// device still needs it, and deleting it would destroy it everywhere. So a hash is never deleted
/// the first time it's seen unreferenced: it's recorded as a *candidate* with a local first-seen
/// timestamp, and only deleted once a later pass finds it still unreferenced after
/// `quarantinePeriod` has elapsed.
enum ImagePrunePlan {
    /// How long a hash must sit unreferenced before it's actually deleted.
    static let quarantinePeriod: TimeInterval = 24 * 3600

    struct Result: Sendable, Equatable {
        /// Hashes safe to delete now: still unreferenced, and quarantined long enough.
        let toDelete: Set<String>
        /// The candidate map to persist for the next pass.
        let candidates: [String: Date]
    }

    /// - Parameters:
    ///   - referenced: every hash the library currently uses — feed logos plus every lead image
    ///     and in-body image/embed poster across all articles. Reuses
    ///     `AggregationWriter.referencedImageHashes()`; never re-derived here.
    ///   - stored: every hash under consideration for pruning — the union of `StoredImage` row
    ///     hashes and on-disk `ImageStore` hashes (the disk cache can hold blobs the row set never
    ///     covered, and vice versa).
    ///   - candidates: the previously persisted first-seen-unreferenced map (device-local,
    ///     `ImagePruneCandidateStore`). Keyed by hash to the local time it was first seen
    ///     unreferenced — never `StoredImage.createdAt`, which mirrors from the originating device
    ///     and would let an imported month-old blob clear the age check instantly.
    ///   - now: the clock, injectable for tests.
    ///   - quarantinePeriod: injectable for tests; production callers use the default.
    ///   - hasArticles: whether the library has any `Article` row at all. An empty article table
    ///     means the store looks incomplete (fresh install, mid-import) — a legitimate empty
    ///     *referenced* set (articles with no images) is fine, but zero articles is not enough
    ///     information to prune safely, so nothing is decided: no deletions, and the candidate map
    ///     is returned unchanged so an incomplete run can't warp the quarantine clock either.
    static func decide(
        referenced: Set<String>,
        stored: Set<String>,
        candidates: [String: Date],
        now: Date,
        quarantinePeriod: TimeInterval = ImagePrunePlan.quarantinePeriod,
        hasArticles: Bool
    ) -> Result {
        guard hasArticles else { return Result(toDelete: [], candidates: candidates) }

        var nextCandidates: [String: Date] = [:]
        var toDelete: Set<String> = []
        for hash in stored {
            guard !referenced.contains(hash) else { continue }   // referenced -> never a candidate
            if let firstSeen = candidates[hash], now.timeIntervalSince(firstSeen) >= quarantinePeriod {
                toDelete.insert(hash)
            } else {
                nextCandidates[hash] = candidates[hash] ?? now
            }
        }
        return Result(toDelete: toDelete, candidates: nextCandidates)
    }
}

/// Device-local persistence for `ImagePrunePlan`'s candidate map. Deliberately `UserDefaults`,
/// not `AppSettings.SyncedSettings` and not the SwiftData store — these are local first-seen
/// timestamps that must never sync (a candidate timestamp from another device would defeat the
/// whole quarantine guard, same reasoning as the `StoredImage.createdAt` note above).
enum ImagePruneCandidateStore {
    static let defaultsKey = "yana.imagePruneCandidates"

    static func load(defaults: UserDefaults = .standard) -> [String: Date] {
        guard let data = defaults.data(forKey: defaultsKey) else { return [:] }
        return (try? JSONDecoder().decode([String: Date].self, from: data)) ?? [:]
    }

    static func save(_ candidates: [String: Date], defaults: UserDefaults = .standard) {
        guard let data = try? JSONEncoder().encode(candidates) else { return }
        defaults.set(data, forKey: defaultsKey)
    }
}

/// The SwiftData half of the prune pass. Its own `@ModelActor` background context — separate from
/// `AggregationWriter` — so it must be called through `OffMainActor.run` per the `@ModelActor`
/// caller's-thread rule (see `OffMainActor`).
@ModelActor
actor ImagePruneRunner {
    /// Whether the library has any `Article` row, and every hash with a `StoredImage` row.
    func snapshot() -> (hasArticles: Bool, storedHashes: Set<String>) {
        let hasArticles = ((try? modelContext.fetchCount(FetchDescriptor<Article>())) ?? 0) > 0
        let rows = (try? modelContext.fetch(FetchDescriptor<StoredImage>())) ?? []
        return (hasArticles, Set(rows.map(\.contentHash)))
    }

    /// Deletes every `StoredImage` row whose `contentHash` is in `hashes`. Returns the count
    /// actually deleted, for logging.
    @discardableResult
    func deleteRows(hashes: Set<String>) -> Int {
        guard !hashes.isEmpty else { return 0 }
        let rows = (try? modelContext.fetch(FetchDescriptor<StoredImage>())) ?? []
        var deleted = 0
        for row in rows where hashes.contains(row.contentHash) {
            modelContext.delete(row)
            deleted += 1
        }
        if deleted > 0 { try? modelContext.save() }
        return deleted
    }
}
