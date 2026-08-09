import Foundation
import SwiftData
import Testing
@testable import Yana

@Suite("UpdateAndSync", .serialized)
@MainActor
struct UpdateAndSyncTests {
    private func makeContainer() throws -> ModelContainer {
        try ModelContainer(for: Article.self, Feed.self, Tag.self, configurations: .init(isStoredInMemoryOnly: true))
    }

    private func makeSettings(container: ModelContainer) -> AppSettings {
        // `AppSettings` is UserDefaults-backed, not a SwiftData `@Model` -- it can't be inserted
        // into a `ModelContainer`. Matches the pattern `SyncEngineTests` already uses; `container`
        // is accepted but unused, kept only so call sites read the same as the brief's.
        let defaults = UserDefaults(suiteName: "UpdateAndSyncTests.\(UUID())")!
        return AppSettings(defaults: defaults)
    }

    private func stubClient(pathsToResponses: [String: (Data, Int)]) -> YanaAPIClient {
        let config = URLSessionConfiguration.ephemeral
        config.protocolClasses = [MockURLProtocol.self]
        MockURLProtocol.stub = { request in
            let key = "\(request.httpMethod ?? "GET") \(request.url!.path)"
            let (data, status) = pathsToResponses[key] ?? (Data(), 404)
            let response = HTTPURLResponse(url: request.url!, statusCode: status, httpVersion: nil, headerFields: ["Content-Type": "application/json"])!
            return (response, data)
        }
        return YanaAPIClient(baseURL: URL(string: "https://example.test")!, token: "t", session: URLSession(configuration: config))
    }

    // MARK: - pollForFreshContent

