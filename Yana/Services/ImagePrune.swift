import Foundation
import SwiftData

/// Pure decision logic for which orphaned image hashes are safe to delete right now. Extracted
/// as a `nonisolated`, SwiftData-free type so the interesting behaviour is unit-testable directly
/// (see `ImagePruneTests`); the SwiftData/disk plumbing lives in `ImagePruneRunner` below.
///
/// **Why a two-phase quarantine.** If this device"s article set is momentarily incomplete — mid-import, partially
/// a fresh install still pulling down — a hash can look unreferenced *here* while another
/// device still needs it, and deleting it would destroy it everywhere. So a hash is never deleted
/// the first time it's seen unreferenced: it's recorded as a *candidate* with a local first-seen
/// timestamp, and only deleted once a later pass finds it still unreferenced after
/// `quarantinePeriod` has elapsed.
enum ImagePrunePlan {
    /// How long a hash must sit unreferenced before it's actually deleted.
    static let quarantinePeriod: TimeInterval = 24 * 3600

    /// Caps how many hashes a single pass deletes. CLAUDE.md notes a `CKError.partialFailure` over
    /// capping here bounds the SwiftData transaction size per
    /// pass. Hashes past the cap simply carry over as still-quarantined candidates — the
    /// quarantine already means they're safe to delete whenever we get to them, so draining a large
    /// backlog across several passes is harmless.
    static let maxDeletionsPerPass = 500

    struct Result: Sendable, Equatable {
        /// Hashes safe to delete now: still unreferenced, quarantined long enough, and within this
        /// pass's cap.
        let toDelete: Set<String>
        /// The candidate map to persist for the next pass.
        let candidates: [String: Date]
    }

