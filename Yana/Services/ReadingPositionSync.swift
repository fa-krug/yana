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

    /// The article id of the most recent user-driven navigation on this device whose push the
    /// server has not acknowledged yet. Set the instant the (debounced) push is *scheduled* --
    /// i.e. the moment the user navigates, not when the PATCH goes out -- and cleared only once a
    /// PATCH for that same id comes back successfully. While it is set, this device knows for a
    /// fact that whatever the server would tell us about the reading position is older than where
    /// the user just navigated to, so `applyRemoteUpdate` drops remote updates outright.
    ///
    /// This covers two windows the plain `readingPositionUpdatedAt` guard cannot:
    ///
    /// - **The debounce window.** Jumping to an article from the list (or a swipe/sidebar click)
    ///   writes the local anchor immediately but only PATCHes ~2s later. A sync pass landing in
    ///   between pulls `GET /api/v1/reading-position`, which still holds the *previous* position,
    ///   and a live `readingPosition` SSE event can carry one just as stale -- either would have
    ///   been stashed as a "remote" update and, since live updates now apply mid-session, would
    ///   yank the reader straight back off the article the user just opened.
    /// - **The round trip itself.** The server fans the live SSE event out to every open
    ///   connection on the account *including the pushing device's own*, over a connection
    ///   separate from the PATCH, so a device's own echo can outrace its own PATCH response --
    ///   before `readingPositionUpdatedAt` has been stamped.
    ///
    /// A failed push deliberately leaves this set: the write is queued in
    /// `AppSettings.pendingReadingPositionPush` and still unacknowledged, so the local position
    /// still outranks the server's. It is in-memory only, so a relaunch starts from a clean slate
    /// (where the first sync's `flushPending` runs before the pull anyway) rather than letting a
    /// permanently-failing push suppress inbound positions forever.
    private var unacknowledgedLocalPosition: Int?

    /// Whether a user-driven navigation on this device is still waiting on its server ack.
    var hasUnacknowledgedLocalPosition: Bool { unacknowledgedLocalPosition != nil }

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
        // Marked unacknowledged here rather than in `push`, so the debounce window is covered too
        // -- see `unacknowledgedLocalPosition`.
        unacknowledgedLocalPosition = articleServerID
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
        // Also set here (not only in `schedulePush`) so a direct push -- `flushPending`'s retry,
        // or a test -- brackets its own round trip the same way.
        unacknowledgedLocalPosition = articleServerID
        do {
            let updatedAt = try await ArticleActions(client: client).setReadingPosition(articleServerID: articleServerID)
            settings.pendingReadingPositionPush = nil
            if let updatedAt { settings.readingPositionUpdatedAt = updatedAt }
            // Only when it's still the newest local write: a navigation made while this PATCH was
            // in flight has already replaced it and is itself still unacknowledged.
            if unacknowledgedLocalPosition == articleServerID { unacknowledgedLocalPosition = nil }
        } catch {
            settings.pendingReadingPositionPush = articleServerID
        }
    }

    /// Retries a not-yet-acknowledged position push. Called by `SyncEngine` alongside
    /// `PendingWriteQueue.flush`, before the normal pull. A no-op when nothing is queued; a
    /// failure here leaves the entry queued for the next sync pass.
    static func flushPending(client: YanaAPIClient, settings: AppSettings) async {
        guard let articleServerID = settings.pendingReadingPositionPush else { return }
        // `push` re-queues the same id on failure, which is exactly "leave it queued" here.
        await shared.push(articleServerID: articleServerID, client: client, settings: settings)
    }

    /// Stashes a remote position update in `AppSettings.pendingRemoteReadingPosition` for the
    /// reader to apply (see its doc comment) -- at the next fresh session's first load, or straight
    /// away when the app is already open and the target article has synced down. Everything that
    /// keeps such an update from yanking the user off an article they're reading themselves lives
    /// here, in the guards below, rather than in the reader. Last-writer-wins by
    /// `updatedAt`: an update no newer than what this device already knows about is dropped, so
    /// this can never regress a local push still in flight or re-apply a position this device
    /// itself just pushed. The single source of truth for that rule -- shared by `SyncEngine`'s
    /// periodic `GET /api/v1/reading-position` pull and `ReadingPositionLiveSync`'s live SSE push,
    /// so a remote update is applied identically regardless of which route delivered it.
    ///
    /// Two further guards cover what comparing `updatedAt` alone cannot:
    ///
    /// - A user-driven navigation on this device that the server hasn't acknowledged yet always
    ///   wins (see `unacknowledgedLocalPosition`) -- the reader must not be dragged back off the
    ///   article the user just opened by a position the server had already superseded locally.
    ///   Such an update is dropped *without* stamping `readingPositionUpdatedAt`, so a genuinely
    ///   newer remote position isn't swallowed: the next pull re-delivers it, and by then the
    ///   local push has either landed (its own newer `updatedAt` legitimately outranks it) or the
    ///   user has navigated again anyway.
    /// - An update pointing at the article this device is already anchored on changes nothing, so
    ///   it is stamped and dropped rather than stashed. That is the resting state of every
    ///   self-echo the guard above no longer covers (the push has resolved and the user hasn't
    ///   moved on), including one whose event carries a marginally later `updatedAt` than the
    ///   PATCH response it echoes.
    static func applyRemoteUpdate(articleId: Int, updatedAt: Date, settings: AppSettings) {
        if let known = settings.readingPositionUpdatedAt, known >= updatedAt { return }
        guard !shared.hasUnacknowledgedLocalPosition else { return }
        settings.readingPositionUpdatedAt = updatedAt
        guard articleId != settings.timelineAnchorServerID else { return }
        settings.pendingRemoteReadingPosition = articleId
    }

    /// Test seam: drops the in-memory unacknowledged-local-write state, which otherwise outlives a
    /// single test through `shared`. Production code never needs this -- the state clears itself
    /// when a push is acknowledged, and is in-memory only.
    func resetLocalWriteStateForTesting() {
        debounceTask?.cancel()
        debounceTask = nil
        unacknowledgedLocalPosition = nil
    }
}
