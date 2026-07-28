import Foundation
import SwiftData
import Testing
@testable import Yana

/// Direct unit tests on `ImagePrunePlan.decide` — the pure, SwiftData-free decision logic behind
/// the orphaned-`StoredImage` prune. See `ImagePrune.swift` for the two-phase quarantine rationale.
@Suite("ImagePrunePlan")
struct ImagePrunePlanTests {
    private let now = Date(timeIntervalSince1970: 1_000_000)
    private let quarantine: TimeInterval = 24 * 3600

    @Test func unreferencedHashNotDeletedOnFirstSight() {
        let result = ImagePrunePlan.decide(
            referenced: ["logo"],
            stored: ["h1"],
            candidates: [:],
            now: now,
            quarantinePeriod: quarantine,
            hasArticles: true,
            hasUnmigratedLegacyContent: false,
            hasUndecodableBlocks: false
        )
        #expect(result.toDelete.isEmpty)
        #expect(result.candidates == ["h1": now])
    }

    @Test func unreferencedHashOlderThanQuarantineIsDeleted() {
        let firstSeen = now.addingTimeInterval(-quarantine - 1)
        let result = ImagePrunePlan.decide(
            referenced: ["logo"],
            stored: ["h1"],
            candidates: ["h1": firstSeen],
            now: now,
            quarantinePeriod: quarantine,
            hasArticles: true,
            hasUnmigratedLegacyContent: false,
            hasUndecodableBlocks: false
        )
        #expect(result.toDelete == ["h1"])
        #expect(result.candidates.isEmpty)
    }

    @Test func unreferencedHashYoungerThanQuarantineIsNotDeleted() {
        let firstSeen = now.addingTimeInterval(-3600)   // 1 hour ago, well under 24h
        let result = ImagePrunePlan.decide(
            referenced: ["logo"],
            stored: ["h1"],
            candidates: ["h1": firstSeen],
            now: now,
            quarantinePeriod: quarantine,
            hasArticles: true,
            hasUnmigratedLegacyContent: false,
            hasUndecodableBlocks: false
        )
        #expect(result.toDelete.isEmpty)
        // The original first-seen timestamp is preserved, not reset to `now`.
        #expect(result.candidates == ["h1": firstSeen])
    }

    @Test func hashBecomesReferencedIsDroppedFromCandidatesAndNotDeleted() {
        let firstSeen = now.addingTimeInterval(-quarantine - 1)   // would be deleted if unreferenced
        let result = ImagePrunePlan.decide(
            referenced: ["h1"],
            stored: ["h1"],
            candidates: ["h1": firstSeen],
            now: now,
            quarantinePeriod: quarantine,
            hasArticles: true,
            hasUnmigratedLegacyContent: false,
            hasUndecodableBlocks: false
        )
        #expect(result.toDelete.isEmpty)
        #expect(result.candidates.isEmpty)
    }

    @Test func referencedHashNeverDeletedRegardlessOfCandidateState() {
        // No prior candidate entry at all, still referenced -> never a candidate, never deleted.
        let result = ImagePrunePlan.decide(
            referenced: ["h1"],
            stored: ["h1"],
            candidates: [:],
            now: now,
            quarantinePeriod: quarantine,
            hasArticles: true,
            hasUnmigratedLegacyContent: false,
            hasUndecodableBlocks: false
        )
        #expect(result.toDelete.isEmpty)
        #expect(result.candidates.isEmpty)
    }

    @Test func emptyArticleTableGuardProducesNoDeletionsAtAll() {
        // Even a hash long past quarantine and unreferenced must not be deleted when the article
        // table is empty — the library looks incomplete (fresh install / mid-import), not "no
        // images referenced".
        let firstSeen = now.addingTimeInterval(-quarantine - 1)
        let existingCandidates: [String: Date] = ["h1": firstSeen, "h2": now]
        let result = ImagePrunePlan.decide(
            referenced: [],
            stored: ["h1", "h2", "h3"],
            candidates: existingCandidates,
            now: now,
            quarantinePeriod: quarantine,
            hasArticles: false,
            hasUnmigratedLegacyContent: false,
            hasUndecodableBlocks: false
        )
        #expect(result.toDelete.isEmpty)
        // Candidate map passes through untouched — an incomplete run doesn't perturb it either.
        #expect(result.candidates == existingCandidates)
    }

