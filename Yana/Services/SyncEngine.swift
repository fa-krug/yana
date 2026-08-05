import Foundation
import SwiftData

struct SyncResult: Sendable, Equatable {
    let newCount: Int
    let updatedCount: Int
    let removedCount: Int
}

private struct SyncPage: Decodable {
    let new: [SyncArticleSummaryWire]?
    let updated: [SyncArticleSummaryWire]?
    let removed: [Int]?
    let nextCursor: String?
    let resyncRequired: Bool?
}

private struct FeedsResponse: Decodable { let feeds: [SyncFeedWire] }

/// Offline-first sync: a full pass replicates the server's article set -- summaries, full block
/// content, and every referenced image -- into the local SwiftData mirror, not just metadata.
/// Content/image fetches are eager, not lazy-on-render; see the design spec's "Local persistence"
/// decision for why (full-text search and true offline reading both depend on it).
@MainActor
final class SyncEngine {
    private let container: ModelContainer
    private let client: YanaAPIClient
    private let settings: AppSettings
    private let maxConcurrentContentFetches = 6

    /// Pagination page size for `/api/v1/articles/sync`. A page shorter than this means the
    /// server has caught up to head -- see the loop's termination check in `sync()`.
    private let pageLimit = 200

    init(container: ModelContainer, client: YanaAPIClient, settings: AppSettings = AppSettings()) {
        self.container = container
        self.client = client
        self.settings = settings
    }

    @discardableResult
    func sync() async throws -> SyncResult {
        var totalNew = 0, totalUpdated = 0, totalRemoved = 0

        try await syncFeeds()

        while true {
            let page: SyncPage = try await client.get(
                "/api/v1/articles/sync",
                query: settings.syncCursor.map { ["cursor": $0, "limit": "\(pageLimit)"] } ?? ["limit": "\(pageLimit)"]
            )

            if page.resyncRequired == true {
                // The server no longer recognizes our cursor (e.g. it expired, or the export it
                // pointed into was compacted). Clearing it and looping starts a fresh full sync
                // from the beginning rather than giving up -- this is the one case where the loop
                // deliberately does NOT advance on this iteration.
                settings.syncCursor = nil
                continue
            }

            let newSummaries = page.new ?? []
            let updatedSummaries = page.updated ?? []
            let removed = page.removed ?? []

            let writer = SyncWriter(modelContainer: container)
            _ = await OffMainActor.run { await writer.upsertSummaries(newSummaries) }
            _ = await OffMainActor.run { await writer.upsertSummaries(updatedSummaries) }
            await OffMainActor.run { await writer.applyRemovals(removed) }

            totalNew += newSummaries.count
            totalUpdated += updatedSummaries.count
            totalRemoved += removed.count

            settings.syncCursor = page.nextCursor

            // A page with fewer than the full limit means we've caught up to head.
            let fullPage = (newSummaries.count + updatedSummaries.count) >= pageLimit
            if !fullPage { break }
        }

        try await backfillMissingContent()

        return SyncResult(newCount: totalNew, updatedCount: totalUpdated, removedCount: totalRemoved)
    }

    private func syncFeeds() async throws {
        let response: FeedsResponse = try await client.get("/api/v1/feeds")
        let writer = SyncWriter(modelContainer: container)
        _ = await OffMainActor.run { await writer.replaceFeeds(response.feeds) }
    }

    /// Fetches full content for every locally-known article that doesn't have it yet, at
    /// bounded concurrency. A dropped connection here doesn't lose progress -- the cursor has
    /// already advanced past these articles' summaries, so this backfill (driven by
    /// `hasContent == false`, not by re-listing from `/articles/sync`) is what retries them on
    /// the next sync pass. Deliberately swallows individual fetch failures rather than aborting
    /// the whole pass -- a spotty connection should degrade to "some articles still pending,"
    /// not "sync failed."
    private func backfillMissingContent() async throws {
        let writer = SyncWriter(modelContainer: container)
        let pending = await OffMainActor.run { await writer.articlesMissingContent(limit: 500) }
        guard !pending.isEmpty else { return }

        // `articlesMissingContent` returns `persistentID` alongside `serverID`, but nothing below
        // needs the persistentID -- `SyncWriter.applyContent` re-resolves the article by
        // `serverID` itself (the two calls can race against a concurrent removal, and re-fetching
        // is what makes that race safe). Projecting down to `[Int]` also sidesteps passing a
        // tuple across the task-group's `@Sendable` boundary -- tuples can't satisfy an explicit
        // `Sendable` generic constraint, only their elements can.
        let serverIDs = pending.map(\.serverID)
        let client = client
        let container = container

        await runBounded(serverIDs, maxConcurrency: maxConcurrentContentFetches) { serverID in
            do {
                let document: WireDocument = try await client.get("/api/v1/articles/\(serverID)/content")
                let writer = SyncWriter(modelContainer: container)
                _ = await writer.applyContent(articleServerID: serverID, document: document)
            } catch {
                // Leave hasContent == false; picked up again on the next sync pass.
            }
        }
    }
}

/// Runs `work` over `items` at bounded concurrency via a sliding-window `withTaskGroup`: exactly
/// `maxConcurrency` tasks are in flight at once (fewer only once `items` itself runs out), and
/// each completion immediately refills the slot rather than waiting for a whole batch to finish --
/// so the queue drains continuously, never in lockstep chunks. `internal` (not `private`) purely
/// so `SyncEngineTests` can drive it directly with a synthetic slow `work` closure and assert the
/// bound is real: an end-to-end test through a mocked HTTP client can prove the *result* is
/// correct while still letting every task run essentially sequentially (a mock responds
/// instantly), which would hide a task group that leaks unbounded tasks or one that accidentally
/// serializes everything.
func runBounded<Item: Sendable>(
    _ items: [Item], maxConcurrency: Int, work: @escaping @Sendable (Item) async -> Void
) async {
    guard maxConcurrency > 0, !items.isEmpty else { return }

    await withTaskGroup(of: Void.self) { group in
        var iterator = items.makeIterator()

        func launchNext() {
            guard let item = iterator.next() else { return }
            group.addTask { await work(item) }
        }

        for _ in 0..<maxConcurrency { launchNext() }
        while await group.next() != nil {
            launchNext()
        }
    }
}
