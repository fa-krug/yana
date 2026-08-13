import Foundation

/// Pushes the current reading-position anchor to the server, debounced so rapid timeline
/// navigation (flicking through many articles) doesn't fire a PATCH per page -- only once the
/// user settles on an article. Mirrors `ArticleWrites`' optimistic-write-then-retry pattern,
/// except there is nothing local to write optimistically here (the local anchor is
/// `AppSettings.timelineAnchorIdentifier`, already written synchronously by
/// `TimelineAnchorWriter.record`) -- this only owns the server side: push now, or remember to
/// retry later via `AppSettings.pendingReadingPositionPush` if the push fails, flushed by
/// `SyncEngine` alongside `PendingWriteQueue` (same first-thing-before-pulling ordering, for the
/// same reason: a local push still in flight must always win over a stale pull).
///
/// `shared` is the production entry point. A single shared instance holds the in-flight debounce
/// `Task` across the lightweight per-access wrapper objects (`ReaderAnchorController`,
/// `TimelineModel`) that call into it -- those are recreated on every access, so any debounce
/// state stored on them would be lost immediately.
///
/// This must be reached ONLY from a user-driven selection change (via `TimelineAnchorWriter.record`).
/// The remote-apply path (`jumpToSyncedTimelinePosition` on both platforms) must never call
/// `schedulePush`, or two open devices would trade anchor writes forever.
@MainActor
final class ReadingPositionSync {
    static let shared = ReadingPositionSync()

    private let debounceInterval: Duration
    private var debounceTask: Task<Void, Never>?

    /// `debounceInterval` is injectable purely for tests; production always uses the default.
    init(debounceInterval: Duration = .seconds(2)) {
        self.debounceInterval = debounceInterval
    }

    /// Schedules a debounced push of `articleServerID` as the account's current reading position.
    /// Call on every user-driven anchor write; only the last call within the debounce window
    /// actually reaches the network. No-ops when unpaired or the article hasn't synced yet
    /// (`articleServerID == nil`).
    func schedulePush(articleServerID: Int?, settings: AppSettings) {
        guard let articleServerID, let client = AuthenticatedClient.current(settings: settings) else { return }
        debounceTask?.cancel()
        let interval = debounceInterval
        debounceTask = Task { [weak self] in
            try? await Task.sleep(for: interval)
            guard !Task.isCancelled else { return }
            await self?.push(articleServerID: articleServerID, client: client, settings: settings)
        }
    }

    /// The actual PATCH, split out from `schedulePush` so it's directly testable without waiting
    /// on the debounce timer. On failure, queues for `flushPending` instead of dropping the write.
    func push(articleServerID: Int, client: YanaAPIClient, settings: AppSettings) async {
        do {
            let updatedAt = try await ArticleActions(client: client).setReadingPosition(articleServerID: articleServerID)
            settings.pendingReadingPositionPush = nil
            if let updatedAt { settings.readingPositionUpdatedAt = updatedAt }
        } catch {
            settings.pendingReadingPositionPush = articleServerID
        }
    }

    /// Retries a not-yet-acknowledged position push. Called by `SyncEngine` alongside
    /// `PendingWriteQueue.flush`, before the normal pull. A no-op when nothing is queued; delegates
    /// to `push`, whose failure path re-queues the same id -- a no-op re-write when it fails again,
    /// but the entry stays explicitly queued rather than relying on it never having been cleared.
    static func flushPending(client: YanaAPIClient, settings: AppSettings) async {
        guard let articleServerID = settings.pendingReadingPositionPush else { return }
        await shared.push(articleServerID: articleServerID, client: client, settings: settings)
    }

    /// Stashes a remote position update for the reader to apply at its next fresh session --
    /// never applied immediately, which would yank the user off the article they're actively
    /// reading (see `AppSettings.pendingRemoteReadingPosition`'s doc comment). Last-writer-wins by
    /// `updatedAt`: an update no newer than what this device already knows about is dropped, so
    /// this can never regress a local push still in flight or re-apply a position this device
    /// itself just pushed. The single source of truth for that rule -- shared by `SyncEngine`'s
    /// periodic `GET /api/v1/reading-position` pull and `ReadingPositionLiveSync`'s live SSE push,
    /// so a remote update is applied identically regardless of which route delivered it.
    static func applyRemoteUpdate(articleId: Int, updatedAt: Date, settings: AppSettings) {
        if let known = settings.readingPositionUpdatedAt, known >= updatedAt { return }
        settings.readingPositionUpdatedAt = updatedAt
        settings.pendingRemoteReadingPosition = articleId
    }

    /// Resolves a reading position pulled from another paired device (`applyRemoteUpdate` above)
    /// against `articles`, applying it as the new local anchor if it resolves. Consumes the pending
    /// value either way (resolved or not) so a stale/unsyncable remote position isn't retried
    /// forever. Call ONLY from the first-load branch of applying the timeline -- a fresh session,
    /// before the user has navigated -- never mid-session, which would yank the user off the
    /// article they're actively reading.
    ///
    /// Deliberately does NOT call `schedulePush`/`TimelineAnchorWriter.record`: this is the read
    /// side of the sync, and pushing the value straight back would let two open devices trade
    /// anchor writes forever. It updates `timelineAnchorIdentifier`/`timelineAnchorServerID`
    /// directly instead, so subsequent self-heal reanchoring still resolves to the right article
    /// without re-triggering a push. Shared by `ReaderAnchorController` (iOS) and `TimelineModel`
    /// (Mac) so this no-ping-pong guarantee lives in one place, not two copies that could drift.
    static func jumpToSyncedTimelinePosition(in articles: [ArticleSummary], settings: AppSettings) -> Int? {
        guard let articleID = settings.pendingRemoteReadingPosition else { return nil }
        settings.pendingRemoteReadingPosition = nil
        guard let index = articles.firstIndex(where: { $0.serverID == articleID }) else { return nil }
        settings.timelineAnchorIdentifier = articles[index].identifier
        settings.timelineAnchorServerID = articleID
        return index
    }
}