    /// Safety bail-out (review finding 4): a fetch failure upstream of `decide` can surface as an
    /// empty `referenced` set even though the library genuinely has articles — indistinguishable,
    /// from inside this function, from "confirmed nothing is used". Since every feed normally has
    /// a logo, `hasArticles == true && referenced.isEmpty` is treated as untrustworthy input, not
    /// as ground truth, and nothing is decided at all.
    @Test func emptyReferencedSetWithArticlesPresentBailsWithNoDeletions() {
        let firstSeen = now.addingTimeInterval(-quarantine - 1)
        let existingCandidates: [String: Date] = ["h1": firstSeen]
        let result = ImagePrunePlan.decide(
            referenced: [],
            stored: ["h1", "h2"],
            candidates: existingCandidates,
            now: now,
            quarantinePeriod: quarantine,
            hasArticles: true,
            hasUnmigratedLegacyContent: false,
            hasUndecodableBlocks: false
        )
        #expect(result.toDelete.isEmpty)
        #expect(result.candidates == existingCandidates)
    }

    /// Safety bail-out (review finding 4): an article still holding legacy pre-migration HTML has
    /// empty `blocks` until `BlockMigrator` sweeps it, so its in-body images are invisible to
    /// `referenced` — pruning while this is true risks deleting images that are actually in use.
    @Test func unmigratedLegacyContentBailsWithNoDeletions() {
        let firstSeen = now.addingTimeInterval(-quarantine - 1)
        let existingCandidates: [String: Date] = ["h1": firstSeen]
        let result = ImagePrunePlan.decide(
            referenced: ["logo"],
            stored: ["h1"],
            candidates: existingCandidates,
            now: now,
            quarantinePeriod: quarantine,
            hasArticles: true,
            hasUnmigratedLegacyContent: true,
            hasUndecodableBlocks: false
        )
        #expect(result.toDelete.isEmpty)
        #expect(result.candidates == existingCandidates)
    }

    /// Review finding 1: an article whose `blockData` fails to decode (e.g. an older build reading
    /// a `Block`/`Embed.Kind` case a newer build wrote) reports zero in-body images to `referenced`
    /// via `Article.blocks`'s `try?`-swallowing getter, exactly like the unmigrated-legacy-content
    /// case above but with a different cause. Must bail the same way.
    @Test func undecodableBlocksBailsWithNoDeletions() {
        let firstSeen = now.addingTimeInterval(-quarantine - 1)
        let existingCandidates: [String: Date] = ["h1": firstSeen]
        let result = ImagePrunePlan.decide(
            referenced: ["logo"],
            stored: ["h1"],
            candidates: existingCandidates,
            now: now,
            quarantinePeriod: quarantine,
            hasArticles: true,
            hasUnmigratedLegacyContent: false,
            hasUndecodableBlocks: true
        )
        #expect(result.toDelete.isEmpty)
        #expect(result.candidates == existingCandidates)
    }

    /// Review finding 3: an unbounded pass could delete (and hand CloudKit) tens of thousands of
    /// records in one go on a large backlog. `maxDeletionsPerPass` caps a single pass; anything
    /// past the cap stays a quarantined candidate for the next pass instead of being dropped.
    @Test func maxDeletionsPerPassCapsAndDefersRemainder() {
        let firstSeen = now.addingTimeInterval(-quarantine - 1)
        let candidates: [String: Date] = ["a": firstSeen, "b": firstSeen, "c": firstSeen]
        let result = ImagePrunePlan.decide(
            referenced: ["logo"],
            stored: ["a", "b", "c"],
            candidates: candidates,
            now: now,
            quarantinePeriod: quarantine,
            maxDeletionsPerPass: 2,
            hasArticles: true,
            hasUnmigratedLegacyContent: false,
            hasUndecodableBlocks: false
        )
        #expect(result.toDelete == ["a", "b"])
        // "c" is still eligible (past quarantine) but deferred — its original timestamp is kept,
        // not reset, so it's picked up (and capped again if needed) on the next pass.
        #expect(result.candidates == ["c": firstSeen])
    }
}

/// The SwiftData half: `ImagePruneRunner`'s `storedHashes`/`deleteRows` on its own `@ModelActor`
/// context.
@MainActor
@Suite("ImagePruneRunner")
struct ImagePruneRunnerTests {
    private func container() throws -> ModelContainer {
        let config = ModelConfiguration(isStoredInMemoryOnly: true, cloudKitDatabase: .none)
        return try ModelContainer(
            for: Feed.self, Yana.Tag.self, Article.self, StoredImage.self,
            configurations: config
        )
    }