    @Test func pollForFreshContentWaitsUntilTheRunIsNoLongerRunningThenSyncsOnce() async throws {
        try await MockURLProtocol.lock.withLock {
            let container = try makeContainer()
            let settings = makeSettings(container: container)
            var runStatusCallCount = 0
            let config = URLSessionConfiguration.ephemeral
            config.protocolClasses = [MockURLProtocol.self]
            MockURLProtocol.stub = { request in
                let path = request.url!.path
                if path == "/api/v1/runs/5" {
                    runStatusCallCount += 1
                    let status = runStatusCallCount < 3 ? "running" : "completed"
                    let body = #"{"runId":5,"status":"\#(status)","totalJobs":1,"completedJobs":0,"failedJobs":0}"#
                    let response = HTTPURLResponse(url: request.url!, statusCode: 200, httpVersion: nil, headerFields: ["Content-Type": "application/json"])!
                    return (response, body.data(using: .utf8)!)
                }
                if path == "/api/v1/articles/sync" {
                    let response = HTTPURLResponse(url: request.url!, statusCode: 200, httpVersion: nil, headerFields: ["Content-Type": "application/json"])!
                    return (response, #"{"new":[],"updated":[],"removed":[],"nextCursor":null}"#.data(using: .utf8)!)
                }
                if path == "/api/v1/feeds" {
                    let response = HTTPURLResponse(url: request.url!, statusCode: 200, httpVersion: nil, headerFields: ["Content-Type": "application/json"])!
                    return (response, #"{"feeds":[]}"#.data(using: .utf8)!)
                }
                if path == "/api/v1/tags" {
                    let response = HTTPURLResponse(url: request.url!, statusCode: 200, httpVersion: nil, headerFields: ["Content-Type": "application/json"])!
                    return (response, #"{"tags":[]}"#.data(using: .utf8)!)
                }
                let response = HTTPURLResponse(url: request.url!, statusCode: 404, httpVersion: nil, headerFields: nil)!
                return (response, Data())
            }
            let client = YanaAPIClient(baseURL: URL(string: "https://example.test")!, token: "t", session: URLSession(configuration: config))

            let result = await UpdateAndSync.pollForFreshContent(
                runId: 5, container: container, client: client, settings: settings, pollInterval: .milliseconds(10)
            )

            #expect(runStatusCallCount == 3)
            #expect(result == SyncResult(newCount: 0, updatedCount: 0, removedCount: 0))
        }
    }

    @Test func pollForFreshContentGivesUpAfterMaxAttemptsAndStillSyncsOnce() async throws {
        try await MockURLProtocol.lock.withLock {
            let container = try makeContainer()
            let settings = makeSettings(container: container)
            var syncCallCount = 0
            let config = URLSessionConfiguration.ephemeral
            config.protocolClasses = [MockURLProtocol.self]
            MockURLProtocol.stub = { request in
                let path = request.url!.path
                if path == "/api/v1/runs/5" {
                    let response = HTTPURLResponse(url: request.url!, statusCode: 200, httpVersion: nil, headerFields: ["Content-Type": "application/json"])!
                    return (response, #"{"runId":5,"status":"running","totalJobs":1,"completedJobs":0,"failedJobs":0}"#.data(using: .utf8)!)
                }
                if path == "/api/v1/articles/sync" {
                    syncCallCount += 1
                    let response = HTTPURLResponse(url: request.url!, statusCode: 200, httpVersion: nil, headerFields: ["Content-Type": "application/json"])!
                    return (response, #"{"new":[],"updated":[],"removed":[],"nextCursor":null}"#.data(using: .utf8)!)
                }
                if path == "/api/v1/feeds" {
                    let response = HTTPURLResponse(url: request.url!, statusCode: 200, httpVersion: nil, headerFields: ["Content-Type": "application/json"])!
                    return (response, #"{"feeds":[]}"#.data(using: .utf8)!)
                }
                if path == "/api/v1/tags" {
                    let response = HTTPURLResponse(url: request.url!, statusCode: 200, httpVersion: nil, headerFields: ["Content-Type": "application/json"])!
                    return (response, #"{"tags":[]}"#.data(using: .utf8)!)
                }
                let response = HTTPURLResponse(url: request.url!, statusCode: 404, httpVersion: nil, headerFields: nil)!
                return (response, Data())
            }
            let client = YanaAPIClient(baseURL: URL(string: "https://example.test")!, token: "t", session: URLSession(configuration: config))

            _ = await UpdateAndSync.pollForFreshContent(
                runId: 5, container: container, client: client, settings: settings,
                pollInterval: .milliseconds(1), maxAttempts: 3
            )

            #expect(syncCallCount == 1)
        }
    }

    @Test func pollForFreshContentToleratesTransientTransportFailuresWhilePollingRunStatus() async throws {
        try await MockURLProtocol.lock.withLock {
            let container = try makeContainer()
            let settings = makeSettings(container: container)
            var runStatusCallCount = 0
            var syncCallCount = 0
            let config = URLSessionConfiguration.ephemeral
            config.protocolClasses = [MockURLProtocol.self]
            MockURLProtocol.stub = { request in
                let path = request.url!.path
                if path == "/api/v1/runs/5" {
                    runStatusCallCount += 1
                    // The first two attempts fail at the transport level (a malformed/non-JSON
                    // 500 body, which can't be decoded as the server's error envelope either --
                    // see `YanaAPIClient.send`'s `.transport` fallback). Only the third attempt
                    // succeeds, reporting the run as still running once before completing.
                    if runStatusCallCount <= 2 {
                        let response = HTTPURLResponse(url: request.url!, statusCode: 500, httpVersion: nil, headerFields: nil)!
                        return (response, "not json".data(using: .utf8)!)
                    }
                    let status = runStatusCallCount < 4 ? "running" : "completed"
                    let body = #"{"runId":5,"status":"\#(status)","totalJobs":1,"completedJobs":0,"failedJobs":0}"#
                    let response = HTTPURLResponse(url: request.url!, statusCode: 200, httpVersion: nil, headerFields: ["Content-Type": "application/json"])!
                    return (response, body.data(using: .utf8)!)
                }
                if path == "/api/v1/articles/sync" {
                    syncCallCount += 1
                    let response = HTTPURLResponse(url: request.url!, statusCode: 200, httpVersion: nil, headerFields: ["Content-Type": "application/json"])!
                    return (response, #"{"new":[],"updated":[],"removed":[],"nextCursor":null}"#.data(using: .utf8)!)
                }
                if path == "/api/v1/feeds" {
                    let response = HTTPURLResponse(url: request.url!, statusCode: 200, httpVersion: nil, headerFields: ["Content-Type": "application/json"])!
                    return (response, #"{"feeds":[]}"#.data(using: .utf8)!)
                }
                if path == "/api/v1/tags" {
                    let response = HTTPURLResponse(url: request.url!, statusCode: 200, httpVersion: nil, headerFields: ["Content-Type": "application/json"])!
                    return (response, #"{"tags":[]}"#.data(using: .utf8)!)
                }
                let response = HTTPURLResponse(url: request.url!, statusCode: 404, httpVersion: nil, headerFields: nil)!
                return (response, Data())
            }
            let client = YanaAPIClient(baseURL: URL(string: "https://example.test")!, token: "t", session: URLSession(configuration: config))

            let result = await UpdateAndSync.pollForFreshContent(
                runId: 5, container: container, client: client, settings: settings, pollInterval: .milliseconds(10)
            )

            // Two transport failures followed by "running" then "completed": the wait doesn't
            // bail after the first (or even second) transient failure, and still reaches a
            // definitive "completed" status before syncing exactly once.
            #expect(runStatusCallCount == 4)
            #expect(syncCallCount == 1)
            #expect(result == SyncResult(newCount: 0, updatedCount: 0, removedCount: 0))
        }
    }

    // MARK: - pollForReloadedContent

    @Test func pollForReloadedContentFetchesContentWhenTheMatchingJobCompletes() async throws {
        try await MockURLProtocol.lock.withLock {
            let container = try makeContainer()
            let writer = SyncWriter(modelContainer: container)
            _ = await writer.replaceFeeds([
                SyncFeedWire(id: 1, name: "Feed", aggregator: "feed_content", identifier: "f1",
                             enabled: true, dailyLimit: 20, tagIds: [], logoImageHash: nil, updatedAt: .now)
            ])
            _ = await writer.upsertSummaries([
                SyncArticleSummaryWire(id: 100, feedId: 1, name: "Hello", identifier: "art-100",
                                        date: .now, author: "", icon: nil, read: false, starred: false,
                                        createdAt: .now, updatedAt: .now)
            ])

            let sseBody = "event: job\ndata: {\"jobId\":42,\"runId\":null,\"kind\":\"article.reload\",\"status\":\"completed\",\"progress\":1}\n\n"
            let contentBody = #"{"version":1,"blocks":[]}"#
            let config = URLSessionConfiguration.ephemeral
            config.protocolClasses = [MockURLProtocol.self]
            MockURLProtocol.stub = { request in
                let path = request.url!.path
                if path == "/api/v1/jobs/events" {
                    let response = HTTPURLResponse(url: request.url!, statusCode: 200, httpVersion: nil, headerFields: nil)!
                    return (response, sseBody.data(using: .utf8)!)
                }
                if path == "/api/v1/articles/100/content" {
                    let response = HTTPURLResponse(url: request.url!, statusCode: 200, httpVersion: nil, headerFields: ["Content-Type": "application/json"])!
                    return (response, contentBody.data(using: .utf8)!)
                }
                let response = HTTPURLResponse(url: request.url!, statusCode: 404, httpVersion: nil, headerFields: nil)!
                return (response, Data())
            }
            let client = YanaAPIClient(baseURL: URL(string: "https://example.test")!, token: "t", session: URLSession(configuration: config))

            let applied = await UpdateAndSync.pollForReloadedContent(
                jobId: 42, articleServerID: 100, container: container, client: client
            )

            #expect(applied)
        }
    }

    @Test func pollForReloadedContentReturnsFalseWithoutFetchingWhenTheJobFails() async throws {
        try await MockURLProtocol.lock.withLock {
            let container = try makeContainer()
            var contentFetchCount = 0
            let sseBody = "event: job\ndata: {\"jobId\":42,\"runId\":null,\"kind\":\"article.reload\",\"status\":\"failed\",\"progress\":1}\n\n"
            let config = URLSessionConfiguration.ephemeral
            config.protocolClasses = [MockURLProtocol.self]
            MockURLProtocol.stub = { request in
                let path = request.url!.path
                if path == "/api/v1/jobs/events" {
                    let response = HTTPURLResponse(url: request.url!, statusCode: 200, httpVersion: nil, headerFields: nil)!
                    return (response, sseBody.data(using: .utf8)!)
                }
                if path == "/api/v1/articles/100/content" {
                    contentFetchCount += 1
                    let response = HTTPURLResponse(url: request.url!, statusCode: 200, httpVersion: nil, headerFields: ["Content-Type": "application/json"])!
                    return (response, #"{"version":1,"blocks":[]}"#.data(using: .utf8)!)
                }
                let response = HTTPURLResponse(url: request.url!, statusCode: 404, httpVersion: nil, headerFields: nil)!
                return (response, Data())
            }
            let client = YanaAPIClient(baseURL: URL(string: "https://example.test")!, token: "t", session: URLSession(configuration: config))

            let applied = await UpdateAndSync.pollForReloadedContent(
                jobId: 42, articleServerID: 100, container: container, client: client
            )

            #expect(!applied)
            #expect(contentFetchCount == 0)
        }
    }

    @Test func pollForReloadedContentFallsBackToADirectFetchWhenNoMatchingEventArrivesInTime() async throws {
        try await MockURLProtocol.lock.withLock {
            let container = try makeContainer()
            let writer = SyncWriter(modelContainer: container)
            _ = await writer.replaceFeeds([
                SyncFeedWire(id: 1, name: "Feed", aggregator: "feed_content", identifier: "f1",
                             enabled: true, dailyLimit: 20, tagIds: [], logoImageHash: nil, updatedAt: .now)
            ])
            _ = await writer.upsertSummaries([
                SyncArticleSummaryWire(id: 100, feedId: 1, name: "Hello", identifier: "art-100",
                                        date: .now, author: "", icon: nil, read: false, starred: false,
                                        createdAt: .now, updatedAt: .now)
            ])

            // The SSE stream reports a *different* job's completion, never job 42's -- it then
            // ends (as it does in this mock, which delivers one shot and closes), simulating a
            // dropped connection or a missed event.
            let sseBody = "event: job\ndata: {\"jobId\":99,\"runId\":null,\"kind\":\"article.reload\",\"status\":\"completed\",\"progress\":1}\n\n"
            let contentBody = #"{"version":1,"blocks":[]}"#
            let config = URLSessionConfiguration.ephemeral
            config.protocolClasses = [MockURLProtocol.self]
            MockURLProtocol.stub = { request in
                let path = request.url!.path
                if path == "/api/v1/jobs/events" {
                    let response = HTTPURLResponse(url: request.url!, statusCode: 200, httpVersion: nil, headerFields: nil)!
                    return (response, sseBody.data(using: .utf8)!)
                }
                if path == "/api/v1/articles/100/content" {
                    let response = HTTPURLResponse(url: request.url!, statusCode: 200, httpVersion: nil, headerFields: ["Content-Type": "application/json"])!
                    return (response, contentBody.data(using: .utf8)!)
                }
                let response = HTTPURLResponse(url: request.url!, statusCode: 404, httpVersion: nil, headerFields: nil)!
                return (response, Data())
            }
            let client = YanaAPIClient(baseURL: URL(string: "https://example.test")!, token: "t", session: URLSession(configuration: config))

            let applied = await UpdateAndSync.pollForReloadedContent(
                jobId: 42, articleServerID: 100, container: container, client: client, eventTimeout: .milliseconds(50)
            )

            #expect(applied)
        }
    }

    /// Regression test: the reader holds an already-registered `Article` on its own
    /// `ModelContext`, fetched before the reload started. `SyncWriter` applies the reload's
    /// content through a *separate* `@ModelActor` context, so without `visibleArticle` that
    /// registered object's fields never change -- a plain `fetch` on its context doesn't refresh
    /// an already-registered object's attributes from a sibling context's save. Passing
    /// `visibleArticle` must update that exact object directly.
    @Test func pollForReloadedContentUpdatesTheVisibleArticleDirectly() async throws {
        try await MockURLProtocol.lock.withLock {
            let container = try makeContainer()
            let writer = SyncWriter(modelContainer: container)
            _ = await writer.replaceFeeds([
                SyncFeedWire(id: 1, name: "Feed", aggregator: "feed_content", identifier: "f1",
                             enabled: true, dailyLimit: 20, tagIds: [], logoImageHash: nil, updatedAt: .now)
            ])
            _ = await writer.upsertSummaries([
                SyncArticleSummaryWire(id: 100, feedId: 1, name: "Hello", identifier: "art-100",
                                        date: .now, author: "", icon: nil, read: false, starred: false,
                                        createdAt: .now, updatedAt: .now)
            ])

            // A separate context, standing in for the reader's main-thread `ModelContext` --
            // exactly like `ArticleResolution.resolve` would hand the reader.
            let readerContext = ModelContext(container)
            let visibleArticle = try readerContext.fetch(
                FetchDescriptor<Article>(predicate: #Predicate { $0.serverID == 100 })
            ).first!
            #expect(visibleArticle.hasContent == false)

            let sseBody = "event: job\ndata: {\"jobId\":42,\"runId\":null,\"kind\":\"article.reload\",\"status\":\"completed\",\"progress\":1}\n\n"
            let contentBody = #"{"version":1,"blocks":[{"type":"paragraph","runs":[{"text":"fresh","styles":[],"link":null}]}]}"#
            let config = URLSessionConfiguration.ephemeral
            config.protocolClasses = [MockURLProtocol.self]
            MockURLProtocol.stub = { request in
                let path = request.url!.path
                if path == "/api/v1/jobs/events" {
                    let response = HTTPURLResponse(url: request.url!, statusCode: 200, httpVersion: nil, headerFields: nil)!
                    return (response, sseBody.data(using: .utf8)!)
                }
                if path == "/api/v1/articles/100/content" {
                    let response = HTTPURLResponse(url: request.url!, statusCode: 200, httpVersion: nil, headerFields: ["Content-Type": "application/json"])!
                    return (response, contentBody.data(using: .utf8)!)
                }
                let response = HTTPURLResponse(url: request.url!, statusCode: 404, httpVersion: nil, headerFields: nil)!
                return (response, Data())
            }
            let client = YanaAPIClient(baseURL: URL(string: "https://example.test")!, token: "t", session: URLSession(configuration: config))

            let applied = await UpdateAndSync.pollForReloadedContent(
                jobId: 42, articleServerID: 100, container: container, client: client, visibleArticle: visibleArticle
            )

            #expect(applied)
            #expect(visibleArticle.hasContent)
            #expect(visibleArticle.plainText.contains("fresh"))
        }
    }
}
