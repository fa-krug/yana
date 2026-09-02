import Foundation
import Testing
import SwiftData
@testable import Yana

@MainActor
@Suite("ServerDisconnect")
struct ServerDisconnectTests {
    private func inMemoryContext() throws -> ModelContext {
        let config = ModelConfiguration(isStoredInMemoryOnly: true, cloudKitDatabase: .none)
        let container = try ModelContainer(for: Feed.self, Tag.self, Article.self, configurations: config)
        return ModelContext(container)
    }

    @Test func disconnectClearsCredentialsWipesLibraryAndEntersDemoMode() throws {
        let context = try inMemoryContext()
        let feed = Feed(name: "Paired Feed", identifier: "paired://feed")
        context.insert(feed)
        let article = Article(
            title: "Paired Article", identifier: "paired://article/0",
            url: "https://example.com", date: .now, author: "Someone"
        )
        article.feed = feed
        context.insert(article)
        try context.save()

        KeychainService.saveDeviceToken("test-session-token")
        defer { KeychainService.deleteDeviceToken() }

        let settings = AppSettings()
        settings.serverBaseURL = "https://paired.example.com"
        settings.hasSkippedServerPairing = false
        defer {
            settings.serverBaseURL = ""
            settings.hasSkippedServerPairing = false
        }

        ServerDisconnect.disconnect(settings: settings, context: context)

        #expect(KeychainService.loadDeviceToken() == nil)
        #expect(settings.serverBaseURL == "")
        #expect(settings.hasSkippedServerPairing == true)
        #expect(try context.fetch(FetchDescriptor<Article>()).allSatisfy { $0.identifier != "paired://article/0" })
        #expect(try context.fetch(FetchDescriptor<Feed>()).allSatisfy { $0.identifier != "paired://feed" })
    }

    /// Removing the server connection has to make the *next* pairing's sync a first sync again:
    /// the whole historical backlog lands afresh, so `InitialSyncGate` must block the reader
    /// behind `InitialSyncLoadingView` for it exactly as it did on the device's original pairing.
    /// Leaving `hasCompletedInitialSync` set is what made the loading screen silently not appear
    /// after remove-then-re-add.
    @Test func disconnectClearsTheInitialSyncCompletionFlag() throws {
        let context = try inMemoryContext()
        let settings = AppSettings()
        settings.hasCompletedInitialSync = true
        defer {
            settings.serverBaseURL = ""
            settings.hasSkippedServerPairing = false
            settings.hasCompletedInitialSync = false
        }

        ServerDisconnect.disconnect(settings: settings, context: context)

        #expect(settings.hasCompletedInitialSync == false)
    }

    @Test func disconnectWhenNeverPairedIsHarmlessNoOp() throws {
        let context = try inMemoryContext()

        KeychainService.deleteDeviceToken()

        let settings = AppSettings()
        settings.serverBaseURL = ""
        settings.hasSkippedServerPairing = false
        defer {
            settings.serverBaseURL = ""
            settings.hasSkippedServerPairing = false
        }

        ServerDisconnect.disconnect(settings: settings, context: context)

        #expect(KeychainService.loadDeviceToken() == nil)
        #expect(settings.serverBaseURL == "")
        #expect(settings.hasSkippedServerPairing == true)
    }

    @Test func disconnectTwiceInARowIsSafe() throws {
        let context = try inMemoryContext()
        let feed = Feed(name: "Paired Feed", identifier: "paired://feed")
        context.insert(feed)
        let article = Article(
            title: "Paired Article", identifier: "paired://article/0",
            url: "https://example.com", date: .now, author: "Someone"
        )
        article.feed = feed
        context.insert(article)
        try context.save()

        KeychainService.saveDeviceToken("test-session-token")
        defer { KeychainService.deleteDeviceToken() }

        let settings = AppSettings()
        settings.serverBaseURL = "https://paired.example.com"
        settings.hasSkippedServerPairing = false
        defer {
            settings.serverBaseURL = ""
            settings.hasSkippedServerPairing = false
        }

        ServerDisconnect.disconnect(settings: settings, context: context)
        ServerDisconnect.disconnect(settings: settings, context: context)

        #expect(KeychainService.loadDeviceToken() == nil)
        #expect(settings.serverBaseURL == "")
        #expect(settings.hasSkippedServerPairing == true)
        #expect(try context.fetch(FetchDescriptor<Article>()).allSatisfy { $0.identifier != "paired://article/0" })
        #expect(try context.fetch(FetchDescriptor<Feed>()).allSatisfy { $0.identifier != "paired://feed" })
    }

    /// A tracked operation is scoped to the server that issued its id, and job/run ids collide
    /// freely across servers. Left persisted, `OperationMonitor.resume()` on a later launch would
    /// poll an OLD server's job id against a NEWLY paired one, and a matching-but-unrelated
    /// completed job would have this device fetch `/articles/<old serverID>/content` and write one
    /// article's body onto whatever row now holds that id. Same reasoning as the pending
    /// write/reading-position queues this clears alongside.
    @Test func disconnectClearsTrackedOperationsSoTheyCannotBeReplayedAgainstAnotherServer() throws {
        let context = try inMemoryContext()
        let settings = AppSettings(defaults: UserDefaults(suiteName: "Disconnect.\(UUID())")!)
        settings.trackedOperations = [
            TrackedOperation(kind: .reloadArticle(serverID: 100), id: 42, startedAt: .now),
            TrackedOperation(kind: .updateAll, id: 7, startedAt: .now)
        ]
        settings.pendingReadingPositionPush = 100

        // A throwaway monitor: `disconnect` stops whatever it is watching, and the app-wide
        // `.shared` one must not be reached into from a test.
        ServerDisconnect.disconnect(settings: settings, context: context,
                                    monitor: OperationMonitor(activity: UpdateActivity()))

        #expect(settings.trackedOperations.isEmpty)
        #expect(settings.pendingReadingPositionPush == nil)
    }
}
