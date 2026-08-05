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
}