    @Test func storedHashesEmptyOnEmptyLibrary() async throws {
        let container = try container()
        let storedHashes = await ImagePruneRunner(modelContainer: container).storedHashes()
        #expect(storedHashes.isEmpty)
    }

    @Test func storedHashesReportsEveryStoredImageRow() async throws {
        let container = try container()
        let ctx = ModelContext(container)
        ctx.insert(StoredImage(contentHash: "h1", data: Data([1]), ext: "png"))
        ctx.insert(StoredImage(contentHash: "h2", data: Data([2]), ext: "jpg"))
        try ctx.save()

        let storedHashes = await ImagePruneRunner(modelContainer: container).storedHashes()
        #expect(storedHashes == ["h1", "h2"])
    }

    @Test func deleteRowsRemovesOnlyTheGivenHashes() async throws {
        let container = try container()
        let ctx = ModelContext(container)
        ctx.insert(StoredImage(contentHash: "keep", data: Data([1]), ext: "png"))
        ctx.insert(StoredImage(contentHash: "drop", data: Data([2]), ext: "png"))
        try ctx.save()

        let deleted = await ImagePruneRunner(modelContainer: container).deleteRows(hashes: ["drop"])
        #expect(deleted == 1)

        let remaining = try ctx.fetch(FetchDescriptor<StoredImage>()).map(\.contentHash)
        #expect(remaining == ["keep"])
    }

    @Test func deleteRowsWithEmptySetDeletesNothing() async throws {
        let container = try container()
        let ctx = ModelContext(container)
        ctx.insert(StoredImage(contentHash: "keep", data: Data([1]), ext: "png"))
        try ctx.save()

        let deleted = await ImagePruneRunner(modelContainer: container).deleteRows(hashes: [])
        #expect(deleted == 0)
        #expect(try ctx.fetch(FetchDescriptor<StoredImage>()).count == 1)
    }

    /// Review finding 3: deletes must be batched (saved every `batchSize`, not once at the end).
    /// A small `batchSize` here forces multiple save boundaries; correctness across those
    /// boundaries — nothing lost, nothing double-handled — is what would break if the batching
    /// were off by one.
    @Test func deleteRowsBatchesAcrossMultipleSaves() async throws {
        let container = try container()
        let ctx = ModelContext(container)
        let hashes = (1...5).map { "h\($0)" }
        for hash in hashes {
            ctx.insert(StoredImage(contentHash: hash, data: Data([1]), ext: "png"))
        }
        try ctx.save()

        let deleted = await ImagePruneRunner(modelContainer: container)
            .deleteRows(hashes: Set(hashes), batchSize: 2)
        #expect(deleted == 5)
        #expect(try ctx.fetch(FetchDescriptor<StoredImage>()).isEmpty)
    }
}

/// `ImagePruneCandidateStore`'s `UserDefaults` round-trip. Uses a private suite so it never
/// touches (or is polluted by) the app's real `UserDefaults.standard`.
@Suite("ImagePruneCandidateStore")
struct ImagePruneCandidateStoreTests {
    private func freshDefaults() -> UserDefaults {
        let suiteName = "ImagePruneCandidateStoreTests-\(UUID().uuidString)"
        let defaults = UserDefaults(suiteName: suiteName)!
        defaults.removePersistentDomain(forName: suiteName)
        return defaults
    }

    @Test func loadOnFreshDefaultsReturnsEmptyMap() {
        #expect(ImagePruneCandidateStore.load(defaults: freshDefaults()).isEmpty)
    }

    @Test func savedCandidatesRoundTrip() {
        let defaults = freshDefaults()
        let firstSeen = Date(timeIntervalSince1970: 1_700_000_000)
        let candidates = ["h1": firstSeen, "h2": firstSeen.addingTimeInterval(60)]
        ImagePruneCandidateStore.save(candidates, defaults: defaults)
        let loaded = ImagePruneCandidateStore.load(defaults: defaults)
        #expect(loaded == candidates)
    }
}

