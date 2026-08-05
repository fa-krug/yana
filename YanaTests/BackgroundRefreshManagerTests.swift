import Foundation
import SwiftData
import Testing
@testable import Yana

// See `YanaTests/Support/MockURLProtocol.swift`: every test that stubs a `YanaAPIClient` must
// wrap its whole body in `MockURLProtocol.lock.withLock`, and the suite must be `.serialized` --
// this shared static stub races with every other suite (e.g. `SyncEngineTests`) that Swift
// Testing otherwise schedules concurrently.
@MainActor
@Suite("BackgroundRefreshManager", .serialized)
struct BackgroundRefreshManagerTests {
    @Test func nextBeginDateAddsIntervalToReference() {
        let now = Date(timeIntervalSince1970: 1_000_000_000)
        let result = BackgroundRefreshManager.nextBeginDate(from: now, interval: 1800)
        #expect(result == now.addingTimeInterval(1800))
    }

    @Test func nextBeginDateClampsNonPositiveIntervalToMinimum() {
        let now = Date(timeIntervalSince1970: 1_000_000_000)
        // Zero or negative intervals would let iOS run immediately/never; clamp to the floor.
        #expect(BackgroundRefreshManager.nextBeginDate(from: now, interval: 0)
                == now.addingTimeInterval(BackgroundRefreshManager.minimumInterval))
        #expect(BackgroundRefreshManager.nextBeginDate(from: now, interval: -500)
                == now.addingTimeInterval(BackgroundRefreshManager.minimumInterval))
    }

    private func makeContainer() throws -> ModelContainer {
        try ModelContainer(
            for: Feed.self, Yana.Tag.self, Article.self,
            configurations: ModelConfiguration(isStoredInMemoryOnly: true, cloudKitDatabase: .none))
    }

    /// Stubs a `YanaAPIClient` that reports one feed and, on `/api/v1/articles/sync`, one new
    /// article summary (no `updated`/`removed`) with a matching `/content` response -- mirrors
    /// `SyncEngineTests.stubClient`, which this manager's `runRefresh` now drives instead of
    /// `AggregationService`.
    private func stubClient(newArticleCount: Int) -> YanaAPIClient {
        let config = URLSessionConfiguration.ephemeral
        config.protocolClasses = [MockURLProtocol.self]

        let newSummaries = (0..<newArticleCount).map { i in
            #"{"id":\#(100 + i),"feedId":1,"name":"x\#(i)","identifier":"x\#(i)","date":"2026-01-01T00:00:00Z","author":"","icon":null,"read":false,"starred":false,"createdAt":"2026-01-01T00:00:00Z","updatedAt":"2026-01-01T00:00:00Z"}"#
        }.joined(separator: ",")
        let syncResponse = #"{"new":[\#(newSummaries)],"updated":[],"removed":[],"nextCursor":null}"#
            .data(using: .utf8)!
        let contentResponse = #"{"version":1,"blocks":[]}"#.data(using: .utf8)!
        let feedsResponse = #"{"feeds":[{"id":1,"name":"A","aggregator":"feed_content","identifier":"a","enabled":true,"dailyLimit":20,"tagIds":[],"logoImageHash":null,"updatedAt":"2026-01-01T00:00:00Z"}]}"#
            .data(using: .utf8)!

        MockURLProtocol.stub = { request in
            let path = request.url!.path
            let (data, status): (Data, Int)
            if path == "/api/v1/feeds" {
                (data, status) = (feedsResponse, 200)
            } else if path == "/api/v1/tags" {
                (data, status) = (#"{"tags":[]}"#.data(using: .utf8)!, 200)
            } else if path == "/api/v1/articles/sync" {
                (data, status) = (syncResponse, 200)
            } else if path.hasSuffix("/content") {
                (data, status) = (contentResponse, 200)
            } else {
                (data, status) = (#"{"error":{"code":"not_found","message":"unhandled path in test"}}"#.data(using: .utf8)!, 404)
            }
            let response = HTTPURLResponse(url: request.url!, statusCode: status, httpVersion: nil, headerFields: ["Content-Type": "application/json"])!
            return (response, data)
        }
        return YanaAPIClient(baseURL: URL(string: "https://example.test")!, token: "t", session: URLSession(configuration: config))
    }

    private func freshSettings(notificationsEnabled: Bool) -> AppSettings {
        let defaults = UserDefaults(suiteName: "BGRefreshTests.\(UUID().uuidString)")!
        let s = AppSettings(defaults: defaults)
        s.notificationsEnabled = notificationsEnabled
        return s
    }

    @Test func runRefreshAwaitsSyncAndImports() async throws {
        try await MockURLProtocol.lock.withLock {
            let container = try makeContainer()
            let client = stubClient(newArticleCount: 1)
            let settings = freshSettings(notificationsEnabled: false)
            let engine = SyncEngine(container: container, client: client, settings: settings)

            await BackgroundRefreshManager.runRefresh(engine: engine, settings: settings)

            let articles = try container.mainContext.fetch(FetchDescriptor<Article>())
            #expect(articles.count == 1)
        }
    }

    private final class FakeNotifier: Notifying, @unchecked Sendable {
        var authorized: Bool
        var postedCounts: [Int] = []
        init(authorized: Bool) { self.authorized = authorized }
        func requestAuthorization() async -> Bool { authorized }
        func isAuthorized() async -> Bool { authorized }
        func postNewArticles(count: Int) async { postedCounts.append(count) }
    }

    @Test func postsNotificationWhenEnabledAuthorizedAndNewArticles() async throws {
        try await MockURLProtocol.lock.withLock {
            let container = try makeContainer()
            let client = stubClient(newArticleCount: 1)
            let settings = freshSettings(notificationsEnabled: true)
            let engine = SyncEngine(container: container, client: client, settings: settings)
            let notifier = FakeNotifier(authorized: true)

            await BackgroundRefreshManager.runRefresh(engine: engine, notifier: notifier, settings: settings)

            #expect(notifier.postedCounts == [1])
        }
    }

    @Test func doesNotNotifyWhenDisabled() async throws {
        try await MockURLProtocol.lock.withLock {
            let container = try makeContainer()
            let client = stubClient(newArticleCount: 1)
            let settings = freshSettings(notificationsEnabled: false)
            let engine = SyncEngine(container: container, client: client, settings: settings)
            let notifier = FakeNotifier(authorized: true)

            await BackgroundRefreshManager.runRefresh(engine: engine, notifier: notifier, settings: settings)

            #expect(notifier.postedCounts.isEmpty)
            let articles = try container.mainContext.fetch(FetchDescriptor<Article>())
            #expect(articles.count == 1)
        }
    }

    @Test func doesNotNotifyWhenNotAuthorized() async throws {
        try await MockURLProtocol.lock.withLock {
            let container = try makeContainer()
            let client = stubClient(newArticleCount: 1)
            let settings = freshSettings(notificationsEnabled: true)
            let engine = SyncEngine(container: container, client: client, settings: settings)
            let notifier = FakeNotifier(authorized: false)

            await BackgroundRefreshManager.runRefresh(engine: engine, notifier: notifier, settings: settings)

            #expect(notifier.postedCounts.isEmpty)
        }
    }

    @Test("schedule() no-ops when secondsProvider returns nil (.off)")
    func passiveScheduleNoOps() throws {
        let container = try ModelContainer(
            for: Feed.self, Yana.Tag.self, Article.self,
            configurations: ModelConfiguration(isStoredInMemoryOnly: true, cloudKitDatabase: .none))
        var scheduled = false
        let off = BackgroundRefreshManager(
            container: container,
            secondsProvider: { nil },              // .off → nil seconds
            now: { Date(timeIntervalSince1970: 0) },
            onScheduleAttempt: { scheduled = true })
        off.schedule()
        #expect(scheduled == false)              // guard returned before onScheduleAttempt

        // Sanity: with a real interval the guard passes and onScheduleAttempt IS called.
        var activeScheduled = false
        let active = BackgroundRefreshManager(
            container: container,
            secondsProvider: { 300 },
            now: { Date(timeIntervalSince1970: 0) },
            onScheduleAttempt: { activeScheduled = true })
        active.schedule()
        #expect(activeScheduled == true)
    }
}
