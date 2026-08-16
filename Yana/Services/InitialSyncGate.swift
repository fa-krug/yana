import Foundation
import SwiftData

/// Gates the reader behind a loading screen for the device's very first sync after pairing.
///
/// Sorting the timeline by the original article date (not import order) means a large historical
/// backfill can insert new unread articles anywhere in the currently-visible range rather than
/// appending them after the reading position -- fine once the mirror has caught up, but during the
/// very first sync (a full historical backlog landing in ~200-article pages, each triggering an
/// `ArticleStore` re-splice) it made swiping through the timeline jump to unrelated articles as
/// pages kept landing. Blocking the reader behind `AppState.isPerformingInitialSync` until this
/// exact sync -- and the index it drives -- has fully settled avoids that; every sync after the
/// first is a small incremental delta and never needs to gate anything.
@MainActor
enum InitialSyncGate {
    /// `SyncEngine.sync()` paginates the *entire* historical backlog inside one call (it only
    /// returns once a short page says the server caught up to head, or it throws) -- so a single
    /// successful call is already "every article landed." A transient failure partway through
    /// (a dropped connection, a `resyncRequired` exhaustion) must not be treated as done: that
    /// silently left older pages to trickle in later via the ordinary background sync path, with
    /// no gate left to catch them -- exactly the "very old articles keep appearing" report this
    /// retry loop fixes. Bounded so a persistently broken connection doesn't hang the launch
    /// forever; giving up here does NOT mark the sync complete, so the very next foreground/launch
    /// retries the gate from scratch instead of quietly accepting a partial mirror.
    private static let maxAttempts = 5

    static func run(
        container: ModelContainer,
        client: YanaAPIClient,
        articleStore: ArticleStore,
        appState: AppState,
        settings: AppSettings,
        retryDelay: Duration = .seconds(3),
        syncOnce: (() async throws -> Void)? = nil
    ) async {
        let sync: () async throws -> Void = syncOnce ?? {
            _ = try await SyncEngine(container: container, client: client).sync()
        }

        guard !settings.hasCompletedInitialSync else {
            try? await sync()
            return
        }

        appState.isPerformingInitialSync = true
        appState.initialSyncFailed = false
        var succeeded = false
        var unauthorized = false
        for attempt in 0..<maxAttempts {
            do {
                try await sync()
                succeeded = true
                break
            } catch YanaAPIClientError.unauthorized {
                // The token was just deleted by `SyncEngine.sync()` itself (session revoked from
                // another device, or expired) -- retrying with the same now-dead client can only
                // fail again. Give up; `ContentView`'s re-pairing gate picks this up on its own.
                unauthorized = true
                break
            } catch {
                guard attempt < maxAttempts - 1 else { break }
                try? await Task.sleep(for: retryDelay)
            }
        }

        if succeeded {
            // `SyncEngine.sync()` returning only guarantees the writes landed -- `ArticleStore`
            // debounces its own re-splice by up to 200ms (see `ArticleStore.start`), so an explicit
            // `refreshNow()` is what actually settles `summaries` before the gate lifts.
            await articleStore.refreshNow()
            settings.hasCompletedInitialSync = true
        } else if !unauthorized {
            // Unauthorized routes through the re-pairing gate instead (Task 16); everything else
            // is "couldn't reach the server" and gets an explicit retry state (audit U3).
            appState.initialSyncFailed = true
        }
        appState.isPerformingInitialSync = false
    }
}
