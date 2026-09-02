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
    ///
    /// `activity:` is a throwaway `UpdateActivity`, not the app-wide `.shared` one: these tests
    /// drive `begin()`/`end()`/`setProgress` for real, and doing that on the singleton leaves the
    /// in-flight count and percentage perturbed for whatever runs next in the same process.
    private func makeMonitor() -> OperationMonitor {
        OperationMonitor(pollInterval: .milliseconds(5), slowPollInterval: .milliseconds(5),
                         youngPhase: .seconds(60), nudgeSlice: .milliseconds(1),
                         activity: UpdateActivity())
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
            #expect(monitor.lastOutcomeEvent?.outcome == .failed(.reloadArticle(serverID: 100)))
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
    /// the same bail-out reasoning `OperationMonitor`'s run-polling applies elsewhere.
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
            #expect(monitor.lastOutcomeEvent?.outcome == .unconfirmed(.reloadArticle(serverID: 100)))
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
            #expect(monitor.lastOutcomeEvent?.outcome == .unconfirmed(.reloadArticle(serverID: 100)))
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
            #expect(monitor.lastOutcomeEvent?.outcome == .unconfirmed(.reloadArticle(serverID: 100)))
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
            #expect(monitor.lastOutcomeEvent?.outcome == .reloaded(articleServerID: 100, feedName: "Feed"))
        }
    }

    /// Regression pin for the production bug behind `Block.preservingSummary`'s use here: a
    /// reload replaces `blocks` wholesale (`fetchAndApplyContent`'s direct write to the visible
    /// object, and `SyncWriter.applyContent` on the stored row), and an incoming document with no
    /// summary of its own must not silently wipe a summary the user generated locally on this
    /// device. Seeds the visible article with a summary already in place, completes a reload whose
    /// incoming document carries none, and checks the summary survives on both the in-memory
    /// object and a fresh fetch of the stored row.
    @Test func aCompletedReloadPreservesALocallyGeneratedSummary() async throws {
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
            // Seed a locally generated summary via the shared `Block` helpers, the way
            // `ReaderActions.summarize` actually writes one, rather than hand-rolling `.summary(...)`.
            let existingBody: [Block] = [.paragraph([InlineRun(text: "The old article body.")])]
            visible.blocks = Block.settingSummary(
                [.paragraph([InlineRun(text: "A locally generated summary.")])], in: existingBody
            )
            try readerContext.save()
            #expect(Block.containsSummary(visible.blocks))

            let api = client { request in
                switch request.url!.path {
                case "/api/v1/jobs/42":
                    return self.json(request, """
                    {"jobId":42,"runId":null,"kind":"article.reload","progress":100,
                     "status":"completed","error":"","startedAt":null,"finishedAt":null}
                    """)
                case "/api/v1/articles/100/content":
                    // No summary in the incoming document -- a plain reload from the source, same
                    // as the server always sends unless it also has "Summarize" enabled for this
                    // feed.
                    return self.json(request, #"""
                    {"version":1,"blocks":[{"type":"paragraph","runs":[{"text":"fresh reload text","styles":[],"link":null}]}]}
                    """#)
                case "/api/v1/feeds":
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

            #expect(visible.plainText.contains("fresh reload text"))
            #expect(Block.summaryContents(of: visible.blocks).map(BlockParser.plainText)?
                .contains("A locally generated summary.") == true)

            let stored = try ModelContext(container).fetch(
                FetchDescriptor<Article>(predicate: #Predicate<Article> { $0.serverID == 100 })
            ).first!
            #expect(Block.summaryContents(of: stored.blocks).map(BlockParser.plainText)?
                .contains("A locally generated summary.") == true)
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

            #expect(monitor.lastOutcomeEvent?.outcome == .updated(newCount: 1))
            // "Syncs once": the follow-up sync after the run completes must not loop -- a second
            // (or more) `/articles/sync` call here would mean either a resync-required retry loop
            // or a duplicate sync pass, either of which would double-count `newCount` on a syncBody
            // that returns the same "new" article on repeat.
            #expect(syncCalls == 1)
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
                    return self.json(request, #"""
                    {"version":1,"blocks":[{"type":"paragraph","runs":[{"text":"fresh","styles":[],"link":null}]}]}
                    """#)
                case "/api/v1/feeds":
                    // Keep the feed the article belongs to alive in this response -- see the other
                    // reload tests' identical comment. An empty list here would cascade-delete the
                    // very article whose content this test claims to verify.
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
            await monitor.track(operation, settings: settings, container: container, client: api).value

            #expect(monitor.lastOutcomeEvent?.outcome == .unconfirmed(.reloadArticle(serverID: 100)))
            // The row being pruned mid-poll doesn't mean nothing was fetched -- `.gone` still
            // applies whatever content it can before reporting unconfirmed (see the `.gone` arm's
            // doc comment in `OperationMonitor.monitor`). A fresh fetch (not the `writer`'s own
            // in-memory object) proves the write actually reached the store, not just an
            // in-memory copy.
            let stored = try ModelContext(container).fetch(
                FetchDescriptor<Article>(predicate: #Predicate<Article> { $0.serverID == 100 })
            ).first!
            #expect(stored.hasContent)
            #expect(stored.plainText.contains("fresh"))
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

            #expect(monitor.lastOutcomeEvent?.outcome == .reloaded(articleServerID: 100, feedName: "Feed"))
        }
    }

    @Test func resumeMonitorsARecordPersistedByAPreviousSession() async throws {
        try await MockURLProtocol.lock.withLock {
            let container = try makeContainer()
            let settings = makeSettings()
            // Written by a previous launch; nothing in this session triggered it.
            settings.trackedOperations = [
                TrackedOperation(kind: .updateAll, id: 5, startedAt: Date(timeIntervalSince1970: 1))
            ]
            var runCalls = 0
            let api = client { request in
                switch request.url!.path {
                case "/api/v1/runs/5":
                    runCalls += 1
                    return self.json(request, """
                    {"runId":5,"status":"completed","progress":100,"totalJobs":1,
                     "completedJobs":1,"failedJobs":0}
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
            let tasks = monitor.resume(settings: settings, container: container,
                                       clientProvider: { _ in api })
            for task in tasks { await task.value }

            #expect(runCalls == 1)
            #expect(settings.trackedOperations.isEmpty)
            #expect(monitor.lastOutcomeEvent?.outcome == .updated(newCount: 0))
        }
    }

    @Test func resumeIsIdempotentSoAForegroundCallDoesNotDoubleMonitor() async throws {
        try await MockURLProtocol.lock.withLock {
            let container = try makeContainer()
            let settings = makeSettings()
            settings.trackedOperations = [
                TrackedOperation(kind: .updateAll, id: 5, startedAt: .now)
            ]
            let api = client { request in
                switch request.url!.path {
                case "/api/v1/runs/5":
                    return self.json(request, """
                    {"runId":5,"status":"running","progress":10,"totalJobs":1,
                     "completedJobs":0,"failedJobs":0}
                    """)
                default:
                    return (HTTPURLResponse(url: request.url!, statusCode: 404, httpVersion: nil,
                                            headerFields: nil)!, Data())
                }
            }

            let monitor = makeMonitor()
            let first = monitor.resume(settings: settings, container: container,
                                       clientProvider: { _ in api })
            let second = monitor.resume(settings: settings, container: container,
                                        clientProvider: { _ in api })
            #expect(first.count == 1)
            #expect(second.isEmpty)
            monitor.stopWatching(settings: settings)
            for task in first { await task.value }
        }
    }

    /// Pins the composite-key constraint `startEvents` relies on: `inFlight` is keyed by
    /// `TrackedOperation.monitorKey` ("job-<id>"/"run-<id>"), not the bare numeric id, precisely
    /// because a job id and a run id are drawn from different server-side tables that collide
    /// freely. A same-numbered `job` SSE event must never move a tracked `run`'s percentage (or
    /// vice versa) -- getting the key format wrong is silent, since it only shows a wrong
    /// percentage, never a wrong outcome.
    @Test func sseJobEventNeverMovesASameNumberedRunsProgress() async throws {
        try await MockURLProtocol.lock.withLock {
            let container = try makeContainer()
            let settings = makeSettings()
            settings.trackedOperations = [
                TrackedOperation(kind: .updateAll, id: 5, startedAt: .now)
            ]
            // The run event (runId 5) should move this run's progress to 60. The job event
            // (jobId 5, same number, different table) must be ignored entirely -- there is no
            // tracked reload with job id 5, only a tracked run with id 5.
            let sseBody = "event: run\ndata: {\"runId\":5,\"status\":\"running\",\"progress\":60,\"totalJobs\":1,\"completedJobs\":0,\"failedJobs\":0}\n\n"
                + "event: job\ndata: {\"jobId\":5,\"runId\":null,\"kind\":\"article.reload\",\"status\":\"running\",\"progress\":99}\n\n"
            let api = client { request in
                switch request.url!.path {
                case "/api/v1/runs/5":
                    return self.json(request, """
                    {"runId":5,"status":"running","progress":10,"totalJobs":1,
                     "completedJobs":0,"failedJobs":0}
                    """)
                case "/api/v1/jobs/events":
                    let response = HTTPURLResponse(url: request.url!, statusCode: 200,
                                                   httpVersion: nil,
                                                   headerFields: ["Content-Type": "text/event-stream"])!
                    return (response, sseBody.data(using: .utf8)!)
                default:
                    return (HTTPURLResponse(url: request.url!, statusCode: 404, httpVersion: nil,
                                            headerFields: nil)!, Data())
                }
            }

            let monitor = makeMonitor()
            let tasks = monitor.resume(settings: settings, container: container,
                                       clientProvider: { _ in api })
            monitor.startEvents(settings: settings, clientProvider: { _ in api },
                                reconnectDelay: .seconds(30))

            // The frames arrive as soon as the stream connects; poll briefly for the run event to
            // land rather than sleeping a fixed guess.
            for _ in 0..<50 where monitor.progressPercent != 60 {
                try await Task.sleep(for: .milliseconds(10))
            }

            #expect(monitor.progressPercent == 60)

            monitor.stopWatching(settings: settings)
            monitor.stopEvents()
            for task in tasks { await task.value }
            // Give the SSE task's cancellation a moment to actually unwind before the lock
            // releases, so a still-in-flight reconnect from THIS test can't consume the NEXT
            // test's stub.
            try await Task.sleep(for: .milliseconds(20))
        }
    }

    /// The point of publishing an `OperationOutcomeEvent` rather than a bare `OperationOutcome`.
    /// Reloading the same article twice produces two byte-identical
    /// `.reloaded(articleServerID: 100, feedName: "Feed")` values, and the observers are SwiftUI
    /// `.onChange` handlers, which fire only when the observed value actually changes -- so the
    /// second delivery used to be dropped: no toast, and no `reloadToken` bump, leaving the
    /// pre-reload page rendered after a reload the server had genuinely finished. The sequence
    /// number is what makes delivery independent of the value.
    @Test func twoConsecutiveIdenticalOutcomesAreBothDelivered() async throws {
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
            await monitor.track(operation, settings: settings, container: container,
                                client: api).value
            let first = monitor.lastOutcomeEvent
            #expect(first?.outcome == .reloaded(articleServerID: 100, feedName: "Feed"))

            // The same article reloaded again: same job id, same server answer, same outcome
            // value.
            settings.trackedOperations = [operation]
            await monitor.track(operation, settings: settings, container: container,
                                client: api).value
            let second = monitor.lastOutcomeEvent
            #expect(second?.outcome == first?.outcome)

            // The events differ even though the outcomes do not -- which is exactly what makes an
            // `.onChange` observer fire the second time.
            #expect(second != first)
            #expect(second?.sequence == (first?.sequence ?? 0) + 1)
        }
    }

    /// The regression guard for the invariant this whole type exists to establish: **no timeout is
    /// ever treated as success.** Its predecessor waited ten seconds for one SSE event and then
    /// fetched the article anyway and reported "Reloaded" while the reader showed pre-reload
    /// content. A job that never reports a terminal status is polled here far past any plausible
    /// give-up threshold, and must produce no outcome at all and fetch no content. Deterministic:
    /// it waits on the poll *count*, not on wall-clock time.
    @Test func aJobThatNeverEndsNeverProducesAnOutcomeAndNeverFetchesContent() async throws {
        try await MockURLProtocol.lock.withLock {
            let container = try makeContainer()
            let settings = makeSettings()
            var polls = 0
            var contentFetches = 0
            let api = client { request in
                if request.url!.path == "/api/v1/articles/100/content" { contentFetches += 1 }
                guard request.url!.path == "/api/v1/jobs/42" else {
                    return (HTTPURLResponse(url: request.url!, statusCode: 404, httpVersion: nil,
                                            headerFields: nil)!, Data())
                }
                polls += 1
                return self.json(request, """
                {"jobId":42,"runId":null,"kind":"article.reload","progress":40,"status":"running",
                 "error":"","startedAt":null,"finishedAt":null}
                """)
            }

            // 1ms polls, so "many cycles" costs milliseconds rather than seconds.
            let monitor = OperationMonitor(pollInterval: .milliseconds(1),
                                           slowPollInterval: .milliseconds(1),
                                           youngPhase: .seconds(60), nudgeSlice: .milliseconds(1),
                                           activity: UpdateActivity())
            let operation = TrackedOperation(kind: .reloadArticle(serverID: 100), id: 42,
                                             startedAt: .now)
            settings.trackedOperations = [operation]
            let task = monitor.track(operation, settings: settings, container: container,
                                     client: api)

            // Wait for the poll loop to have gone round many times -- 40 iterations is well past
            // the 10s/5-attempt shapes any reintroduced client-side give-up would use, while
            // staying a bounded number of iterations rather than a real-time sleep.
            for _ in 0..<2000 where polls < 40 {
                try await Task.sleep(for: .milliseconds(1))
            }
            #expect(polls >= 40)
            #expect(monitor.lastOutcomeEvent == nil)
            #expect(contentFetches == 0)
            #expect(monitor.isActive)
            // Still persisted: nothing terminal was ever observed, so the record has to survive
            // for a later resume.
            #expect(settings.trackedOperations == [operation])

            monitor.stopWatching(settings: settings)
            await task.value
            // Cancellation is "stop watching", not a result -- and it must stay silent even
            // though the loop had a perfectly good percentage in hand.
            #expect(monitor.lastOutcomeEvent == nil)
        }
    }
}
