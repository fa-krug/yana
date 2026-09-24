import Foundation
import SwiftData
import Testing
@testable import Yana

/// `InitialSyncGate.run`'s `syncOnce` seam lets these tests exercise its retry/failure-flag logic
/// without a real network round-trip -- see `task-17-brief.md`. `client` is constructed but never
/// actually used once `syncOnce` is injected, matching `SyncEngineTests`' throwaway-container
/// pattern.
@MainActor
@Suite("InitialSyncGate")
struct InitialSyncGateTests {
    private func makeContainer() throws -> ModelContainer {
        try ModelContainer(for: Article.self, Feed.self, Tag.self, configurations: .init(isStoredInMemoryOnly: true))
    }

    private func makeSettings() -> AppSettings {
        AppSettings(defaults: UserDefaults(suiteName: "InitialSyncGateTests.\(UUID())")!)
    }

    @Test func failedFirstSyncSetsFailureFlagAndDoesNotMarkComplete() async throws {
        let container = try makeContainer()
        let client = YanaAPIClient(baseURL: URL(string: "https://example.test")!, token: "t")
        let store = ArticleStore(container: container)
        let settings = makeSettings()
        let appState = AppState()
        settings.hasCompletedInitialSync = false
        struct Boom: Error {}

        await InitialSyncGate.run(
            container: container, client: client, articleStore: store,
            appState: appState, settings: settings,
            retryDelay: .milliseconds(1),
            syncOnce: { throw Boom() }
        )

        #expect(appState.initialSyncFailed)
        #expect(!settings.hasCompletedInitialSync)
        #expect(!appState.isPerformingInitialSync)
    }

    @Test func successfulFirstSyncClearsFailureAndMarksComplete() async throws {
        let container = try makeContainer()
        let client = YanaAPIClient(baseURL: URL(string: "https://example.test")!, token: "t")
        let store = ArticleStore(container: container)
        let settings = makeSettings()
        let appState = AppState()
        appState.initialSyncFailed = true
        settings.hasCompletedInitialSync = false

        await InitialSyncGate.run(
            container: container, client: client, articleStore: store,
            appState: appState, settings: settings,
            retryDelay: .milliseconds(1),
            syncOnce: {}
        )

        #expect(!appState.initialSyncFailed)
        #expect(settings.hasCompletedInitialSync)
    }

    /// A sync stopped because the server connection was removed mid-way must end the gate
    /// quietly: no retry (it would pull the old server's backlog into the demo library), no
    /// "couldn't reach your server" screen, and no completion flag for a pairing that is gone.
    @Test func pairingChangedEndsTheGateWithoutRetryFailureOrCompletion() async throws {
        let container = try makeContainer()
        let client = YanaAPIClient(baseURL: URL(string: "https://example.test")!, token: "t")
        let store = ArticleStore(container: container)
        let settings = makeSettings()
        let appState = AppState()
        settings.hasCompletedInitialSync = false
        var attempts = 0

        await InitialSyncGate.run(
            container: container, client: client, articleStore: store,
            appState: appState, settings: settings,
            retryDelay: .milliseconds(1),
            syncOnce: {
                attempts += 1
                throw SyncEngineError.pairingChanged
            }
        )

        #expect(attempts == 1)
        #expect(!appState.initialSyncFailed)
        #expect(!settings.hasCompletedInitialSync)
        #expect(!appState.isPerformingInitialSync)
    }
}
