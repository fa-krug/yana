import Foundation
import Testing
@testable import Yana

@MainActor
@Suite("ReadingPositionSync", .serialized)
struct ReadingPositionSyncTests {
    private func freshSettings() -> AppSettings {
        // `ReadingPositionSync.shared`'s unacknowledged-local-write state is in-memory and outlives
        // a single test (a deliberately-failing push leaves it set), so clear it per test.
        ReadingPositionSync.shared.resetLocalWriteStateForTesting()
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

    // MARK: - applyRemoteUpdate (shared by SyncEngine's pull and ReadingPositionLiveSync's push)

    @Test func applyRemoteUpdateStashesAFreshPositionWhenNoneIsKnown() {
        let settings = freshSettings()
        let updatedAt = Date(timeIntervalSince1970: 1000)
        ReadingPositionSync.applyRemoteUpdate(articleId: 7, updatedAt: updatedAt, settings: settings)
        #expect(settings.pendingRemoteReadingPosition == 7)
        #expect(settings.readingPositionUpdatedAt == updatedAt)
    }

    @Test func applyRemoteUpdateAcceptsAStrictlyNewerUpdate() {
        let settings = freshSettings()
        settings.readingPositionUpdatedAt = Date(timeIntervalSince1970: 1000)
        ReadingPositionSync.applyRemoteUpdate(articleId: 7, updatedAt: Date(timeIntervalSince1970: 2000), settings: settings)
        #expect(settings.pendingRemoteReadingPosition == 7)
        #expect(settings.readingPositionUpdatedAt == Date(timeIntervalSince1970: 2000))
    }

    @Test func applyRemoteUpdateDropsAnUpdateNoNewerThanWhatIsAlreadyKnown() {
        let settings = freshSettings()
        settings.readingPositionUpdatedAt = Date(timeIntervalSince1970: 2000)
        ReadingPositionSync.applyRemoteUpdate(articleId: 7, updatedAt: Date(timeIntervalSince1970: 1000), settings: settings)
        #expect(settings.pendingRemoteReadingPosition == nil)
        #expect(settings.readingPositionUpdatedAt == Date(timeIntervalSince1970: 2000))
    }

    /// The bug this pins: the server fans a live `readingPosition` SSE event out to every open
    /// connection on the account, including the pushing device's own -- so that echo can arrive on
    /// a completely separate connection before this device's own PATCH response does. Before the
    /// fix, `readingPositionUpdatedAt` (the only guard `applyRemoteUpdate` had) wasn't stamped yet
    /// at that point, so the device treated its own in-flight write as a fresh remote update and
    /// would jump straight to it -- landing back on a stale/previous article the moment the user
    /// had already navigated on. `unacknowledgedLocalPosition` closes that window directly.
    @Test func applyRemoteUpdateIgnoresAnEchoOfAPushStillInFlight() async throws {
        try await MockURLProtocol.lock.withLock {
            let settings = freshSettings()
            let config = URLSessionConfiguration.ephemeral
            config.protocolClasses = [MockURLProtocol.self]
            MockURLProtocol.stub = { request in
                Thread.sleep(forTimeInterval: 0.3)   // simulate a slow PATCH round trip
                let response = HTTPURLResponse(url: request.url!, statusCode: 200, httpVersion: nil, headerFields: ["Content-Type": "application/json"])!
                return (response, #"{"articleId":42,"updatedAt":"2026-01-01T00:00:00Z"}"#.data(using: .utf8)!)
            }
            let client = YanaAPIClient(baseURL: URL(string: "https://example.test")!, token: "t", session: URLSession(configuration: config))

            let pushTask = Task { await ReadingPositionSync.shared.push(articleServerID: 42, client: client, settings: settings) }
            try? await Task.sleep(for: .milliseconds(80))   // let push() start and mark the in-flight id

            // The live SSE echo of this exact write races ahead of the PATCH response.
            ReadingPositionSync.applyRemoteUpdate(articleId: 42, updatedAt: ISO8601DateFormatter().date(from: "2026-01-01T00:00:00Z")!, settings: settings)

            #expect(settings.pendingRemoteReadingPosition == nil, "an echo of this device's own in-flight push must not be treated as a remote update")

            await pushTask.value
            #expect(settings.readingPositionUpdatedAt == ISO8601DateFormatter().date(from: "2026-01-01T00:00:00Z"))
        }
    }

    /// The reported bug: jumping to an article from the list writes the local anchor immediately
    /// but debounces the push by ~2s, so a sync pull -- or a live `readingPosition` SSE event --
    /// landing inside that window still carries the *previous* position. Since a remote update now
    /// applies mid-session, stashing it would drag the reader straight back off the article the
    /// user just opened.
    @Test func applyRemoteUpdateIgnoresAStalePositionWhileALocalJumpIsStillDebounced() throws {
        let settings = freshSettings()
        settings.serverBaseURL = "https://yana.example.com"
        KeychainService.saveDeviceToken("test-token")
        defer {
            KeychainService.deleteDeviceToken()
            ReadingPositionSync.shared.resetLocalWriteStateForTesting()
        }
        // `schedulePush` no-ops when unpaired, which would make the assertions below hold for the
        // wrong reason -- fail loudly instead if another suite's Keychain cleanup raced this one.
        try #require(AuthenticatedClient.current(settings: settings) != nil)

        // The user picks article 42 out of the list: anchor written now, push scheduled for later.
        settings.timelineAnchorServerID = 42
        ReadingPositionSync.shared.schedulePush(articleServerID: 42, settings: settings)

        ReadingPositionSync.applyRemoteUpdate(articleId: 7, updatedAt: Date(timeIntervalSince1970: 1000), settings: settings)

        #expect(settings.pendingRemoteReadingPosition == nil, "an unacknowledged local jump outranks the position the server still holds")
        #expect(
            settings.readingPositionUpdatedAt == nil,
            "dropped without stamping, so a genuinely newer remote position is only deferred, never swallowed"
        )
    }

    @Test func applyRemoteUpdateDropsAnUpdateForTheArticleAlreadyAnchoredLocally() {
        // A self-echo that arrives once the push has resolved and the user hasn't moved on: there
        // is nothing to apply, and stashing it would surface as a "remote" jump.
        let settings = freshSettings()
        let updatedAt = Date(timeIntervalSince1970: 1000)
        settings.timelineAnchorServerID = 42
        ReadingPositionSync.applyRemoteUpdate(articleId: 42, updatedAt: updatedAt, settings: settings)
        #expect(settings.pendingRemoteReadingPosition == nil)
        #expect(settings.readingPositionUpdatedAt == updatedAt, "still the newest server state this device knows about")
    }

    @Test func applyRemoteUpdateStillFollowsAnotherDeviceToADifferentArticle() {
        let settings = freshSettings()
        settings.timelineAnchorServerID = 42
        ReadingPositionSync.applyRemoteUpdate(articleId: 8, updatedAt: Date(timeIntervalSince1970: 1000), settings: settings)
        #expect(settings.pendingRemoteReadingPosition == 8)
    }

    @Test func remoteUpdatesFlowAgainOnceTheLocalPushIsAcknowledged() async throws {
        try await MockURLProtocol.lock.withLock {
            let settings = freshSettings()
            let client = stubClient(status: 200, body: #"{"articleId":100,"updatedAt":"2026-01-01T00:00:00Z"}"#.data(using: .utf8)!)
            settings.timelineAnchorServerID = 100

            await ReadingPositionSync.shared.push(articleServerID: 100, client: client, settings: settings)
            ReadingPositionSync.applyRemoteUpdate(articleId: 8, updatedAt: Date(timeIntervalSince1970: 2_000_000_000), settings: settings)

            #expect(settings.pendingRemoteReadingPosition == 8)
        }
    }

    @Test func aFailedPushKeepsTheLocalPositionAuthoritative() async throws {
        try await MockURLProtocol.lock.withLock {
            let settings = freshSettings()
            let client = stubClient(status: 500, body: #"{"error":{"code":"server_error","message":"nope"}}"#.data(using: .utf8)!)
            defer { ReadingPositionSync.shared.resetLocalWriteStateForTesting() }

            await ReadingPositionSync.shared.push(articleServerID: 100, client: client, settings: settings)
            ReadingPositionSync.applyRemoteUpdate(articleId: 7, updatedAt: Date(timeIntervalSince1970: 1000), settings: settings)

            #expect(settings.pendingReadingPositionPush == 100)
            #expect(settings.pendingRemoteReadingPosition == nil, "the queued local write is still newer than anything the server can report")
        }
    }

    @Test func applyRemoteUpdateDropsAnExactlyEqualUpdate() {
        // Guards against a device re-applying a position it just pushed itself, or a live SSE
        // event echoing the exact same write the periodic pull already applied.
        let settings = freshSettings()
        let same = Date(timeIntervalSince1970: 1500)
        settings.readingPositionUpdatedAt = same
        ReadingPositionSync.applyRemoteUpdate(articleId: 99, updatedAt: same, settings: settings)
        #expect(settings.pendingRemoteReadingPosition == nil)
    }
}
