import Foundation
import Testing
@testable import Yana

@MainActor
@Suite("PendingWriteQueue")
struct PendingWriteQueueTests {
    private func freshSettings() -> AppSettings {
        let suite = "PendingWriteQueueTests.\(UUID().uuidString)"
        let defaults = UserDefaults(suiteName: suite)!
        defaults.removePersistentDomain(forName: suite)
        return AppSettings(defaults: defaults)
    }

    private func stubClient(status: Int, body: Data) -> YanaAPIClient {
        let config = URLSessionConfiguration.ephemeral
        config.protocolClasses = [MockURLProtocol.self]
        MockURLProtocol.stub = { request in
            let response = HTTPURLResponse(url: request.url!, statusCode: status, httpVersion: nil, headerFields: ["Content-Type": "application/json"])!
            return (response, body)
        }
        return YanaAPIClient(baseURL: URL(string: "https://example.test")!, token: "t", session: URLSession(configuration: config))
    }

    @Test func enqueueDedupesByArticleAndFieldKind() {
        let settings = freshSettings()
        PendingWriteQueue.enqueue(PendingWrite(articleServerID: 1, field: .read(true)), settings: settings)
        PendingWriteQueue.enqueue(PendingWrite(articleServerID: 1, field: .read(true)), settings: settings)
        PendingWriteQueue.enqueue(PendingWrite(articleServerID: 1, field: .starred(true)), settings: settings)
        #expect(settings.pendingWrites.count == 2)
    }

    @Test func enqueueReplacesSameKindWithDifferentValue() {
        let settings = freshSettings()
        PendingWriteQueue.enqueue(PendingWrite(articleServerID: 1, field: .starred(true)), settings: settings)
        PendingWriteQueue.enqueue(PendingWrite(articleServerID: 1, field: .starred(false)), settings: settings)
        #expect(settings.pendingWrites.count == 1)
        #expect(settings.pendingWrites.first?.field == .starred(false))
    }

    @Test func flushRemovesSuccessfulWritesAndKeepsFailedOnes() async throws {
        try await MockURLProtocol.lock.withLock {
            let settings = freshSettings()
            PendingWriteQueue.enqueue(PendingWrite(articleServerID: 100, field: .read(true)), settings: settings)
            PendingWriteQueue.enqueue(PendingWrite(articleServerID: 999, field: .starred(true)), settings: settings)

            let config = URLSessionConfiguration.ephemeral
            config.protocolClasses = [MockURLProtocol.self]
            MockURLProtocol.stub = { request in
                let ok = request.url!.path == "/api/v1/articles/100"
                let status = ok ? 200 : 404
                let body = ok
                    ? #"{"id":100,"read":true}"#.data(using: .utf8)!
                    : #"{"error":{"code":"not_found","message":"nope"}}"#.data(using: .utf8)!
                let response = HTTPURLResponse(url: request.url!, statusCode: status, httpVersion: nil, headerFields: ["Content-Type": "application/json"])!
                return (response, body)
            }
            let client = YanaAPIClient(baseURL: URL(string: "https://example.test")!, token: "t", session: URLSession(configuration: config))

            await PendingWriteQueue.flush(using: ArticleActions(client: client), settings: settings)

            #expect(settings.pendingWrites == [PendingWrite(articleServerID: 999, field: .starred(true))])
        }
    }

    /// Reproduces the race Finding 1 covers: a write lands in `settings.pendingWrites` (e.g. a
    /// user star/read action) WHILE `flush` is still awaiting an in-flight network call for a
    /// different, earlier-queued write. The stub below performs that concurrent `enqueue` itself,
    /// synchronously, from inside the response callback for the first request -- simulating the
    /// interleaving without needing real concurrency. A blind `settings.pendingWrites = remaining`
    /// write-back would silently drop the article-777 write it never knew about; the fixed
    /// filter-by-succeeded write-back must preserve it.
    @Test func flushDoesNotDropAWriteEnqueuedWhileFlushIsInFlight() async throws {
        try await MockURLProtocol.lock.withLock {
            let settings = freshSettings()
            PendingWriteQueue.enqueue(PendingWrite(articleServerID: 100, field: .read(true)), settings: settings)
            PendingWriteQueue.enqueue(PendingWrite(articleServerID: 999, field: .starred(true)), settings: settings)

            let config = URLSessionConfiguration.ephemeral
            config.protocolClasses = [MockURLProtocol.self]
            MockURLProtocol.stub = { request in
                if request.url!.path == "/api/v1/articles/100" {
                    // Simulate a concurrent user action enqueuing a new write while this flush's
                    // first network call is still "in flight". `startLoading()` runs on a
                    // URLSession-internal background thread, not the main thread `flush` (and
                    // `settings`, `@MainActor`) is isolated to -- hop to main synchronously (the
                    // main thread is idle here, since `flush` is suspended awaiting this very
                    // response, so this cannot deadlock) and assert isolation for the compiler.
                    DispatchQueue.main.sync {
                        MainActor.assumeIsolated {
                            PendingWriteQueue.enqueue(PendingWrite(articleServerID: 777, field: .starred(true)), settings: settings)
                        }
                    }
                    let response = HTTPURLResponse(url: request.url!, statusCode: 200, httpVersion: nil, headerFields: ["Content-Type": "application/json"])!
                    return (response, #"{"id":100,"read":true}"#.data(using: .utf8)!)
                }
                let response = HTTPURLResponse(url: request.url!, statusCode: 404, httpVersion: nil, headerFields: ["Content-Type": "application/json"])!
                return (response, #"{"error":{"code":"not_found","message":"nope"}}"#.data(using: .utf8)!)
            }
            let client = YanaAPIClient(baseURL: URL(string: "https://example.test")!, token: "t", session: URLSession(configuration: config))

            await PendingWriteQueue.flush(using: ArticleActions(client: client), settings: settings)

            // article 100 succeeded and is gone; article 999 failed and stays; article 777 was
            // enqueued mid-flush and must survive the write-back untouched.
            let expected = [
                PendingWrite(articleServerID: 999, field: .starred(true)),
                PendingWrite(articleServerID: 777, field: .starred(true)),
            ]
            #expect(settings.pendingWrites.count == expected.count)
            for write in expected {
                #expect(settings.pendingWrites.contains(write))
            }
        }
    }

    @Test func flushIsANoOpWhenQueueIsEmpty() async throws {
        let settings = freshSettings()
        // No stub configured -- if flush tried to make a request, this would hang/fail.
        await PendingWriteQueue.flush(using: ArticleActions(client: stubClient(status: 200, body: Data())), settings: settings)
        #expect(settings.pendingWrites.isEmpty)
    }
}
