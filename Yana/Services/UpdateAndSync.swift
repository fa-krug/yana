import Foundation
import SwiftData

/// Coordinates a server-triggered write (`ArticleActions.reload`/`updateAll`) with observing its
/// actual completion and pulling the result back down. Both triggers only ack that the server
/// *started* work; this type is what turns that ack into "the work is done, here's the outcome."
///
/// The two triggers are tracked completely differently server-side (confirmed by reading
/// `yana-server` directly -- see `docs/superpowers/specs/2026-08-05-server-api-client-rework-design.md:137-138`
/// for the intent this file implements):
/// - `updateAll()`'s `POST /aggregate` returns a `runId` that IS queryable via
///   `GET /api/v1/runs/:id` (`RunStatusResponse`) -- `pollForFreshContent` polls that REST
///   endpoint until the run is no longer `"running"`, then syncs exactly once.
/// - `reload()`'s `POST /articles/:id/reload` returns a `jobId` for a job with `runId: null` --
///   it is NOT part of a run, so `/runs/:id` can never see it, and there is no `GET /jobs/:id`.
///   The only place its completion surfaces is the per-user SSE stream `GET /api/v1/jobs/events`
///   (`JobEventsClient`), which emits a terminal `job` event exactly once. That stream is
///   documented server-side as best-effort, so `pollForReloadedContent` falls back to a single
///   direct content re-fetch if no matching terminal event arrives within `eventTimeout`.
@MainActor
enum UpdateAndSync {
    /// Polls `GET /api/v1/runs/:id` until the run's status is no longer `"running"` (or attempts
    /// run out), then runs `SyncEngine.sync()` exactly once to pull in whatever the run produced.
    /// Cooperatively cancellable: bails immediately once the enclosing `Task` is cancelled.
    @discardableResult
    static func pollForFreshContent(
        runId: Int, container: ModelContainer, client: YanaAPIClient, settings: AppSettings,
        pollInterval: Duration = .seconds(1), maxAttempts: Int = 30
    ) async -> SyncResult {
        await waitForRunToFinish(runId: runId, client: client, pollInterval: pollInterval, maxAttempts: maxAttempts)
        guard !Task.isCancelled else {
            return SyncResult(newCount: 0, updatedCount: 0, removedCount: 0)
        }
        let engine = SyncEngine(container: container, client: client, settings: settings)
        return (try? await engine.sync()) ?? SyncResult(newCount: 0, updatedCount: 0, removedCount: 0)
    }

    private static func waitForRunToFinish(
        runId: Int, client: YanaAPIClient, pollInterval: Duration, maxAttempts: Int
    ) async {
        for _ in 0..<maxAttempts {
            if Task.isCancelled { return }
            guard let status: RunStatusResponse = try? await client.get("/api/v1/runs/\(runId)") else { return }
            if !status.isRunning { return }
            try? await Task.sleep(for: pollInterval)
        }
    }

    /// Waits for `/api/v1/jobs/events` to report this exact `jobId` reaching a terminal state,
    /// then -- only on `"completed"` -- re-fetches and applies that one article's content
    /// directly, bypassing `SyncEngine`'s generic `hasContent`-gated backfill entirely (an earlier
    /// version of this code went through that backfill, resetting `hasContent = false` first, and
    /// that is actively wrong: a premature backfill fetch racing the poll sets `hasContent = true`
    /// and permanently blocks any later retry, since nothing else ever resets it). If the job
    /// reports `"failed"`/`"cancelled"`, there is nothing new to fetch, so this returns `false`
    /// without a network call. If no matching terminal event arrives within `eventTimeout` (a
    /// dropped SSE connection, or the event simply being missed -- the stream is best-effort),
    /// this falls back to exactly one direct content fetch, matching what this method has always
    /// done as its fallback path.
    @discardableResult
    static func pollForReloadedContent(
        jobId: Int, articleServerID: Int, container: ModelContainer, client: YanaAPIClient,
        eventTimeout: Duration = .seconds(30)
    ) async -> Bool {
        switch await waitForReloadJobOutcome(jobId: jobId, client: client, eventTimeout: eventTimeout) {
        case .some(false):
            return false
        case .some(true), .none:
            return await fetchAndApplyContent(articleServerID: articleServerID, container: container, client: client)
        }
    }

    /// `true` = the matching job completed; `false` = it failed/was cancelled; `nil` = no matching
    /// terminal event arrived before `eventTimeout` (dropped connection, missed event, or the
    /// stream simply ended without ever mentioning this job).
    private static func waitForReloadJobOutcome(
        jobId: Int, client: YanaAPIClient, eventTimeout: Duration
    ) async -> Bool? {
        await withTaskGroup(of: Bool?.self) { group in
            group.addTask {
                var iterator = JobEventsClient(client: client).events().makeAsyncIterator()
                while let event = try? await iterator.next() {
                    if case let .job(payload) = event, payload.jobId == jobId, payload.isTerminal {
                        return payload.status == "completed"
                    }
                }
                return nil
            }
            group.addTask {
                try? await Task.sleep(for: eventTimeout)
                return nil
            }
            defer { group.cancelAll() }
            for await result in group {
                return result
            }
            return nil
        }
    }

    private static func fetchAndApplyContent(
        articleServerID: Int, container: ModelContainer, client: YanaAPIClient
    ) async -> Bool {
        guard let document: WireDocument = try? await client.get(
            "/api/v1/articles/\(articleServerID)/content"
        ) else { return false }
        // `SyncWriter` is a `@ModelActor` -- per this codebase's rule, every call into one from a
        // `@MainActor` context (this enum) must be hopped off-main via `OffMainActor.run`, or the
        // write runs inline on the calling (main) thread.
        let writer = SyncWriter(modelContainer: container)
        return await OffMainActor.run {
            await writer.applyContent(articleServerID: articleServerID, document: document)
        }
    }
}
