import Foundation
import SwiftData
import Testing
@testable import Yana

@Suite("OperationMonitor", .serialized)
@MainActor
struct OperationMonitorTests {
    private func makeContainer() throws -> ModelContainer {
        try ModelContainer(for: Article.self, Feed.self, Tag.self,
                           configurations: .init(isStoredInMemoryOnly: true))
    }

    private func makeSettings() -> AppSettings {
        AppSettings(defaults: UserDefaults(suiteName: "OperationMonitorTests.\(UUID())")!)
    }

    /// A monitor with intervals short enough that a test finishes in milliseconds.
    private func makeMonitor() -> OperationMonitor {
        OperationMonitor(pollInterval: .milliseconds(5), slowPollInterval: .milliseconds(5),
                         youngPhase: .seconds(60), nudgeSlice: .milliseconds(1))
    }

    private func client(_ stub: @escaping (URLRequest) -> (HTTPURLResponse, Data)) -> YanaAPIClient {
        let config = URLSessionConfiguration.ephemeral
        config.protocolClasses = [MockURLProtocol.self]
        MockURLProtocol.stub = stub
        return YanaAPIClient(baseURL: URL(string: "https://example.test")!, token: "t",
                             session: URLSession(configuration: config))
    }

    private func json(_ request: URLRequest, _ body: String, status: Int = 200) -> (HTTPURLResponse, Data) {
        (HTTPURLResponse(url: request.url!, statusCode: status, httpVersion: nil,
                         headerFields: ["Content-Type": "application/json"])!,
         body.data(using: .utf8)!)
    }

    @Test func keepsPollingWhileTheJobIsPendingAndRunningAndPublishesEachPercentage() async throws {
        try await MockURLProtocol.lock.withLock {
            let container = try makeContainer()
            let settings = makeSettings()
            var seen: [Int] = []
            var call = 0
            let api = client { request in
                guard request.url!.path == "/api/v1/jobs/42" else {
                    return (HTTPURLResponse(url: request.url!, statusCode: 404, httpVersion: nil,
                                            headerFields: nil)!, Data())
                }
                call += 1
                let (status, progress) = switch call {
                case 1: ("pending", 0)
                case 2: ("running", 55)
                default: ("completed", 100)
                }
                return self.json(request, """
                {"jobId":42,"runId":null,"kind":"article.reload","progress":\(progress),
                 "status":"\(status)","error":"","startedAt":null,"finishedAt":null}
                """)
            }

            let monitor = makeMonitor()
            let operation = TrackedOperation(kind: .reloadArticle(serverID: 100), id: 42,
                                             startedAt: .now)
            settings.trackedOperations = [operation]
            let task = monitor.track(operation, settings: settings, container: container,
                                     client: api, observer: { seen.append($0 ?? -1) })
            await task.value

            #expect(call == 3)
            #expect(seen.contains(0))
            #expect(seen.contains(55))
            #expect(monitor.isActive == false)
        }
    }

    @Test func stopsOnAFailedJobAndClearsThePersistedRecord() async throws {
        try await MockURLProtocol.lock.withLock {
            let container = try makeContainer()
            let settings = makeSettings()
            var contentFetches = 0
            let api = client { request in
                if request.url!.path == "/api/v1/articles/100/content" { contentFetches += 1 }
                guard request.url!.path == "/api/v1/jobs/42" else {
                    return (HTTPURLResponse(url: request.url!, statusCode: 404, httpVersion: nil,
                                            headerFields: nil)!, Data())
                }
                return self.json(request, """
                {"jobId":42,"runId":null,"kind":"article.reload","progress":30,"status":"failed",
                 "error":"boom","startedAt":null,"finishedAt":null}
                """)
            }

            let monitor = makeMonitor()
            let operation = TrackedOperation(kind: .reloadArticle(serverID: 100), id: 42,
                                             startedAt: .now)
            settings.trackedOperations = [operation]
            await monitor.track(operation, settings: settings, container: container,
                                client: api).value

            #expect(contentFetches == 0)
            #expect(settings.trackedOperations.isEmpty)
            #expect(monitor.lastOutcome == .failed(.reloadArticle(serverID: 100)))
        }
    }

