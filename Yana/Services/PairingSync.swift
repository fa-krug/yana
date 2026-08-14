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
        settings: AppSettings = AppSettings()
    ) {
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
