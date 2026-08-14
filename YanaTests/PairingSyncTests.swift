import Foundation
import Testing
import SwiftData
@testable import Yana

@MainActor
@Suite("PairingSync")
struct PairingSyncTests {
    /// Every pairing hands the app a token that may point at a different server, so whatever the
    /// device synced before says nothing about the backlog about to land. Clearing the flag is
    /// what routes the follow-up sync through `InitialSyncGate`'s blocking branch instead of its
    /// fire-and-forget one, which is what puts `InitialSyncLoadingView` on screen.
    @Test func resetClearsTheInitialSyncCompletionFlag() {
        let settings = AppSettings()
        settings.hasCompletedInitialSync = true
        defer { settings.hasCompletedInitialSync = false }

        // Unpaired: the wipe + flag reset still run, only the sync itself is skipped.
        KeychainService.deleteDeviceToken()
        PairingSync.resetAndFullSync(
            appState: AppState(),
            articleStore: ArticleStore(container: AppContainer.shared),
            settings: settings
        )

        #expect(settings.hasCompletedInitialSync == false)
    }
}
