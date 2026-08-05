import Foundation
import SwiftData

/// Coordinates a server-triggered write (`ArticleActions.reload`/`updateAll`) with pulling its
/// results back down. Both of those calls only ack that the server *started* work -- a reload/
/// aggregate run finishes asynchronously, with no fixed latency -- so a caller that wants to show
/// the result must follow up with `SyncEngine.sync()` itself, not assume the ack delivered content.
///
/// The design spec (`docs/superpowers/specs/2026-08-05-server-api-client-rework-design.md`)
/// documents a `GET /runs/:id` job-status endpoint for precise completion detection, but its
/// response shape isn't pinned down anywhere in this codebase or in Task 13's `ArticleActions`
/// interface (which deliberately exposes only `setStarred`/`reload`/`updateAll`), and guessing at
/// an unspecified wire format would be worse than not polling it at all. Instead this polls the
/// already-specified, already-tested `/articles/sync` endpoint (via `SyncEngine.sync()`) a few
/// times with a short backoff, stopping as soon as a pass reports any change. This is a bounded
/// heuristic, not a guarantee -- a slow server-side run can still finish after the last attempt,
/// in which case the next manual refresh or background sync (Task 14) picks it up.
@MainActor
enum UpdateAndSync {
    /// Backoff between poll attempts. Worst case ~9s before giving up.
    private static let delays: [Duration] = [.seconds(1), .seconds(2), .seconds(2), .seconds(2), .seconds(2)]

    /// Repeatedly calls `SyncEngine.sync()` until a pass reports a change or attempts run out.
    /// Returns the last `SyncResult` observed (all zeros if nothing arrived in time). Cooperatively
    /// cancellable: bails immediately once the enclosing `Task` is cancelled, returning whatever
    /// was last observed.
    ///
    /// Used by `updateAll()`'s "Update" flow only, where the counts genuinely flow through
    /// `/articles/sync`'s summary page loop. **Not used by `reload()`'s flow** -- a single
    /// article's re-fetched content comes from `backfillMissingContent()`'s `hasContent`-gated
    /// scan, which contributes nothing to these counters, so this method's termination check can
    /// never actually observe a reload landing. See `pollForReloadedContent` for that path.
    @discardableResult
    static func pollForFreshContent(
        container: ModelContainer, client: YanaAPIClient, settings: AppSettings
    ) async -> SyncResult {
        let engine = SyncEngine(container: container, client: client, settings: settings)
        var last = SyncResult(newCount: 0, updatedCount: 0, removedCount: 0)
        for delay in delays {
            if Task.isCancelled { return last }
            try? await Task.sleep(for: delay)
            if Task.isCancelled { return last }
            last = (try? await engine.sync()) ?? last
            if last.newCount > 0 || last.updatedCount > 0 || last.removedCount > 0 { return last }
        }
        return last
    }

    /// Re-fetches ONE article's content directly, bypassing `SyncEngine`'s generic
    /// `hasContent`-gated backfill scan entirely, on every attempt of the same bounded backoff
    /// schedule -- overwriting each time rather than stopping at the first successful fetch.
    ///
    /// This exists specifically for `reload()`: the server's reload job is asynchronous, so a
    /// content fetch this early in the window can land *before* the server has actually finished
    /// re-fetching -- getting the pre-reload content back. Going through the backfill scan
    /// instead (as an earlier version of this code did, resetting `hasContent = false` first) is
    /// actively wrong for this case, not just imprecise: `articlesMissingContent`'s predicate is a
    /// one-way `hasContent == false` gate, so a premature backfill fetch sets `hasContent = true`
    /// and *permanently* blocks any later retry -- not just for this poll window, but forever,
    /// since nothing else ever resets it back to `false`. Calling `applyContent` directly here has
    /// no such gate: a premature fetch is simply overwritten by the next attempt a few seconds
    /// later, converging on the freshest content the window happened to observe.
    ///
    /// There is no reliable way to tell whether the content actually *changed* (the server may
    /// legitimately return byte-identical content if the reload found nothing new), so this
    /// returns `true` as soon as *any* attempt successfully applies content -- "we re-fetched and
    /// applied within the window" is treated as reload's success signal, matching what "Reload"
    /// has always meant in this app (re-fetch in place, not detect-a-change).
    @discardableResult
    static func pollForReloadedContent(
        articleServerID: Int, container: ModelContainer, client: YanaAPIClient
    ) async -> Bool {
        var appliedAtLeastOnce = false
        for delay in delays {
            if Task.isCancelled { return appliedAtLeastOnce }
            try? await Task.sleep(for: delay)
            if Task.isCancelled { return appliedAtLeastOnce }
            guard let document: WireDocument = try? await client.get(
                "/api/v1/articles/\(articleServerID)/content"
            ) else { continue }
            // `SyncWriter` is a `@ModelActor` -- per this codebase's rule, every call into one
            // from a `@MainActor` context (this enum) must be hopped off-main via
            // `OffMainActor.run`, or the write runs inline on the calling (main) thread. Mirrors
            // `SyncEngine.syncFeeds()`'s exact pattern: construct on the caller's actor, wrap only
            // the `await` into the actor.
            let writer = SyncWriter(modelContainer: container)
            let applied = await OffMainActor.run {
                await writer.applyContent(articleServerID: articleServerID, document: document)
            }
            appliedAtLeastOnce = appliedAtLeastOnce || applied
        }
        return appliedAtLeastOnce
    }
}
