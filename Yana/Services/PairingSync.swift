import Foundation

/// Wipes the local library and kicks off a full server sync after a (re-)pairing succeeds --
/// shared by onboarding's "Continue" (`OnboardingServerPage`) and Settings' "change server" flow
/// (`ServerSettingsSection`), since both hand the app a fresh Bearer token that may point at a
/// different server than whatever was already mirrored locally, or the same server after a stale
/// local mirror. Fire-and-forget, routed through `UpdateActivity` so the app's shared spinner
/// shows for its duration, matching every other update-triggering action.
enum PairingSync {
    @MainActor
    static func resetAndFullSync() {
        LocalLibraryReset.wipe(context: AppContainer.shared.mainContext)
        guard let client = AuthenticatedClient.current() else { return }
        UpdateActivity.shared.restart {
            let engine = SyncEngine(container: AppContainer.shared, client: client)
            _ = try? await SyncCoordinator.shared.run { try await engine.sync() }
        }
    }
}
