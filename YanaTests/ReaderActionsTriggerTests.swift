import Foundation
import SwiftData
import Testing
@testable import Yana

@Suite("Reader action triggers", .serialized)
@MainActor
struct ReaderActionsTriggerTests {
    private func makeContainer() throws -> ModelContainer {
        try ModelContainer(for: Article.self, Feed.self, Tag.self,
                           configurations: .init(isStoredInMemoryOnly: true))
    }

    @Test func startingAReloadPersistsTheJobBeforeAnythingElseCanLoseIt() async throws {
        try await MockURLProtocol.lock.withLock {
            let container = try makeContainer()
            let settings = AppSettings(defaults: UserDefaults(suiteName: "Trigger.\(UUID())")!)
            let article = Article(title: "T", identifier: "a", url: "https://example.test/a")
            article.serverID = 100
            let context = ModelContext(container)
            context.insert(article)

            let config = URLSessionConfiguration.ephemeral
            config.protocolClasses = [MockURLProtocol.self]
            MockURLProtocol.stub = { request in
                let response = HTTPURLResponse(url: request.url!, statusCode: 202, httpVersion: nil,
                                               headerFields: ["Content-Type": "application/json"])!
                if request.url!.path == "/api/v1/articles/100/reload" {
                    return (response, #"{"jobId":42}"#.data(using: .utf8)!)
                }
                // Keep the monitor's first poll from finishing the operation during this test.
                return (HTTPURLResponse(url: request.url!, statusCode: 500, httpVersion: nil,
                                        headerFields: nil)!, Data())
            }
            let client = YanaAPIClient(baseURL: URL(string: "https://example.test")!, token: "t",
                                       session: URLSession(configuration: config))

            let monitor = OperationMonitor(pollInterval: .seconds(60), slowPollInterval: .seconds(60),
                                           youngPhase: .seconds(60), nudgeSlice: .milliseconds(1))
            let started = await ReaderActions.startReload(
                article, serverID: 100, client: client, container: container, settings: settings,
                monitor: monitor
            )

            #expect(started)
            #expect(settings.trackedOperations == [
                TrackedOperation(kind: .reloadArticle(serverID: 100), id: 42,
                                 startedAt: settings.trackedOperations.first!.startedAt)
            ])
            monitor.stopWatching(settings: settings)
        }
    }

    @Test func aFailedTriggerPersistsNothing() async throws {
        try await MockURLProtocol.lock.withLock {
            let container = try makeContainer()
            let settings = AppSettings(defaults: UserDefaults(suiteName: "Trigger.\(UUID())")!)
            let article = Article(title: "T", identifier: "a", url: "https://example.test/a")
            article.serverID = 100
            ModelContext(container).insert(article)

            let config = URLSessionConfiguration.ephemeral
            config.protocolClasses = [MockURLProtocol.self]
            MockURLProtocol.stub = { request in
                (HTTPURLResponse(url: request.url!, statusCode: 500, httpVersion: nil,
                                 headerFields: nil)!, Data())
            }
            let client = YanaAPIClient(baseURL: URL(string: "https://example.test")!, token: "t",
                                       session: URLSession(configuration: config))

            let monitor = OperationMonitor()
            let started = await ReaderActions.startReload(
                article, serverID: 100, client: client, container: container, settings: settings,
                monitor: monitor
            )

            #expect(!started)
            #expect(settings.trackedOperations.isEmpty)
        }
    }
}
