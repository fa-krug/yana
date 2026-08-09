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
private struct TagsResponse: Decodable { let tags: [SyncTagWire] }

enum SyncEngineError: Error, Equatable {
    /// The server returned `resyncRequired` on `SyncEngine.maxConsecutiveResyncAttempts`
    /// consecutive attempts within one `sync()` call. A single resync is the server telling us
    /// our cursor expired or was compacted -- normal, and handled by starting over. Getting it
    /// over and over inside the same call means something is persistently wrong (a server bug,
    /// or an account stuck in a bad state); looping forever inside a `@MainActor` method is worse
    /// than surfacing an error the caller can retry or report.
    case persistentResyncRequired
}

/// Offline-first sync: a full pass replicates the server's article set -- summaries, full block
/// content, and every referenced image -- into the local SwiftData mirror, not just metadata.
/// Content/image fetches are eager, not lazy-on-render; see the design spec's "Local persistence"
/// decision for why (full-text search and true offline reading both depend on it).
@MainActor
final class SyncEngine {
    private let container: ModelContainer
    private let client: YanaAPIClient
    private let settings: AppSettings
    /// Injectable purely so tests can point it at a throwaway on-disk directory instead of the
    /// real `ImageStore.shared` cache (`~/Library/Caches/images`) -- every other collaborator here
    /// is already injected the same way (`container`, `client`, `settings`).
    private let imageStore: ImageStore
    private let maxConcurrentContentFetches = 6

    /// Pagination page size for `/api/v1/articles/sync`. A page shorter than this means the
    /// server has caught up to head -- see the loop's termination check in `sync()`.
    private let pageLimit = 200

    /// Bounds the `resyncRequired` retry loop below. A single resync (cursor expired/compacted)
    /// is normal; this many *consecutive* ones inside one `sync()` call means something is
    /// persistently wrong server-side, and the loop must surface an error instead of spinning
    /// forever on the main actor.
    private static let maxConsecutiveResyncAttempts = 3

    init(container: ModelContainer, client: YanaAPIClient, settings: AppSettings = AppSettings(),
         imageStore: ImageStore = .shared) {
        self.container = container
        self.client = client
        self.settings = settings
        self.imageStore = imageStore
    }

    @discardableResult
    func sync() async throws -> SyncResult {
        do {
            return try await performSync()
        } catch YanaAPIClientError.unauthorized {
            // A session revoked from another device, or the token otherwise expired -- the
            // stored device token is now dead weight, and leaving it in Keychain would make sync
            // fail silently forever with no recovery path. Deleting it is enough on its own:
            // `AuthenticatedClient.current()` returns `nil` once the token is gone, and
            // `ContentView`'s existing re-pairing gate (`AuthenticatedClient.current() == nil`)
            // picks that up on the next app-foreground/launch check -- no new UI needed here.
            KeychainService.deleteDeviceToken()
            throw YanaAPIClientError.unauthorized
        }
    }

    private func performSync() async throws -> SyncResult {
        await PendingWriteQueue.flush(using: ArticleActions(client: client), settings: settings)

        var totalNew = 0, totalUpdated = 0, totalRemoved = 0
        var resyncAttempts = 0

        try await syncFeeds()
        try await syncTags()

        while true {
            let page: SyncPage = try await client.get(
                "/api/v1/articles/sync",
                query: settings.syncCursor.map { ["cursor": $0, "limit": "\(pageLimit)"] } ?? ["limit": "\(pageLimit)"]
            )

            if page.resyncRequired == true {
                resyncAttempts += 1
                guard resyncAttempts <= Self.maxConsecutiveResyncAttempts else {
                    throw SyncEngineError.persistentResyncRequired
                }
                // The server no longer recognizes our cursor (e.g. it expired, or the export it
                // pointed into was compacted). Clearing it and looping starts a fresh full sync
                // from the beginning rather than giving up -- this is the one case where the loop
                // deliberately does NOT advance on this iteration.
                settings.syncCursor = nil
                continue
            }
            resyncAttempts = 0

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

            // Only advance the cursor when the server actually provided one -- a `nil`
            // `nextCursor` on a normal (non-`resyncRequired`) page must leave the existing
            // cursor alone, not wipe it. Clearing it is `resyncRequired`'s job exclusively
            // (explicit `= nil` above); wiping it here too would force a full historical
            // re-download on the next sync for no reason.
            if let next = page.nextCursor {
                settings.syncCursor = next
            }

            // A page with fewer than the full limit means we've caught up to head. Counts
            // `removed` too, not just `new`/`updated` -- a page consisting mostly or entirely of
            // deletions would otherwise look short and stop the loop early even though the
            // server may have more pages queued.
            let fullPage = (newSummaries.count + updatedSummaries.count + removed.count) >= pageLimit
            if !fullPage { break }
        }

        try await backfillMissingContent()
        await pruneOrphanedImages()

        return SyncResult(newCount: totalNew, updatedCount: totalUpdated, removedCount: totalRemoved)
    }