    /// - Parameters:
    ///   - referenced: every hash the library currently uses — feed logos plus every lead image
    ///     and in-body image/embed poster across all articles. Comes from
    ///     `AggregationWriter.referencedImageSnapshotForPruning()`; never re-derived here.
    ///   - stored: every hash under consideration for pruning — the union of `StoredImage` row
    ///     hashes and on-disk `ImageStore` hashes (the disk cache can hold blobs the row set never
    ///     covered, and vice versa).
    ///   - candidates: the previously persisted first-seen-unreferenced map (device-local,
    ///     `ImagePruneCandidateStore`). Keyed by hash to the local time it was first seen
    ///     unreferenced — never `StoredImage.createdAt`, which mirrors from the originating device
    ///     and would let an imported month-old blob clear the age check instantly.
    ///   - now: the clock, injectable for tests.
    ///   - quarantinePeriod: injectable for tests; production callers use the default.
    ///   - maxDeletionsPerPass: injectable for tests; production callers use the default.
    ///   - hasArticles: whether the library has any `Article` row at all. An empty article table
    ///     means the store looks incomplete (fresh install, mid-import) — zero articles is not
    ///     enough information to prune safely, so nothing is decided: no deletions, and the
    ///     candidate map is returned unchanged so an incomplete run can't warp the quarantine clock
    ///     either.
    ///   - hasUnmigratedLegacyContent: whether any article still holds legacy pre-migration HTML
    ///     (`Article.content`). Such an article's blocks are empty until `BlockMigrator` sweeps it,
    ///     so its in-body images are invisible to `referenced` — pruning while this is true could
    ///     delete images that *are* referenced, just not by anything this scan can see yet.
    ///   - hasUndecodableBlocks: whether any article's `blockData` is non-empty but failed to
    ///     decode as `[Block]` (see `ReferencedImageSnapshot.hasUndecodableBlocks`). Such an
    ///     article's in-body images/embed posters are invisible to `referenced` the same way an
    ///     unmigrated article's are, just via decode failure instead of an empty sweep — pruning
    ///     while this is true risks deleting images that are still referenced.
    ///
    /// **Safety bail-out.** `referenced` being empty while `hasArticles` is true, or either
    /// `hasUnmigratedLegacyContent` or `hasUndecodableBlocks` being true, means `referenced` cannot
    /// be trusted as "everything actually in use" — in all cases this pass decides nothing at all
    /// (same as the `hasArticles` guard: no deletions, candidate map passed through unchanged). This
    /// matters because `referencedImageSnapshotForPruning()`'s only failure mode is returning `nil`
    /// for the whole snapshot (callers skip this method entirely then) — but a library that
    /// genuinely has articles and genuinely references nothing is not a realistic steady state
    /// (every feed has a logo), so treating an empty `referenced` set as "trustworthy" would risk
    /// classifying an upstream scan gap as "confirmed nothing is used" instead of "unknown, don't
    /// delete".
    static func decide(
        referenced: Set<String>,
        stored: Set<String>,
        candidates: [String: Date],
        now: Date,
        quarantinePeriod: TimeInterval = ImagePrunePlan.quarantinePeriod,
        maxDeletionsPerPass: Int = ImagePrunePlan.maxDeletionsPerPass,
        hasArticles: Bool,
        hasUnmigratedLegacyContent: Bool,
        hasUndecodableBlocks: Bool
    ) -> Result {
        guard hasArticles, !hasUnmigratedLegacyContent, !hasUndecodableBlocks, !referenced.isEmpty else {
            return Result(toDelete: [], candidates: candidates)
        }

        var nextCandidates: [String: Date] = [:]
        var toDelete: Set<String> = []
        // Sorted so the cap below is deterministic (and testable) rather than depending on Set's
        // unspecified iteration order.
        for hash in stored.sorted() {
            guard !referenced.contains(hash) else { continue }   // referenced -> never a candidate
            if let firstSeen = candidates[hash], now.timeIntervalSince(firstSeen) >= quarantinePeriod {
                if toDelete.count < maxDeletionsPerPass {
                    toDelete.insert(hash)
                } else {
                    nextCandidates[hash] = firstSeen   // still eligible; deferred to a later pass
                }
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
///
/// Binary property-list encoded rather than JSON: a library the size the prune pass exists for
/// (thousands of unreferenced hashes) turns a JSON `[String: Date]` — 64-char hex keys plus JSON
/// punctuation — into a ~1 MB text blob decoded/encoded on every pass; a binary plist stores the
/// same dictionary far more compactly and natively (no string round-trip for the dates).
enum ImagePruneCandidateStore {
    static let defaultsKey = "yana.imagePruneCandidates"

    static func load(defaults: UserDefaults = .standard) -> [String: Date] {
        guard let data = defaults.data(forKey: defaultsKey) else { return [:] }
        return (try? PropertyListDecoder().decode([String: Date].self, from: data)) ?? [:]
    }

    static func save(_ candidates: [String: Date], defaults: UserDefaults = .standard) {
        guard let data = try? PropertyListEncoder().encode(candidates) else { return }
        defaults.set(data, forKey: defaultsKey)
    }
}

/// The SwiftData half of the prune pass. Its own `@ModelActor` background context — separate from
/// `AggregationWriter` — so it must be called through `OffMainActor.run` per the `@ModelActor`
/// caller's-thread rule (see `OffMainActor`).
@ModelActor
actor ImagePruneRunner {
    /// Every hash with a `StoredImage` row. (`hasArticles`, previously also returned here, now
    /// comes from `AggregationWriter.referencedImageSnapshotForPruning()` instead, so it's derived
    /// from the same transaction as `referenced` — see that method's doc comment for why the two
    /// facts must not come from independent fetches.)
    func storedHashes() -> Set<String> {
        let rows = (try? modelContext.fetch(FetchDescriptor<StoredImage>())) ?? []
        return Set(rows.map(\.contentHash))
    }

    /// Deletes every `StoredImage` row whose `contentHash` is in `hashes`, saving every `batchSize`
    /// deletions rather than once at the end — so a large pass never holds the context (or hands
    /// one giant transaction, mirroring `BlockMigrator.migrate(batchSize:)`. `hashes` is
    /// expected to already be capped by `ImagePrunePlan.maxDeletionsPerPass`; batching here is a
    /// second, independent line of defense for whatever is passed in. Returns the count actually
    /// deleted, for logging.
    @discardableResult
    func deleteRows(hashes: Set<String>, batchSize: Int = 200) -> Int {
        guard !hashes.isEmpty else { return 0 }
        let rows = (try? modelContext.fetch(FetchDescriptor<StoredImage>())) ?? []
        var deleted = 0
        for row in rows where hashes.contains(row.contentHash) {
            modelContext.delete(row)
            deleted += 1
            if deleted % batchSize == 0 { try? modelContext.save() }
        }
        if deleted % batchSize != 0 { try? modelContext.save() }
        return deleted
    }
}