    @Test func pollsTheRunRouteForAnUpdateAllOperation() async throws {
        try await MockURLProtocol.lock.withLock {
            let container = try makeContainer()
            let settings = makeSettings()
            var runCalls = 0
            let api = client { request in
                switch request.url!.path {
                case "/api/v1/runs/5":
                    runCalls += 1
                    let running = runCalls < 2
                    return self.json(request, """
                    {"runId":5,"status":"\(running ? "running" : "completed")",
                     "progress":\(running ? 50 : 100),"totalJobs":2,
                     "completedJobs":\(running ? 1 : 2),"failedJobs":0}
                    """)
                case "/api/v1/feeds": return self.json(request, #"{"feeds":[]}"#)
                case "/api/v1/tags": return self.json(request, #"{"tags":[]}"#)
                case "/api/v1/articles/sync":
                    return self.json(request, #"{"new":[],"updated":[],"removed":[],"nextCursor":null}"#)
                default:
                    return (HTTPURLResponse(url: request.url!, statusCode: 404, httpVersion: nil,
                                            headerFields: nil)!, Data())
                }
            }

            let monitor = makeMonitor()
            let operation = TrackedOperation(kind: .updateAll, id: 5, startedAt: .now)
            settings.trackedOperations = [operation]
            var seen: [Int] = []
            await monitor.track(operation, settings: settings, container: container, client: api,
                                observer: { seen.append($0 ?? -1) }).value

            #expect(runCalls == 2)
            #expect(seen.contains(50))
            #expect(settings.trackedOperations.isEmpty)
        }
    }

    @Test func aTransportFailureRetriesInsteadOfEndingTheWait() async throws {
        try await MockURLProtocol.lock.withLock {
            let container = try makeContainer()
            let settings = makeSettings()
            var call = 0
            let api = client { request in
                guard request.url!.path == "/api/v1/jobs/42" else {
                    return (HTTPURLResponse(url: request.url!, statusCode: 404, httpVersion: nil,
                                            headerFields: nil)!, Data())
                }
                call += 1
                // Two undecodable 500s -- YanaAPIClient reports these as .unexpectedStatus, the
                // same class of blip as a dropped packet. Neither may end the wait.
                if call <= 2 {
                    return (HTTPURLResponse(url: request.url!, statusCode: 500, httpVersion: nil,
                                            headerFields: nil)!, "not json".data(using: .utf8)!)
                }
                return self.json(request, """
                {"jobId":42,"runId":null,"kind":"article.reload","progress":100,
                 "status":"completed","error":"","startedAt":null,"finishedAt":null}
                """)
            }

            let monitor = makeMonitor()
            let operation = TrackedOperation(kind: .reloadArticle(serverID: 100), id: 42,
                                             startedAt: .now)
            settings.trackedOperations = [operation]
            await monitor.track(operation, settings: settings, container: container,
                                client: api).value

            #expect(call == 3)
            #expect(settings.trackedOperations.isEmpty)
        }
    }

    /// Pins finding 2 of the code-review fix pass: `monitor` returns `nil` on cancellation, and
    /// that must NOT be treated as an outcome. `TrackedOperation`'s own doc contract is that a
    /// record is removed only once a terminal status has been observed, precisely so a relaunch
    /// after the process is killed mid-wait can resume it -- clearing the record on a mere
    /// cancellation (as opposed to a real terminal result) would defeat that.
    @Test func cancellingTheTaskLeavesThePersistedRecordAndClearsIsActive() async throws {
        try await MockURLProtocol.lock.withLock {
            let container = try makeContainer()
            let settings = makeSettings()
            let api = client { request in
                guard request.url!.path == "/api/v1/jobs/42" else {
                    return (HTTPURLResponse(url: request.url!, statusCode: 404, httpVersion: nil,
                                            headerFields: nil)!, Data())
                }
                return self.json(request, """
                {"jobId":42,"runId":null,"kind":"article.reload","progress":10,"status":"running",
                 "error":"","startedAt":null,"finishedAt":null}
                """)
            }

            let monitor = makeMonitor()
            let operation = TrackedOperation(kind: .reloadArticle(serverID: 100), id: 42,
                                             startedAt: .now)
            settings.trackedOperations = [operation]
            let task = monitor.track(operation, settings: settings, container: container,
                                     client: api)
            task.cancel()
            await task.value

            #expect(monitor.isActive == false)
            #expect(settings.trackedOperations == [operation])
        }
    }

    /// Pins finding 1: an `.unauthorized` response (the "token revoked from another device"
    /// case named in the fix request) must end the wait rather than retry forever -- mirroring
    /// `UpdateAndSync.waitForRunToFinish`'s identical bail-out on the same error class.
    @Test func anUnauthorizedResponseEndsTheWaitUnconfirmedAndClearsTheRecord() async throws {
        try await MockURLProtocol.lock.withLock {
            let container = try makeContainer()
            let settings = makeSettings()
            var call = 0
            let api = client { request in
                guard request.url!.path == "/api/v1/jobs/42" else {
                    return (HTTPURLResponse(url: request.url!, statusCode: 404, httpVersion: nil,
                                            headerFields: nil)!, Data())
                }
                call += 1
                return (HTTPURLResponse(url: request.url!, statusCode: 401, httpVersion: nil,
                                        headerFields: nil)!, Data())
            }

            let monitor = makeMonitor()
            let operation = TrackedOperation(kind: .reloadArticle(serverID: 100), id: 42,
                                             startedAt: .now)
            settings.trackedOperations = [operation]
            await monitor.track(operation, settings: settings, container: container,
                                client: api).value

            #expect(call == 1)
            #expect(settings.trackedOperations.isEmpty)
            #expect(monitor.lastOutcome == .unconfirmed(.reloadArticle(serverID: 100)))
        }
    }

    /// Pins one of the two `.gone` shapes: a 404 whose body carries the server's
    /// `{"error":{"code":"not_found",...}}` envelope, which `YanaAPIClient` decodes into
    /// `.server(YanaAPIError(code: "not_found", ...))`.
    @Test func aNotFoundEnvelopeReachesTheGoneArm() async throws {
        try await MockURLProtocol.lock.withLock {
            let container = try makeContainer()
            let settings = makeSettings()
            let api = client { request in
                guard request.url!.path == "/api/v1/jobs/42" else {
                    return (HTTPURLResponse(url: request.url!, statusCode: 404, httpVersion: nil,
                                            headerFields: nil)!, Data())
                }
                return self.json(
                    request, #"{"error":{"code":"not_found","message":"job gone"}}"#, status: 404)
            }

            let monitor = makeMonitor()
            let operation = TrackedOperation(kind: .reloadArticle(serverID: 100), id: 42,
                                             startedAt: .now)
            settings.trackedOperations = [operation]
            await monitor.track(operation, settings: settings, container: container,
                                client: api).value

            #expect(settings.trackedOperations.isEmpty)
            #expect(monitor.lastOutcome == .unconfirmed(.reloadArticle(serverID: 100)))
        }
    }

    /// Pins the other `.gone` shape: a bare 404 with no JSON error envelope at all -- an HTML 404
    /// page or similar -- which `YanaAPIClient` cannot decode as the error envelope and so maps to
    /// `.unexpectedStatus(404)` instead of `.server(...)`.
    @Test func aBareNotFoundStatusReachesTheGoneArm() async throws {
        try await MockURLProtocol.lock.withLock {
            let container = try makeContainer()
            let settings = makeSettings()
            let api = client { request in
                (HTTPURLResponse(url: request.url!, statusCode: 404, httpVersion: nil,
                                 headerFields: nil)!, Data())
            }

            let monitor = makeMonitor()
            let operation = TrackedOperation(kind: .reloadArticle(serverID: 100), id: 42,
                                             startedAt: .now)
            settings.trackedOperations = [operation]
            await monitor.track(operation, settings: settings, container: container,
                                client: api).value

            #expect(settings.trackedOperations.isEmpty)
            #expect(monitor.lastOutcome == .unconfirmed(.reloadArticle(serverID: 100)))
        }
    }

    @Test func aCompletedReloadAppliesTheContentToTheVisibleArticle() async throws {
        try await MockURLProtocol.lock.withLock {
            let container = try makeContainer()
            let settings = makeSettings()
            let writer = SyncWriter(modelContainer: container)
            _ = await writer.replaceFeeds([
                SyncFeedWire(id: 1, name: "Feed", identifier: "f1", tagIds: [], logoImageHash: nil)
            ])
            _ = await writer.upsertSummaries([
                SyncArticleSummaryWire(id: 100, feedId: 1, name: "Old", identifier: "art-100",
                                       date: .now, author: "", read: false, starred: false,
                                       createdAt: .now, updatedAt: .now)
            ])
            let readerContext = ModelContext(container)
            let visible = try readerContext.fetch(
                FetchDescriptor<Article>(predicate: #Predicate { $0.serverID == 100 })
            ).first!

            let api = client { request in
                switch request.url!.path {
                case "/api/v1/jobs/42":
                    return self.json(request, """
                    {"jobId":42,"runId":null,"kind":"article.reload","progress":100,
                     "status":"completed","error":"","startedAt":null,"finishedAt":null}
                    """)
                case "/api/v1/articles/100/content":
                    return self.json(request, #"""
                    {"version":1,"blocks":[{"type":"paragraph","runs":[{"text":"fresh","styles":[],"link":null}]}]}
                    """#)
                case "/api/v1/feeds":
                    // Keep the feed the article belongs to alive in this response -- the follow-up
                    // sync inside fetchAndApplyContent is a real /feeds fetch, and SyncWriter.replaceFeeds
                    // prunes (and cascade-deletes the articles of) any local feed missing from it. An
                    // empty response here would delete Feed 1 and its Article mid-test.
                    return self.json(request, #"{"feeds":[{"id":1,"name":"Feed","identifier":"f1","tagIds":[],"logoImageHash":null}]}"#)
                case "/api/v1/tags": return self.json(request, #"{"tags":[]}"#)
                case "/api/v1/articles/sync":
                    return self.json(request, #"{"new":[],"updated":[],"removed":[],"nextCursor":null}"#)
                default:
                    return (HTTPURLResponse(url: request.url!, statusCode: 404, httpVersion: nil,
                                            headerFields: nil)!, Data())
                }
            }

            let monitor = makeMonitor()
            let operation = TrackedOperation(kind: .reloadArticle(serverID: 100), id: 42,
                                             startedAt: .now)
            settings.trackedOperations = [operation]
            await monitor.track(operation, settings: settings, container: container, client: api,
                                visibleArticle: visible).value

            #expect(visible.hasContent)
            #expect(visible.plainText.contains("fresh"))
            #expect(monitor.lastOutcome == .reloaded(articleServerID: 100, feedName: "Feed"))
        }
    }

    @Test func aCompletedUpdateAllSyncsOnceAndReportsTheNewCount() async throws {
        try await MockURLProtocol.lock.withLock {
            let container = try makeContainer()
            let settings = makeSettings()
            var syncCalls = 0
            let syncBody = #"""
            {"new":[{"id":100,"feedId":1,"name":"New","identifier":"art-100","date":"2026-01-01T00:00:00Z","author":"","icon":null,"read":false,"starred":false,"createdAt":"2026-01-01T00:00:00Z","updatedAt":"2026-01-01T00:00:00Z"}],"updated":[],"removed":[],"nextCursor":null}
            """#
            let api = client { request in
                switch request.url!.path {
                case "/api/v1/runs/5":
                    return self.json(request, """
                    {"runId":5,"status":"completed","progress":100,"totalJobs":1,
                     "completedJobs":1,"failedJobs":0}
                    """)
                case "/api/v1/feeds":
                    return self.json(request, #"{"feeds":[{"id":1,"name":"Feed","identifier":"f1","tagIds":[],"logoImageHash":null}]}"#)
                case "/api/v1/tags": return self.json(request, #"{"tags":[]}"#)
                case "/api/v1/articles/sync":
                    syncCalls += 1
                    return self.json(request, syncCalls == 1
                        ? syncBody
                        : #"{"new":[],"updated":[],"removed":[],"nextCursor":null}"#)
                default:
                    return (HTTPURLResponse(url: request.url!, statusCode: 404, httpVersion: nil,
                                            headerFields: nil)!, Data())
                }
            }

            let monitor = makeMonitor()
            let operation = TrackedOperation(kind: .updateAll, id: 5, startedAt: .now)
            settings.trackedOperations = [operation]
            await monitor.track(operation, settings: settings, container: container, client: api).value

            #expect(monitor.lastOutcome == .updated(newCount: 1))
        }
    }

    @Test func aPrunedJobRowAppliesContentButReportsItAsUnconfirmed() async throws {
        try await MockURLProtocol.lock.withLock {
            let container = try makeContainer()
            let settings = makeSettings()
            let writer = SyncWriter(modelContainer: container)
            _ = await writer.replaceFeeds([
                SyncFeedWire(id: 1, name: "Feed", identifier: "f1", tagIds: [], logoImageHash: nil)
            ])
            _ = await writer.upsertSummaries([
                SyncArticleSummaryWire(id: 100, feedId: 1, name: "Old", identifier: "art-100",
                                       date: .now, author: "", read: false, starred: false,
                                       createdAt: .now, updatedAt: .now)
            ])
            var jobCalls = 0
            let api = client { request in
                switch request.url!.path {
                case "/api/v1/jobs/42":
                    jobCalls += 1
                    if jobCalls == 1 {
                        return self.json(request, """
                        {"jobId":42,"runId":null,"kind":"article.reload","progress":10,
                         "status":"running","error":"","startedAt":null,"finishedAt":null}
                        """)
                    }
                    return self.json(request, #"{"error":{"code":"not_found","message":"gone"}}"#,
                                     status: 404)
                case "/api/v1/articles/100/content":
                    return self.json(request, #"{"version":1,"blocks":[]}"#)
                case "/api/v1/feeds": return self.json(request, #"{"feeds":[]}"#)
                case "/api/v1/tags": return self.json(request, #"{"tags":[]}"#)
                case "/api/v1/articles/sync":
                    return self.json(request, #"{"new":[],"updated":[],"removed":[],"nextCursor":null}"#)
                default:
                    return (HTTPURLResponse(url: request.url!, statusCode: 404, httpVersion: nil,
                                            headerFields: nil)!, Data())
                }
            }

            let monitor = makeMonitor()
            let operation = TrackedOperation(kind: .reloadArticle(serverID: 100), id: 42,
                                             startedAt: .now)
            settings.trackedOperations = [operation]
            await monitor.track(operation, settings: settings, container: container, client: api).value

            #expect(monitor.lastOutcome == .unconfirmed(.reloadArticle(serverID: 100)))
        }
    }

    @Test func aCompletedReloadPicksUpARewrittenTitleViaTheFollowUpSync() async throws {
        try await MockURLProtocol.lock.withLock {
            let container = try makeContainer()
            let settings = makeSettings()
            let writer = SyncWriter(modelContainer: container)
            _ = await writer.replaceFeeds([
                SyncFeedWire(id: 1, name: "Feed", identifier: "f1", tagIds: [], logoImageHash: nil)
            ])
            _ = await writer.upsertSummaries([
                SyncArticleSummaryWire(id: 100, feedId: 1, name: "Old Title", identifier: "art-100",
                                       date: .now, author: "", read: false, starred: false,
                                       createdAt: .now, updatedAt: .now)
            ])
            let readerContext = ModelContext(container)
            let visible = try readerContext.fetch(
                FetchDescriptor<Article>(predicate: #Predicate { $0.serverID == 100 })
            ).first!
            #expect(visible.title == "Old Title")

            let syncBody = #"""
            {"new":[],"updated":[{"id":100,"feedId":1,"name":"New Title","identifier":"art-100","date":"2026-01-01T00:00:00Z","author":"","icon":null,"read":false,"starred":false,"createdAt":"2026-01-01T00:00:00Z","updatedAt":"2026-01-02T00:00:00Z"}],"removed":[],"nextCursor":null}
            """#
            let api = client { request in
                switch request.url!.path {
                case "/api/v1/jobs/42":
                    return self.json(request, """
                    {"jobId":42,"runId":null,"kind":"article.reload","progress":100,
                     "status":"completed","error":"","startedAt":null,"finishedAt":null}
                    """)
                case "/api/v1/articles/100/content":
                    return self.json(request, #"{"version":1,"blocks":[]}"#)
                case "/api/v1/feeds":
                    // Keep the feed the article belongs to alive in this response -- the follow-up
                    // sync inside fetchAndApplyContent is a real /feeds fetch, and SyncWriter.replaceFeeds
                    // prunes (and cascade-deletes the articles of) any local feed missing from it. An
                    // empty response here would delete Feed 1 and its Article mid-test.
                    return self.json(request, #"{"feeds":[{"id":1,"name":"Feed","identifier":"f1","tagIds":[],"logoImageHash":null}]}"#)
                case "/api/v1/tags": return self.json(request, #"{"tags":[]}"#)
                case "/api/v1/articles/sync": return self.json(request, syncBody)
                default:
                    return (HTTPURLResponse(url: request.url!, statusCode: 404, httpVersion: nil,
                                            headerFields: nil)!, Data())
                }
            }

            let monitor = makeMonitor()
            let operation = TrackedOperation(kind: .reloadArticle(serverID: 100), id: 42,
                                             startedAt: .now)
            settings.trackedOperations = [operation]
            await monitor.track(operation, settings: settings, container: container, client: api,
                                visibleArticle: visible).value

            #expect(visible.title == "New Title")
        }
    }

    /// Extra case beyond the brief: an operation resumed after a relaunch has NO visible `Article`
    /// (the reader wasn't holding one when the process restarted), so `feedName` cannot come from
    /// `visible?.feed?.name`. It must instead be resolved from the store by the article's
    /// `serverID`, or a resumed reload's completion renders as "No new articles." downstream
    /// (`RefreshOutcome.message(newCount: 0, feedName: nil)`) despite genuinely succeeding.
    @Test func aCompletedReloadWithNoVisibleArticleStillReportsTheFeedNameFromTheStore() async throws {
        try await MockURLProtocol.lock.withLock {
            let container = try makeContainer()
            let settings = makeSettings()
            let writer = SyncWriter(modelContainer: container)
            _ = await writer.replaceFeeds([
                SyncFeedWire(id: 1, name: "Feed", identifier: "f1", tagIds: [], logoImageHash: nil)
            ])
            _ = await writer.upsertSummaries([
                SyncArticleSummaryWire(id: 100, feedId: 1, name: "Old", identifier: "art-100",
                                       date: .now, author: "", read: false, starred: false,
                                       createdAt: .now, updatedAt: .now)
            ])

            let api = client { request in
                switch request.url!.path {
                case "/api/v1/jobs/42":
                    return self.json(request, """
                    {"jobId":42,"runId":null,"kind":"article.reload","progress":100,
                     "status":"completed","error":"","startedAt":null,"finishedAt":null}
                    """)
                case "/api/v1/articles/100/content":
                    return self.json(request, #"{"version":1,"blocks":[]}"#)
                case "/api/v1/feeds":
                    // Keep the feed the article belongs to alive in this response -- the follow-up
                    // sync inside fetchAndApplyContent is a real /feeds fetch, and SyncWriter.replaceFeeds
                    // prunes (and cascade-deletes the articles of) any local feed missing from it. An
                    // empty response here would delete Feed 1 and its Article mid-test.
                    return self.json(request, #"{"feeds":[{"id":1,"name":"Feed","identifier":"f1","tagIds":[],"logoImageHash":null}]}"#)
                case "/api/v1/tags": return self.json(request, #"{"tags":[]}"#)
                case "/api/v1/articles/sync":
                    return self.json(request, #"{"new":[],"updated":[],"removed":[],"nextCursor":null}"#)
                default:
                    return (HTTPURLResponse(url: request.url!, statusCode: 404, httpVersion: nil,
                                            headerFields: nil)!, Data())
                }
            }

            let monitor = makeMonitor()
            // No `visibleArticle:` argument -- simulates a resumed operation after a relaunch.
            let operation = TrackedOperation(kind: .reloadArticle(serverID: 100), id: 42,
                                             startedAt: .now)
            settings.trackedOperations = [operation]
            await monitor.track(operation, settings: settings, container: container, client: api).value

            #expect(monitor.lastOutcome == .reloaded(articleServerID: 100, feedName: "Feed"))
        }
    }
}
