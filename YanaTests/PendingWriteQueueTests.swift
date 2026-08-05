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

    @Test func flushIsANoOpWhenQueueIsEmpty() async throws {
        let settings = freshSettings()
        // No stub configured -- if flush tried to make a request, this would hang/fail.
        await PendingWriteQueue.flush(using: ArticleActions(client: stubClient(status: 200, body: Data())), settings: settings)
        #expect(settings.pendingWrites.isEmpty)
    }
}