/// `AggregationWriter.referencedImageSnapshotForPruning()` — the failure-surfacing scan that
/// `ImagePrunePlan`'s safety guards depend on (review finding 4).
@MainActor
@Suite("ReferencedImageSnapshotForPruning")
struct ReferencedImageSnapshotForPruningTests {
    private func container() throws -> ModelContainer {
        let config = ModelConfiguration(isStoredInMemoryOnly: true, cloudKitDatabase: .none)
        return try ModelContainer(
            for: Feed.self, Yana.Tag.self, Article.self, StoredImage.self,
            configurations: config
        )
    }

    @Test func reportsNoArticlesOnEmptyLibrary() async throws {
        let container = try container()
        let snapshot = await AggregationWriter(modelContainer: container).referencedImageSnapshotForPruning()
        let unwrapped = try #require(snapshot)
        #expect(unwrapped.hasArticles == false)
        #expect(unwrapped.hashes.isEmpty)
        #expect(unwrapped.hasUnmigratedLegacyContent == false)
        #expect(unwrapped.hasUndecodableBlocks == false)
    }

    @Test func flagsUnmigratedLegacyContent() async throws {
        let container = try container()
        let ctx = ModelContext(container)
        let article = Article(title: "a", identifier: "a1", url: "u", author: "", iconURL: nil)
        article.content = "<p>legacy html, not yet swept to blocks</p>"
        ctx.insert(article)
        try ctx.save()

        let snapshot = await AggregationWriter(modelContainer: container).referencedImageSnapshotForPruning()
        let unwrapped = try #require(snapshot)
        #expect(unwrapped.hasArticles == true)
        #expect(unwrapped.hasUnmigratedLegacyContent == true)
        #expect(unwrapped.hasUndecodableBlocks == false)
    }

    /// Review finding 1: an article whose `blockData` is non-empty but fails to decode as `[Block]`
    /// (simulating an older build reading a newer build's article after an enum case was added)
    /// must set `hasUndecodableBlocks`, not silently report zero in-body images via `Article.blocks`'s
    /// `try?`-swallowing getter. Setting `blockData` directly (bypassing the `blocks` setter, which
    /// always encodes valid JSON) is the cheap way to construct this without a real decode failure.
    @Test func flagsUndecodableBlocks() async throws {
        let container = try container()
        let ctx = ModelContext(container)
        let article = Article(title: "a", identifier: "a1", url: "u", author: "", iconURL: nil)
        article.blockData = Data("not valid block json".utf8)
        ctx.insert(article)
        try ctx.save()

        let snapshot = await AggregationWriter(modelContainer: container).referencedImageSnapshotForPruning()
        let unwrapped = try #require(snapshot)
        #expect(unwrapped.hasArticles == true)
        #expect(unwrapped.hasUnmigratedLegacyContent == false)
        #expect(unwrapped.hasUndecodableBlocks == true)
    }

    /// A legitimately empty body encodes to `[]` (non-empty `Data`, empty array) — this must NOT be
    /// mistaken for an undecodable body. Guards against the "just check `blocks.isEmpty`" mistake
    /// the finding explicitly warns off (that would disable the prune permanently).
    @Test func emptyBlocksArrayIsNotFlaggedAsUndecodable() async throws {
        let container = try container()
        let ctx = ModelContext(container)
        let article = Article(title: "a", identifier: "a1", url: "u", author: "", iconURL: nil)
        article.blocks = []   // goes through the real setter: encodes to valid, empty-array JSON
        ctx.insert(article)
        try ctx.save()

        let snapshot = await AggregationWriter(modelContainer: container).referencedImageSnapshotForPruning()
        let unwrapped = try #require(snapshot)
        #expect(unwrapped.hasArticles == true)
        #expect(unwrapped.hasUndecodableBlocks == false)
    }

    @Test func hasArticlesAndReferencedComeFromTheSameScan() async throws {
        let container = try container()
        let ctx = ModelContext(container)
        let feed = Feed(name: "F", aggregatorType: .feedContent, identifier: "f1")
        feed.logoHash = "logohash"
        ctx.insert(feed)
        let article = Article(title: "a", identifier: "a1", url: "u", author: "", iconURL: nil)
        article.feed = feed
        ctx.insert(article)
        try ctx.save()

        let snapshot = await AggregationWriter(modelContainer: container).referencedImageSnapshotForPruning()
        let unwrapped = try #require(snapshot)
        #expect(unwrapped.hasArticles == true)
        #expect(unwrapped.hashes.contains("logohash"))
        #expect(unwrapped.hasUnmigratedLegacyContent == false)
    }
}
