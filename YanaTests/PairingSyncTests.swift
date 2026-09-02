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
            settings: settings,
            monitor: OperationMonitor(activity: UpdateActivity())
        )

        #expect(settings.hasCompletedInitialSync == false)
    }

    /// A fresh pairing may point at a different server entirely, and job/run ids collide freely
    /// across servers -- so a `TrackedOperation` recorded before the re-pair must not survive it,
    /// or `OperationMonitor.resume()` would poll an old server's id against the new one and apply
    /// whatever it found to whichever local row now holds that article id.
    @Test func resetClearsTrackedOperationsScopedToThePreviousServer() {
        let settings = AppSettings(defaults: UserDefaults(suiteName: "PairingSync.\(UUID())")!)
        settings.trackedOperations = [
            TrackedOperation(kind: .updateAll, id: 7, startedAt: .now)
        ]

        KeychainService.deleteDeviceToken()
        PairingSync.resetAndFullSync(
            appState: AppState(),
            articleStore: ArticleStore(container: AppContainer.shared),
            settings: settings,
            monitor: OperationMonitor(activity: UpdateActivity())
        )

        #expect(settings.trackedOperations.isEmpty)
    }
}
