import Foundation
import Testing
@testable import Yana

@MainActor
@Suite("ReadingPositionLiveSync", .serialized)
struct ReadingPositionLiveSyncTests {
    // Every test wraps its whole body in `MockURLProtocol.lock.withLock` -- see
    // `YanaAPIClientTests.swift` for why this is required across suites sharing the static stub.

    private func freshSettings() -> AppSettings {
        let suite = "ReadingPositionLiveSyncTests.\(UUID().uuidString)"
        let defaults = UserDefaults(suiteName: suite)!
        defaults.removePersistentDomain(forName: suite)
        return AppSettings(defaults: defaults)
    }

    private func stubClient(sseBody: String) -> YanaAPIClient {
        let config = URLSessionConfiguration.ephemeral
        config.protocolClasses = [MockURLProtocol.self]
        MockURLProtocol.stub = { request in
            let response = HTTPURLResponse(url: request.url!, statusCode: 200, httpVersion: nil, headerFields: ["Content-Type": "text/event-stream"])!
            return (response, sseBody.data(using: .utf8)!)
        }
        return YanaAPIClient(baseURL: URL(string: "https://example.test")!, token: "t", session: URLSession(configuration: config))
    }

    private func wait(until predicate: @escaping () -> Bool) async {
        for _ in 0..<80 where !predicate() {
            try? await Task.sleep(for: .milliseconds(50))
        }
    }

    @Test func appliesALiveReadingPositionEventViaTheSharedLastWriterWinsRule() async throws {
        try await MockURLProtocol.lock.withLock {
            let client = stubClient(
                sseBody: "event: readingPosition\ndata: {\"articleId\":42,\"updatedAt\":\"2026-01-01T00:00:00Z\"}\n\n"
            )
            let settings = freshSettings()
            let sync = ReadingPositionLiveSync(reconnectDelay: .seconds(60), clientProvider: { _ in client })
            sync.start(settings: settings)
            await wait { settings.pendingRemoteReadingPosition != nil }
            sync.stop()

            #expect(settings.pendingRemoteReadingPosition == 42)
            #expect(settings.readingPositionUpdatedAt == ISO8601DateFormatter().date(from: "2026-01-01T00:00:00Z"))
        }
    }

    @Test func ignoresNonReadingPositionEventsOnTheSameStream() async throws {
        try await MockURLProtocol.lock.withLock {
            let client = stubClient(
                sseBody: "event: job\ndata: {\"jobId\":1,\"runId\":null,\"kind\":\"article.reload\",\"status\":\"completed\",\"progress\":1}\n\n"
            )
            let settings = freshSettings()
            let sync = ReadingPositionLiveSync(reconnectDelay: .seconds(60), clientProvider: { _ in client })
            sync.start(settings: settings)
            try? await Task.sleep(for: .milliseconds(200))
            sync.stop()

            #expect(settings.pendingRemoteReadingPosition == nil)
        }
    }

    @Test func startIsANoOpWhenUnpaired() async throws {
        // The provider resolving `nil` (as `AuthenticatedClient.current` does when unpaired) means
        // the retry loop should sit there quietly and never touch the network -- see
        // `schedulePushIsANoOpWhenUnpaired` in `ReadingPositionSyncTests` for the same invariant
        // on the push side.
        let settings = freshSettings()
        let sync = ReadingPositionLiveSync(reconnectDelay: .seconds(60), clientProvider: { _ in nil })
        sync.start(settings: settings)
        try? await Task.sleep(for: .milliseconds(100))
        sync.stop()
        #expect(settings.pendingRemoteReadingPosition == nil)
    }

    /// `@unchecked Sendable` box for the call counter -- mirrors `TerminationFlag` in
    /// `JobEventsClientTests.swift`, the established pattern for test-only mutable state observed
    /// from inside an async closure.
    private final class CallCounter: @unchecked Sendable {
        var count = 0
    }

    @Test func startIsIdempotentWhileAlreadyRunning() async throws {
        try await MockURLProtocol.lock.withLock {
            let counter = CallCounter()
            let client = stubClient(sseBody: "")
            let sync = ReadingPositionLiveSync(
                reconnectDelay: .seconds(60),
                clientProvider: { _ in counter.count += 1; return client }
            )
            let settings = freshSettings()
            sync.start(settings: settings)
            sync.start(settings: settings) // must not open a second connection
            try? await Task.sleep(for: .milliseconds(100))
            sync.stop()

            #expect(counter.count == 1)
        }
    }

    @Test func stopIsSafeToCallWithoutAPriorStart() {
        let sync = ReadingPositionLiveSync()
        sync.stop() // must not crash
    }
}
