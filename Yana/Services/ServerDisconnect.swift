import Foundation
import SwiftData

/// Un-pairs this device from its Yana Server: deletes the stored Bearer token, clears the server
/// address, wipes every locally mirrored `Article`/`Feed`/`Tag`, and falls back into the same
/// demo-content mode `OnboardingServerPage`'s "Skip for now" already offers -- see
/// docs/superpowers/specs/2026-08-14-remove-server-connection-design.md. Mirrors `PairingSync`'s
/// shape, just running the transition in reverse.
enum ServerDisconnect {
    @MainActor
    static func disconnect(settings: AppSettings, context: ModelContext = AppContainer.shared.mainContext) {
        // Best-effort mitigation: cancel whichever foreground update (pull-to-refresh "Update
        // All", article reload, the reader's periodic refresh) `UpdateActivity` is currently
        // tracking, so it can't keep writing through SyncEngine/SyncWriter after the wipe below
        // and resurrect articles or re-set `syncCursor`. This does NOT cover
        // `BackgroundRefreshManager` or `InitialSyncGate`, which run their syncs outside
        // `UpdateActivity` entirely and are therefore not cancellable this way -- a full fix
        // would require `SyncEngine` to re-check `AuthenticatedClient.current()` before every
        // write batch, which is out of scope here.
        UpdateActivity.shared.cancel()

        KeychainService.deleteDeviceToken()
        settings.serverBaseURL = ""
        LocalLibraryReset.wipe(context: context)
        settings.hasSkippedServerPairing = true

        // Clear old-server-scoped pending state so it can never be replayed against a different
        // server paired later: SyncEngine.performSync() flushes these queues at the top of every
        // sync, with no server-identity check.
        settings.pendingWrites = []
        settings.pendingReadingPositionPush = nil
        settings.pendingRemoteReadingPosition = nil
        settings.readingPositionUpdatedAt = nil

        // Reset the per-session demo-banner dismissal so a user who dismissed it earlier this
        // session still sees it explain the newly-appeared demo content.
        settings.hasDismissedDemoBanner = false

        Task {
            await ScreenshotSeed.seed(into: context)
        }
    }
}
