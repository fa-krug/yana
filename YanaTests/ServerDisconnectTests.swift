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
        let feed = Feed(name: "Paired Feed", aggregator: "feedContent", identifier: "paired://feed")
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
        let feed = Feed(name: "Paired Feed", aggregator: "feedContent", identifier: "paired://feed")
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
}
