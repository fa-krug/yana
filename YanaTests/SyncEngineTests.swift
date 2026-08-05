import Foundation
import SwiftData
import Testing
@testable import Yana

// Every test wraps its whole body in `MockURLProtocol.lock.withLock` -- `.serialized` below only
// orders tests within THIS suite; it does nothing against `YanaAPIClientTests`, a different suite
// sharing the same static `MockURLProtocol.stub`, which Swift Testing schedules concurrently with
// this one by default. See `YanaTests/Support/MockURLProtocol.swift` for why, and
// task-10-report.md for the empirical repro.
@MainActor
@Suite("SyncEngine", .serialized)
struct SyncEngineTests {
    private func makeContainer() throws -> ModelContainer {
        try ModelContainer(for: Article.self, Feed.self, Tag.self, configurations: .init(isStoredInMemoryOnly: true))
    }

    private func stubClient(responses: [String: (Data, Int)]) -> YanaAPIClient {
        let config = URLSessionConfiguration.ephemeral
        config.protocolClasses = [MockURLProtocol.self]
        MockURLProtocol.stub = { request in
            let path = request.url!.path
            let (data, status) = responses[path] ?? (#"{"error":{"code":"not_found","message":"unhandled path in test"}}"#.data(using: .utf8)!, 404)
            let response = HTTPURLResponse(url: request.url!, statusCode: status, httpVersion: nil, headerFields: ["Content-Type": "application/json"])!
            return (response, data)
        }
        return YanaAPIClient(baseURL: URL(string: "https://example.test")!, token: "t", session: URLSession(configuration: config))
    }

    @Test func syncInsertsNewArticlesAndFetchesTheirContent() async throws {
        try await MockURLProtocol.lock.withLock {
            let container = try makeContainer()
            let defaults = UserDefaults(suiteName: "SyncEngineTests.\(UUID())")!
            let settings = AppSettings(defaults: defaults)

            let syncResponse = #"""
            {"new":[{"id":100,"feedId":1,"name":"Hello","identifier":"a1","date":"2026-01-01T00:00:00Z","author":"","icon":null,"read":false,"starred":false,"createdAt":"2026-01-01T00:00:00Z","updatedAt":"2026-01-01T00:00:00Z"}],"updated":[],"removed":[],"nextCursor":"cursor-1"}
            """#.data(using: .utf8)!
            let contentResponse = #"{"version":1,"blocks":[{"type":"paragraph","runs":[{"text":"Body","styles":[],"link":null}]}]}"#.data(using: .utf8)!
            let feedsResponse = #"{"feeds":[{"id":1,"name":"Test Feed","aggregator":"feed_content","identifier":"1","enabled":true,"dailyLimit":20,"tagIds":[],"logoImageHash":null,"updatedAt":"2026-01-01T00:00:00Z"}]}"#.data(using: .utf8)!

            let client = stubClient(responses: [
                "/api/v1/articles/sync": (syncResponse, 200),
                "/api/v1/articles/100/content": (contentResponse, 200),
                "/api/v1/feeds": (feedsResponse, 200),
            ])

            let engine = SyncEngine(container: container, client: client, settings: settings)
            let result = try await engine.sync()

            #expect(result.newCount == 1)
            let articles = try container.mainContext.fetch(FetchDescriptor<Article>())
            #expect(articles.count == 1)
            #expect(articles.first?.hasContent == true)
            #expect(settings.syncCursor == "cursor-1")
        }
    }

    @Test func resyncRequiredClearsTheCursorAndRetries() async throws {
        try await MockURLProtocol.lock.withLock {
            let container = try makeContainer()
            let defaults = UserDefaults(suiteName: "SyncEngineTests.\(UUID())")!
            let settings = AppSettings(defaults: defaults)
            settings.syncCursor = "stale-cursor"

            var callCount = 0
            let config = URLSessionConfiguration.ephemeral
            config.protocolClasses = [MockURLProtocol.self]
            MockURLProtocol.stub = { request in
                let response = HTTPURLResponse(url: request.url!, statusCode: 200, httpVersion: nil, headerFields: ["Content-Type": "application/json"])!
                if request.url!.path == "/api/v1/feeds" {
                    return (response, #"{"feeds":[]}"#.data(using: .utf8)!)
                }
                callCount += 1
                if callCount == 1 {
                    return (response, #"{"resyncRequired":true}"#.data(using: .utf8)!)
                }
                return (response, #"{"new":[],"updated":[],"removed":[],"nextCursor":"fresh-cursor"}"#.data(using: .utf8)!)
            }
            let client = YanaAPIClient(baseURL: URL(string: "https://example.test")!, token: "t", session: URLSession(configuration: config))

            let engine = SyncEngine(container: container, client: client, settings: settings)
            _ = try await engine.sync()

            #expect(settings.syncCursor == "fresh-cursor")
            #expect(callCount == 2)
        }
    }

    /// Proves the pagination loop actually pages: a first page shorter than the 200-item page
    /// size would stop after one round, so this drives TWO full-sized pages (200 items each)
    /// followed by a short final page, and asserts every item across all three pages landed
    /// locally and the loop terminated (didn't spin forever on the full pages, didn't stop early).
    @Test func syncPaginatesUntilAShortPage() async throws {
        try await MockURLProtocol.lock.withLock {
            let container = try makeContainer()
            let defaults = UserDefaults(suiteName: "SyncEngineTests.\(UUID())")!
            let settings = AppSettings(defaults: defaults)

            nonisolated func page(startingAt start: Int, count: Int, nextCursor: String?) -> Data {
                let items = (0..<count).map { i -> String in
                    let id = start + i
                    return #"{"id":\#(id),"feedId":1,"name":"A\#(id)","identifier":"a\#(id)","date":"2026-01-01T00:00:00Z","author":"","icon":null,"read":false,"starred":false,"createdAt":"2026-01-01T00:00:00Z","updatedAt":"2026-01-01T00:00:00Z"}"#
                }.joined(separator: ",")
                let cursorJSON = nextCursor.map { "\"\($0)\"" } ?? "null"
                return #"{"new":[\#(items)],"updated":[],"removed":[],"nextCursor":\#(cursorJSON)}"#.data(using: .utf8)!
            }

            var syncCallCount = 0
            let config = URLSessionConfiguration.ephemeral
            config.protocolClasses = [MockURLProtocol.self]
            MockURLProtocol.stub = { request in
                let response = HTTPURLResponse(url: request.url!, statusCode: 200, httpVersion: nil, headerFields: ["Content-Type": "application/json"])!
                if request.url!.path == "/api/v1/feeds" {
                    return (response, #"{"feeds":[]}"#.data(using: .utf8)!)
                }
                if request.url!.path.hasSuffix("/content") {
                    return (response, #"{"version":1,"blocks":[]}"#.data(using: .utf8)!)
                }
                syncCallCount += 1
                switch syncCallCount {
                case 1: return (response, page(startingAt: 0, count: 200, nextCursor: "cursor-2"))
                case 2: return (response, page(startingAt: 200, count: 200, nextCursor: "cursor-3"))
                case 3: return (response, page(startingAt: 400, count: 10, nextCursor: "cursor-4"))
                default:
                    Issue.record("sync endpoint called more times than expected: \(syncCallCount)")
                    return (response, #"{"new":[],"updated":[],"removed":[],"nextCursor":null}"#.data(using: .utf8)!)
                }
            }
            let client = YanaAPIClient(baseURL: URL(string: "https://example.test")!, token: "t", session: URLSession(configuration: config))

            let engine = SyncEngine(container: container, client: client, settings: settings)
            let result = try await engine.sync()

            #expect(syncCallCount == 3)
            #expect(result.newCount == 410)
            #expect(settings.syncCursor == "cursor-4")
            let articles = try container.mainContext.fetch(FetchDescriptor<Article>())
            #expect(articles.count == 410)
        }
    }

    /// A page whose `new`/`updated` arrays are short but whose `removed` array makes up the rest
    /// of `pageLimit` must still be treated as a full page -- otherwise a page consisting mostly
    /// or entirely of deletions would look short and stop the loop early, silently truncating a
    /// sync that still had more pages queued. Drives a first page with only 5 new + 195 removed
    /// (200 total) followed by a genuinely short second page, and asserts the sync endpoint was
    /// called twice (not once, which is what the pre-fix `new.count + updated.count` check would
    /// have produced here) and every item across both pages is reflected in the result.
    @Test func syncPaginatesWhenAPageIsMostlyRemovals() async throws {
        try await MockURLProtocol.lock.withLock {
            let container = try makeContainer()
            let defaults = UserDefaults(suiteName: "SyncEngineTests.\(UUID())")!
            let settings = AppSettings(defaults: defaults)

            nonisolated func newItem(id: Int) -> String {
                #"{"id":\#(id),"feedId":1,"name":"A\#(id)","identifier":"a\#(id)","date":"2026-01-01T00:00:00Z","author":"","icon":null,"read":false,"starred":false,"createdAt":"2026-01-01T00:00:00Z","updatedAt":"2026-01-01T00:00:00Z"}"#
            }

            var syncCallCount = 0
            let config = URLSessionConfiguration.ephemeral
            config.protocolClasses = [MockURLProtocol.self]
            MockURLProtocol.stub = { request in
                let response = HTTPURLResponse(url: request.url!, statusCode: 200, httpVersion: nil, headerFields: ["Content-Type": "application/json"])!
                if request.url!.path == "/api/v1/feeds" {
                    return (response, #"{"feeds":[]}"#.data(using: .utf8)!)
                }
                if request.url!.path.hasSuffix("/content") {
                    return (response, #"{"version":1,"blocks":[]}"#.data(using: .utf8)!)
                }
                syncCallCount += 1
                switch syncCallCount {
                case 1:
                    // 5 new + 195 removed == 200 == pageLimit, even though new+updated alone is
                    // only 5 -- the case the fixed `fullPage` check must catch.
                    let newItems = (0..<5).map(newItem).joined(separator: ",")
                    let removedItems = (1000..<1195).map(String.init).joined(separator: ",")
                    let body = #"{"new":[\#(newItems)],"updated":[],"removed":[\#(removedItems)],"nextCursor":"cursor-2"}"#
                    return (response, body.data(using: .utf8)!)
                case 2:
                    return (response, #"{"new":[],"updated":[],"removed":[],"nextCursor":"cursor-3"}"#.data(using: .utf8)!)
                default:
                    Issue.record("sync endpoint called more times than expected: \(syncCallCount)")
                    return (response, #"{"new":[],"updated":[],"removed":[],"nextCursor":null}"#.data(using: .utf8)!)
                }
            }
            let client = YanaAPIClient(baseURL: URL(string: "https://example.test")!, token: "t", session: URLSession(configuration: config))

            let engine = SyncEngine(container: container, client: client, settings: settings)
            let result = try await engine.sync()

            #expect(syncCallCount == 2, "a mostly-removals page must not be mistaken for the last page")
            #expect(result.newCount == 5)
            #expect(result.removedCount == 195)
            #expect(settings.syncCursor == "cursor-3")
            let articles = try container.mainContext.fetch(FetchDescriptor<Article>())
            #expect(articles.count == 5)
        }
    }
}
