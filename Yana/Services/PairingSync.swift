import Foundation

/// Wipes the local library and kicks off a full server sync after a (re-)pairing succeeds --
/// shared by onboarding's "Continue" (`OnboardingServerPage`) and Settings' "change server" flow
/// (`ServerSettingsSection`), since both hand the app a fresh Bearer token that may point at a
/// different server than whatever was already mirrored locally, or the same server after a stale
/// local mirror. Fire-and-forget, routed through `UpdateActivity` so the app's shared spinner
/// shows for its duration, matching every other update-triggering action.
enum PairingSync {
    @MainActor
    static func resetAndFullSync(
        appState: AppState,
        articleStore: ArticleStore,
        settings: AppSettings = AppSettings(),
        monitor: OperationMonitor = .shared
    ) {
        // The token that just arrived may point at an entirely different server, so everything
        // scoped to the previous one has to go before the new sync starts. An in-flight monitor is
        // the sharp edge: it would keep polling a job/run id from the old server against the new
        // one (ids collide freely across servers), and on a terminal status run `SyncEngine.sync()`
        // and write `/articles/<old serverID>/content` onto whatever row now holds that id.
        // `stopWatching` cancels those waits and drops the persisted `trackedOperations` records,
        // so `resume()` cannot replay them after a relaunch either.
        monitor.stopWatching(settings: settings)
        settings.trackedOperations = []
        // Picks the SSE progress feed back up under the new token: `startEvents` exits (and clears
        // its own task) when there is no client to build, which is the resting state of an
        // unpaired device, so a pairing that happens mid-session has to restart it explicitly.
        monitor.startEvents(settings: settings)
        LocalLibraryReset.wipe(context: AppContainer.shared.mainContext)
        // Whatever this device synced before says nothing about the backlog about to land: the
        // mirror was just wiped, and the token may well point at a different server entirely. So
        // this sync is a first sync again, and must go through `InitialSyncGate`'s blocking branch
        // (the full-screen `InitialSyncLoadingView`) rather than its fire-and-forget one -- both
        // on a fresh install and on a re-pair after "Remove Server Connection" or a server change.
        settings.hasCompletedInitialSync = false
        guard let client = AuthenticatedClient.current() else { return }
        UpdateActivity.shared.restart {
            await InitialSyncGate.run(
                container: AppContainer.shared, client: client,
                articleStore: articleStore, appState: appState, settings: settings
            )
        }
    }
}
