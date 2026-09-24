import Foundation
import SwiftData

/// Un-pairs this device from its Yana Server: deletes the stored Bearer token, clears the server
/// address, wipes every locally mirrored `Article`/`Feed`/`Tag`, and falls back into the same
/// demo-content mode `OnboardingServerPage`'s "Skip for now" already offers -- see
/// docs/superpowers/specs/2026-08-14-remove-server-connection-design.md. Mirrors `PairingSync`'s
/// shape, just running the transition in reverse.
enum ServerDisconnect {
    @MainActor
    static func disconnect(settings: AppSettings, context: ModelContext = AppContainer.shared.mainContext,
                           monitor: OperationMonitor = .shared,
                           appState: AppState? = nil, articleStore: ArticleStore? = nil) {
        // Up before the wipe, so the window never shows the emptied library or the demo articles
        // trickling in; lowered only once the index reflects the finished seed.
        appState?.isLoadingDemoContent = true
        // Stop every operation this device is still waiting on. This is not cosmetic: a monitor
        // that survives the wipe below keeps polling the old server's job/run row and, on a
        // terminal status, runs `SyncEngine.sync()` with the old client -- resurrecting the
        // articles just deleted and re-setting `syncCursor`. `stopWatching` also drops the
        // persisted `trackedOperations` records, which is what stops `resume()` on a later launch
        // from replaying an old server's job id against a newly paired one (job ids collide freely
        // across servers, so a matching-but-unrelated completed job would have this device fetch
        // `/articles/<old serverID>/content` and write one article's body onto whatever row now
        // holds that id).
        monitor.stopWatching(settings: settings)
        // `UpdateActivity.cancel()` on top of that covers `PairingSync`'s own `restart`-wrapped
        // initial sync, the only thing still routed through `UpdateActivity.current`. It does NOT
        // cover `BackgroundRefreshManager` or `InitialSyncGate` called from elsewhere, which run
        // their syncs outside `UpdateActivity` entirely. Those are stopped by `SyncEngine` itself,
        // which re-checks the stored token before every write and throws `.pairingChanged` once
        // the deletion below lands; the seed task at the bottom waits for that to happen.
        UpdateActivity.shared.cancel()

        KeychainService.deleteDeviceToken()
        settings.serverBaseURL = ""
        LocalLibraryReset.wipe(context: context)
        settings.hasSkippedServerPairing = true

        // Clear old-server-scoped pending state so it can never be replayed against a different
        // server paired later: SyncEngine.performSync() flushes these queues at the top of every
        // sync, with no server-identity check.
        settings.pendingWrites = []
        // Already emptied by `stopWatching` above; restated here so the whole set of
        // old-server-scoped state a disconnect has to clear reads as one list, and so removing the
        // monitor call one day cannot silently leave these behind.
        settings.trackedOperations = []
        settings.pendingReadingPositionPush = nil
        settings.pendingRemoteReadingPosition = nil
        settings.readingPositionUpdatedAt = nil

        // Reset the per-session demo-banner dismissal so a user who dismissed it earlier this
        // session still sees it explain the newly-appeared demo content.
        settings.hasDismissedDemoBanner = false

        // The mirror is empty again, so whenever this device next pairs, that sync is once more a
        // full historical backlog -- exactly what `InitialSyncGate` exists to block the reader
        // behind. Leaving this set is what made the loading screen silently not appear on a
        // remove-then-re-add.
        settings.hasCompletedInitialSync = false

        Task {
            // A sync that was mid-page when the token went away can still finish the write it had
            // already started, after the wipe above. Wait for it to stop, then wipe again: the
            // seed below bails as soon as any `Feed` exists, so a single stray server feed left
            // behind would replace the demo library with the old server's articles.
            await SyncEngine.cancelAndWaitForInFlightSync(container: context.container)
            LocalLibraryReset.wipe(context: context)
            await ScreenshotSeed.seed(into: context)
            // The seed's saves reach `ArticleStore` through its debounced splice; settle the index
            // explicitly before the loading screen lifts, as `InitialSyncGate` does.
            await articleStore?.refreshNow()
            appState?.isLoadingDemoContent = false
        }
    }
}
