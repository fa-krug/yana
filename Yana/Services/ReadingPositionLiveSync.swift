import Foundation

/// Maintains a long-lived connection to `GET /api/v1/jobs/events` purely to observe live
/// `readingPosition` events (`yana-server`'s `src/lib/api/events.ts`), so a position pushed from
/// another paired device shows up on this one without waiting for the next full sync's pull
/// (`SyncEngine.syncReadingPosition()`). Reuses `JobEventsClient`'s existing SSE plumbing and
/// ignores every other event type on the stream -- `UpdateAndSync` opens its own separate,
/// short-lived connection for a single reload's `job` event; multiple concurrent readers of the
/// same per-user feed are fine, since the server fans every event out to every open connection.
///
/// Applying a live update goes through the exact same stash (`ReadingPositionSync
/// .applyRemoteUpdate`) the periodic pull uses, guards included -- a live push just makes that
/// stash available sooner. In particular a position this device itself just navigated to and
/// hasn't had acknowledged yet always outranks whatever arrives here, so the sender's own echo (the
/// server fans every event out to every open connection on the account, this one included) can
/// never move the reader off the article the user just opened.
///
/// Best-effort by construction, same as `JobEventsClient` itself: a dropped connection (or the
/// device simply being offline) loses nothing but low latency -- the next full sync's
/// `GET /api/v1/reading-position` pull always eventually catches up regardless. Reconnects on a
/// fixed delay while `start()` is active (including while unpaired, so pairing mid-session is
/// picked up without a relaunch); `stop()` (scene going to background) cancels outright rather
/// than paying for a connection nobody is watching.
@MainActor
final class ReadingPositionLiveSync {
    static let shared = ReadingPositionLiveSync()

    private var task: Task<Void, Never>?

    /// Space between reconnect attempts after the stream ends/errors, and between retries while
    /// unpaired. Deliberately fixed, not exponential: this is a background nicety, not a critical
    /// path, and a flat interval keeps a flaky connection from either hammering the server or
    /// going quiet for minutes.
    private let reconnectDelay: Duration

    /// Resolves the client on every (re)connect attempt. Overridable purely for tests (so they can
    /// inject a client wired to a mocked `URLSession` instead of going through the real Keychain +
    /// `URLSession.shared`); production always uses the default, matching
    /// `ArticleStore`'s `anchorProvider` injection pattern.
    private let clientProvider: (AppSettings) -> YanaAPIClient?

    init(
        reconnectDelay: Duration = .seconds(5),
        clientProvider: @escaping (AppSettings) -> YanaAPIClient? = { AuthenticatedClient.current(settings: $0) }
    ) {
        self.reconnectDelay = reconnectDelay
        self.clientProvider = clientProvider
    }

    /// Idempotent: calling while already running is a no-op, so scene-foreground handlers can
    /// call this unconditionally.
    func start(settings: AppSettings) {
        guard task == nil else { return }
        task = Task { [reconnectDelay, clientProvider] in
            while !Task.isCancelled {
                guard let client = clientProvider(settings) else {
                    try? await Task.sleep(for: reconnectDelay)
                    continue
                }
                var iterator = JobEventsClient(client: client).events().makeAsyncIterator()
                while let event = try? await iterator.next() {
                    if Task.isCancelled { return }
                    if case let .readingPosition(payload) = event {
                        ReadingPositionSync.applyRemoteUpdate(
                            articleId: payload.articleId, updatedAt: payload.updatedAt, settings: settings
                        )
                    }
                }
                guard !Task.isCancelled else { return }
                try? await Task.sleep(for: reconnectDelay)
            }
        }
    }

    /// Cancels the connection outright. Safe to call whether or not `start()` is running.
    func stop() {
        task?.cancel()
        task = nil
    }
}
