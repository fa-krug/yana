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
            referenced: [],
            stored: ["h1"],
            candidates: [:],
            now: now,
            quarantinePeriod: quarantine,
            hasArticles: true
        )
        #expect(result.toDelete.isEmpty)
        #expect(result.candidates == ["h1": now])
    }

    @Test func unreferencedHashOlderThanQuarantineIsDeleted() {
        let firstSeen = now.addingTimeInterval(-quarantine - 1)
        let result = ImagePrunePlan.decide(
            referenced: [],
            stored: ["h1"],
            candidates: ["h1": firstSeen],
            now: now,
            quarantinePeriod: quarantine,
            hasArticles: true
        )
        #expect(result.toDelete == ["h1"])
        #expect(result.candidates.isEmpty)
    }

    @Test func unreferencedHashYoungerThanQuarantineIsNotDeleted() {
        let firstSeen = now.addingTimeInterval(-3600)   // 1 hour ago, well under 24h
        let result = ImagePrunePlan.decide(
            referenced: [],
            stored: ["h1"],
            candidates: ["h1": firstSeen],
            now: now,
            quarantinePeriod: quarantine,
            hasArticles: true
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
            hasArticles: true
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
            hasArticles: true
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
            hasArticles: false
        )
        #expect(result.toDelete.isEmpty)
        // Candidate map passes through untouched — an incomplete run doesn't perturb it either.
        #expect(result.candidates == existingCandidates)
    }
}

/// The SwiftData half: `ImagePruneRunner`'s `snapshot`/`deleteRows` on its own `@ModelActor`
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

    @Test func snapshotReportsNoArticlesOnEmptyLibrary() async throws {
        let container = try container()
        let (hasArticles, storedHashes) = await ImagePruneRunner(modelContainer: container).snapshot()
        #expect(hasArticles == false)
        #expect(storedHashes.isEmpty)
    }

    @Test func snapshotReportsArticlesAndStoredHashes() async throws {
        let container = try container()
        let ctx = ModelContext(container)
        ctx.insert(Article(title: "a", identifier: "a1", url: "u", author: "", iconURL: nil))
        ctx.insert(StoredImage(contentHash: "h1", data: Data([1]), ext: "png"))
        ctx.insert(StoredImage(contentHash: "h2", data: Data([2]), ext: "jpg"))
        try ctx.save()

        let (hasArticles, storedHashes) = await ImagePruneRunner(modelContainer: container).snapshot()
        #expect(hasArticles == true)
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
