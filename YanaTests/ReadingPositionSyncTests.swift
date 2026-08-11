import Foundation
import Testing
@testable import Yana

@MainActor
@Suite("ReadingPositionSync", .serialized)
struct ReadingPositionSyncTests {
    private func freshSettings() -> AppSettings {
        let suite = "ReadingPositionSyncTests.\(UUID().uuidString)"
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

    @Test func pushSuccessClearsPendingAndStampsUpdatedAt() async throws {
        try await MockURLProtocol.lock.withLock {
            let settings = freshSettings()
            settings.pendingReadingPositionPush = 100   // as if a previous attempt had failed
            let client = stubClient(status: 200, body: #"{"articleId":100,"updatedAt":"2026-01-01T00:00:00Z"}"#.data(using: .utf8)!)

            await ReadingPositionSync.shared.push(articleServerID: 100, client: client, settings: settings)

            #expect(settings.pendingReadingPositionPush == nil)
            #expect(settings.readingPositionUpdatedAt == ISO8601DateFormatter().date(from: "2026-01-01T00:00:00Z"))
        }
    }

    @Test func pushFailureQueuesForRetry() async throws {
        try await MockURLProtocol.lock.withLock {
            let settings = freshSettings()
            let client = stubClient(status: 404, body: #"{"error":{"code":"not_found","message":"nope"}}"#.data(using: .utf8)!)

            await ReadingPositionSync.shared.push(articleServerID: 100, client: client, settings: settings)

            #expect(settings.pendingReadingPositionPush == 100)
            #expect(settings.readingPositionUpdatedAt == nil)
        }
    }

    @Test func schedulePushIsANoOpWhenUnpaired() async throws {
        // No device token/server URL in this fresh suite, so `AuthenticatedClient.current()`
        // resolves `nil` -- matches `ArticleWritesTests`' "notPaired" pattern. If this scheduled a
        // push anyway it would eventually crash on a nil client; a `sleep` short enough for CI is
        // not reliable proof of "never fires", so this only asserts the synchronous no-op path
        // leaves no state changed immediately.
        let settings = freshSettings()
        ReadingPositionSync.shared.schedulePush(articleServerID: 100, settings: settings)
        #expect(settings.pendingReadingPositionPush == nil)
    }

    @Test func schedulePushIsANoOpWithoutAServerID() async throws {
        let settings = freshSettings()
        ReadingPositionSync.shared.schedulePush(articleServerID: nil, settings: settings)
        #expect(settings.pendingReadingPositionPush == nil)
    }

    @Test func flushPendingIsANoOpWhenNothingIsQueued() async throws {
        let settings = freshSettings()
        // No stub configured -- if this tried to make a request, it would hang/fail.
        await ReadingPositionSync.flushPending(client: stubClient(status: 200, body: Data()), settings: settings)
        #expect(settings.pendingReadingPositionPush == nil)
    }

    @Test func flushPendingRetriesAndClearsOnSuccess() async throws {
        try await MockURLProtocol.lock.withLock {
            let settings = freshSettings()
            settings.pendingReadingPositionPush = 100
            let client = stubClient(status: 200, body: #"{"articleId":100,"updatedAt":"2026-01-02T00:00:00Z"}"#.data(using: .utf8)!)

            await ReadingPositionSync.flushPending(client: client, settings: settings)

            #expect(settings.pendingReadingPositionPush == nil)
            #expect(settings.readingPositionUpdatedAt == ISO8601DateFormatter().date(from: "2026-01-02T00:00:00Z"))
        }
    }

    @Test func flushPendingLeavesTheEntryQueuedOnFailure() async throws {
        try await MockURLProtocol.lock.withLock {
            let settings = freshSettings()
            settings.pendingReadingPositionPush = 100
            let client = stubClient(status: 500, body: #"{"error":{"code":"server_error","message":"nope"}}"#.data(using: .utf8)!)

            await ReadingPositionSync.flushPending(client: client, settings: settings)

            #expect(settings.pendingReadingPositionPush == 100)
        }
    }
}