    private func syncFeeds() async throws {
        let response: FeedsResponse = try await client.get("/api/v1/feeds")
        let writer = SyncWriter(modelContainer: container)
        _ = await OffMainActor.run { await writer.replaceFeeds(response.feeds) }

        let logoHashes = Set(response.feeds.compactMap(\.logoImageHash))
        let client = client
        let imageStore = imageStore
        await runBounded(Array(logoHashes), maxConcurrency: maxConcurrentContentFetches) { hash in
            _ = await imageStore.fetchIfNeeded(hash: hash, client: client)
        }
    }

    /// Sibling to `syncFeeds()`: `/tags` is small and unpaginated the same way, and populating
    /// the `Tag` table is what makes `Feed.tagIDs` resolvable into display names at all (see
    /// `ArticleSummary.tagNameLookup`/`Article.filterTagNames`). Without this call the `Tag`
    /// table stays permanently empty and every article reads as "untagged."
    private func syncTags() async throws {
        let response: TagsResponse = try await client.get("/api/v1/tags")
        let writer = SyncWriter(modelContainer: container)
        _ = await OffMainActor.run { await writer.syncTags(response.tags) }
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
        let imageStore = imageStore

        await runBounded(serverIDs, maxConcurrency: maxConcurrentContentFetches) { serverID in
            do {
                let document: WireDocument = try await client.get("/api/v1/articles/\(serverID)/content")
                let writer = SyncWriter(modelContainer: container)
                _ = await writer.applyContent(articleServerID: serverID, document: document)
                // Eager, not lazy-on-render: every image the article's body actually references
                // is fetched right alongside its content, not just the lead image on first open
                // (see `LeadImageReveal`'s bounded on-demand fallback for the rare case this
                // hasn't landed yet -- a stale/incomplete backfill, not the common path).
                await withTaskGroup(of: Void.self) { group in
                    for hash in Block.imageHashes(in: document.blocks) {
                        group.addTask { _ = await imageStore.fetchIfNeeded(hash: hash, client: client) }
                    }
                }
            } catch YanaAPIClientError.unauthorized {
                // This loop swallows every other failure by design (see the doc comment above),
                // so a revoked/expired session would otherwise never reach anything that clears
                // the stored token -- `sync()`'s top-level catch only sees errors thrown out of
                // `syncFeeds()`/`syncTags()`/the summary pagination loop, not this backfill's
                // per-item fetches. Same recovery, no rethrow: the other in-flight fetches still
                // get their chance, and the next sync attempt will fail fast on `syncFeeds()`
                // once the token is gone.
                KeychainService.deleteDeviceToken()
            } catch {
                // Leave hasContent == false; picked up again on the next sync pass.
            }
        }
    }

    /// Deletes any on-disk cached image no locally-known article or feed still references. Runs
    /// after removals/backfill have settled so a removed article's images (whether removed via
    /// `applyRemovals`'s explicit list, a feed's cascade-delete in `replaceFeeds`, or a local
    /// swipe-to-delete since the last sync) don't linger on disk forever -- `ImageStore` has no
    /// other path that ever deletes a blob once fetched. Pure local disk I/O (no network), so this
    /// runs even when the rest of the pass was offline/degraded.
    private func pruneOrphanedImages() async {
        let writer = SyncWriter(modelContainer: container)
        let referenced = await OffMainActor.run { await writer.referencedImageHashes() }
        let orphaned = await imageStore.allHashes().subtracting(referenced)
        for hash in orphaned {
            await imageStore.remove(forHash: hash)
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
