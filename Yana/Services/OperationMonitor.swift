import Foundation
import SwiftData

/// What a monitored operation turned out to be. Published by `OperationMonitor` rather than
/// returned to the caller, because by the time the truth arrives the view that triggered the work
/// may be gone, and so may the whole process.
enum OperationOutcome: Equatable, Sendable {
    case reloaded(articleServerID: Int, feedName: String?)
    case updated(newCount: Int)
    case failed(TrackedOperation.Kind)
    /// The server's answer could not be obtained -- its job row was pruned before this device
    /// looked. Whatever content could be fetched has been applied, but nothing here confirms the
    /// work finished, so this must never be reported as success.
    case unconfirmed(TrackedOperation.Kind)
}

/// Waits for server-side operations to actually finish, and reports what really happened.
///
/// The durable `jobs`/`runs` rows are the source of truth: this polls `GET /api/v1/jobs/:id` or
/// `GET /api/v1/runs/:id` until the row reports a terminal status, and shows the `progress`
/// percentage those routes return. **No timeout is ever treated as success.** The predecessor of
/// this type waited ten seconds for a single SSE event and then fetched the article anyway and
/// reported "Reloaded", which meant every reload slower than ten seconds -- the normal case, since
/// the server's worker claims pending jobs on a two-second poll and then refetches and re-extracts
/// the page under a 300s budget -- announced success while displaying the pre-reload content.
///
/// A transport failure retries rather than ending the wait, and the operation stays persisted in
/// `AppSettings.trackedOperations` throughout, so a relaunch resumes the same wait through the
/// same code path (`resume()`) rather than through a second recovery mechanism.
@MainActor
@Observable
final class OperationMonitor {
    static let shared = OperationMonitor()

    /// The newest percentage across the operations in flight, 0-100 exactly as the wire carries
    /// it, `nil` when nothing is running. With more than one operation this is whichever reported
    /// most recently.
    private(set) var progressPercent: Int?
    private(set) var isActive: Bool = false
    /// The most recent finished operation. Views observe this to show a toast.
    private(set) var lastOutcome: OperationOutcome?

    /// Keyed by `TrackedOperation.monitorKey`, NOT `id`: `id` is a job id for `.reloadArticle` and
    /// a run id for `.updateAll`, drawn from two different server-side tables whose ids collide
    /// freely. Keying by `id` alone would let an in-flight reload silently refuse to also track a
    /// same-numbered Update All run (`track` treats an existing key as "already watching this").
    private var inFlight: [String: Task<Void, Never>] = [:]
    /// The reader's already-registered `Article` object for a reload, when there is one. Not part
    /// of `TrackedOperation` because it cannot be persisted; absent after a relaunch, which is
    /// fine, since a freshly launched reader fetches the row after the write anyway. Keyed by
    /// `monitorKey` for the same reason as `inFlight`.
    private var visibleArticles: [String: WeakArticle] = [:]

    private let pollInterval: Duration
    private let slowPollInterval: Duration
    private let youngPhase: Duration
    private let nudgeSlice: Duration

    init(pollInterval: Duration = .seconds(2), slowPollInterval: Duration = .seconds(5),
         youngPhase: Duration = .seconds(60), nudgeSlice: Duration = .milliseconds(250)) {
        self.pollInterval = pollInterval
        self.slowPollInterval = slowPollInterval
        self.youngPhase = youngPhase
        self.nudgeSlice = nudgeSlice
    }

    /// Begins (or resumes) monitoring one operation. The caller is expected to have persisted it
    /// into `settings.trackedOperations` already, so a crash between the POST ack and this call
    /// still leaves a record for `resume()` to find.
    ///
    /// `observer` exists for tests, which need to see every published percentage rather than only
    /// the last one; production passes nothing.
    @discardableResult
    func track(
        _ operation: TrackedOperation, settings: AppSettings, container: ModelContainer,
        client: YanaAPIClient, visibleArticle: Article? = nil,
        observer: ((Int?) -> Void)? = nil
    ) -> Task<Void, Never> {
        let key = operation.monitorKey
        if let existing = inFlight[key] { return existing }
        if let visibleArticle { visibleArticles[key] = WeakArticle(visibleArticle) }
        isActive = true

        let task = Task { @MainActor in
            let outcome = await self.monitor(operation, settings: settings, container: container,
                                             client: client, observer: observer)
            self.inFlight[key] = nil
            self.visibleArticles[key] = nil
            // Only clear the persisted record once an outcome was actually reached. `monitor`
            // returns `nil` solely on cancellation ("stop watching", not "the wait ended"), and
            // `TrackedOperation`'s own doc contract is that a record is removed only once a
            // terminal status has been observed and its follow-up applied -- clearing it on
            // cancellation too would defeat resume-after-relaunch, since a cancelled-at-launch
            // monitor (e.g. the app being killed mid-poll) must leave the record for `resume()`
            // to pick back up next launch.
            if let outcome {
                settings.trackedOperations.removeAll { $0.monitorKey == key }
                self.lastOutcome = outcome
            }
            self.isActive = !self.inFlight.isEmpty
            if !self.isActive { self.progressPercent = nil }
        }
        inFlight[key] = task
        return task
    }

    /// Polls until the row reports a terminal status, then hands off to the follow-through.
    /// Returns `nil` only when the task itself was cancelled, which is "stop watching", not an
    /// outcome to report.
    private func monitor(
        _ operation: TrackedOperation, settings: AppSettings, container: ModelContainer,
        client: YanaAPIClient, observer: ((Int?) -> Void)?
    ) async -> OperationOutcome? {
        let startedMonitoringAt = ContinuousClock.now
        var sawTheRowAlive = false

        while !Task.isCancelled {
            let poll = await pollOnce(operation, client: client)
            switch poll {
            case .state(let percent, let terminal, let succeeded):
                sawTheRowAlive = true
                publish(percent, observer: observer)
                if terminal {
                    guard succeeded else { return .failed(operation.kind) }
                    return await applyTerminalSuccess(operation, container: container,
                                                      client: client, settings: settings)
                }
            case .gone:
                // The row was pruned out from under the poll. Anything fetchable is applied, but
                // nothing here says the work finished, so it is reported as unconfirmed.
                guard sawTheRowAlive else { return .unconfirmed(operation.kind) }
                _ = await applyTerminalSuccess(operation, container: container, client: client,
                                               settings: settings)
                return .unconfirmed(operation.kind)
            case .permanentFailure:
                // .unauthorized, .decoding, and a well-formed .server error other than
                // "not_found" mean the row genuinely cannot be queried -- retrying will never
                // succeed (mirrors UpdateAndSync.waitForRunToFinish's identical bail-out). Ending
                // the wait here, rather than looping it forever, is what lets the record clear and
                // the UI report honestly that completion could not be confirmed.
                return .unconfirmed(operation.kind)
            case .retryable:
                // A dropped packet, a proxy's 502, or being offline entirely -- unlike the
                // permanent class above, retrying CAN eventually succeed here, so the wait
                // continues and the record stays persisted. This is deliberate: it is what lets an
                // offline device resume the wait later instead of losing it, with the server's own
                // 300s per-job budget as the real bound rather than any client-side timeout.
                break
            }

            let interval = ContinuousClock.now - startedMonitoringAt < youngPhase
                ? pollInterval : slowPollInterval
            await sleep(interval)
        }
        return nil
    }

    private enum PollResult {
        case state(percent: Int, terminal: Bool, succeeded: Bool)
        case gone
        /// `.unauthorized`, `.decoding`, or a well-formed `.server` error whose code is not
        /// `"not_found"` -- the row cannot be queried and never will be, no matter how many more
        /// times this polls.
        case permanentFailure
        /// `.transport` or `.unexpectedStatus` -- a dropped packet, a proxy blip, or being
        /// offline. Worth another attempt.
        case retryable
    }

    private func pollOnce(_ operation: TrackedOperation, client: YanaAPIClient) async -> PollResult {
        do {
            switch operation.kind {
            case .reloadArticle:
                let job: JobStatusResponse = try await client.get("/api/v1/jobs/\(operation.id)")
                return .state(percent: job.progress, terminal: job.isTerminal,
                              succeeded: job.didSucceed)
            case .updateAll:
                let run: RunStatusResponse = try await client.get("/api/v1/runs/\(operation.id)")
                return .state(percent: run.progress, terminal: run.isTerminal,
                              succeeded: run.didSucceed)
            }
        } catch YanaAPIClientError.server(let error) where error.code == "not_found" {
            return .gone
        } catch YanaAPIClientError.unexpectedStatus(404) {
            return .gone
        } catch let error as YanaAPIClientError {
            switch error {
            case .unauthorized, .decoding, .server:
                // Same reasoning as UpdateAndSync.waitForRunToFinish: an auth rejection, an
                // undecodable response, or a well-formed (non-"not_found") server error all mean
                // this row genuinely cannot be queried, as opposed to a transient network blip.
                return .permanentFailure
            case .transport, .unexpectedStatus:
                return .retryable
            }
        } catch {
            return .retryable
        }
    }

    private func publish(_ percent: Int, observer: ((Int?) -> Void)?) {
        progressPercent = percent
        observer?(percent)
    }

    /// Picks monitoring back up for everything persisted, whether this session triggered it or a
    /// previous one did. Called at launch and whenever the app returns to the foreground; the
    /// per-operation guard in `track` (keyed the same way, by `monitorKey`) makes repeat calls
    /// free, so callers never have to reason about whether monitoring is already running.
    ///
    /// Returns the tasks it started, for tests. Production ignores the result.
    @discardableResult
    func resume(
        settings: AppSettings, container: ModelContainer,
        clientProvider: (AppSettings) -> YanaAPIClient? = { AuthenticatedClient.current(settings: $0) }
    ) -> [Task<Void, Never>] {
        guard let client = clientProvider(settings) else { return [] }
        return settings.trackedOperations.compactMap { operation in
            // Keyed by `monitorKey`, NOT `id`: `id` alone collides across the job/run id spaces
            // (see the `inFlight` doc comment above), and `track` itself already treats an
            // existing `monitorKey` entry as "already watching this" -- checking here too avoids
            // constructing a `Task` (via `track`) for an operation that would just be handed back
            // its own already-running one, so `resume`'s return value stays an accurate "what did
            // I just start" for tests to assert on.
            guard inFlight[operation.monitorKey] == nil else { return nil }
            return track(operation, settings: settings, container: container, client: client)
        }
    }

    /// Stop watching on this device, without asking the server to stop working. The persisted
    /// records go with it: the user asked for the spinner to end, and whatever the server produces
    /// still arrives through the next ordinary sync.
    func stopWatching(settings: AppSettings) {
        for task in inFlight.values { task.cancel() }
        inFlight.removeAll()
        visibleArticles.removeAll()
        settings.trackedOperations = []
        isActive = false
        progressPercent = nil
    }

    private var eventTask: Task<Void, Never>?

    /// Subscribes to `GET /api/v1/jobs/events` for as long as the app is foregrounded, purely to
    /// learn a percentage sooner than the next poll would. **It never decides an outcome and is
    /// never required for correctness**: a missed or duplicated event costs nothing, because the
    /// poll loop in `monitor(_:settings:container:client:observer:)` is what actually ends the
    /// wait. Applying an event clamps to `max(existing, incoming)` rather than assigning outright,
    /// so a stale or out-of-order event can only move `progressPercent` forward, never backward --
    /// a percentage regressing on screen reads as a bug even though nothing here was actually
    /// wrong. Started before any operation is triggered (from the scene `.task`, alongside
    /// `resume`), so a job that finishes in the moment between a POST and its first poll cannot
    /// slip through a connect gap.
    func startEvents(
        settings: AppSettings,
        clientProvider: @escaping @MainActor @Sendable (AppSettings) -> YanaAPIClient? = {
            AuthenticatedClient.current(settings: $0)
        },
        reconnectDelay: Duration = .seconds(5)
    ) {
        guard eventTask == nil else { return }
        eventTask = Task { @MainActor [weak self] in
            while !Task.isCancelled {
                // Bound once per (re)connect attempt, not once per event. Only relevant in tests,
                // which construct throwaway `OperationMonitor` instances (production only ever uses
                // `.shared`, which never deallocates): a stream that closes having delivered no
                // events at all would otherwise never reach a self-liveness check and keep
                // reconnecting forever on the captured `clientProvider`/`settings`, with nothing
                // left around that a later event could even update -- exactly the kind of leaked
                // loop that can reopen connections during a later, unrelated test.
                guard let self else { return }
                guard let client = clientProvider(settings) else {
                    try? await Task.sleep(for: reconnectDelay)
                    continue
                }
                var iterator = JobEventsClient(client: client).events().makeAsyncIterator()
                while let event = try? await iterator.next() {
                    // Matches `ReadingPositionLiveSync`'s shape: without this, an event already
                    // buffered when `stopEvents()` fires (app backgrounded) could still land a
                    // `progressPercent` write after the task was told to stop.
                    guard !Task.isCancelled else { return }
                    // Composite-keyed exactly like `inFlight` itself, for the same reason: a job
                    // id and a run id are drawn from different server-side tables and collide
                    // freely, so indexing by the bare numeric id here would attribute a run's
                    // percentage to a same-numbered in-flight job (or vice versa).
                    if case let .job(payload) = event,
                       self.inFlight["job-\(payload.jobId)"] != nil {
                        self.progressPercent = max(self.progressPercent ?? 0, Int(payload.progress))
                    }
                    if case let .run(payload) = event,
                       self.inFlight["run-\(payload.runId)"] != nil {
                        self.progressPercent = max(self.progressPercent ?? 0, payload.progress)
                    }
                }
                guard !Task.isCancelled else { return }
                try? await Task.sleep(for: reconnectDelay)
            }
        }
    }

    func stopEvents() {
        eventTask?.cancel()
        eventTask = nil
    }

    /// Sleeps in slices so a live SSE event (Task 9) can shorten the wait without any continuation
    /// bookkeeping. The cost is at most one slice of added latency.
    private func sleep(_ total: Duration) async {
        var remaining = total
        while remaining > .zero, !Task.isCancelled {
            let slice = remaining < nudgeSlice ? remaining : nudgeSlice
            try? await Task.sleep(for: slice)
            remaining -= slice
        }
    }

    /// The work the server just finished, pulled down. For a reload this deliberately does NOT go
    /// through `SyncEngine`'s generic `hasContent`-gated backfill: that backfill sets
    /// `hasContent = true` and nothing ever resets it, so a fetch racing the poll would
    /// permanently block any later retry of this exact article.
    private func applyTerminalSuccess(
        _ operation: TrackedOperation, container: ModelContainer, client: YanaAPIClient,
        settings: AppSettings
    ) async -> OperationOutcome {
        switch operation.kind {
        case .reloadArticle(let articleServerID):
            let visible = visibleArticles[operation.monitorKey]?.article
            let applied = await Self.fetchAndApplyContent(
                articleServerID: articleServerID, container: container, client: client,
                visibleArticle: visible, settings: settings
            )
            guard applied else { return .failed(operation.kind) }
            // `visible` is only present when the reader was actually holding this article when
            // the operation started -- absent after a relaunch resumes a still-in-flight
            // operation, since there is nothing to have held onto across the process restart. In
            // that case the feed name is resolved from the store instead, so a resumed reload
            // still reports the feed it belongs to rather than `nil` (which would otherwise render
            // downstream as "No new articles." for a reload that in fact succeeded).
            let feedName: String?
            if let visible {
                feedName = visible.feed?.name
            } else {
                let writer = SyncWriter(modelContainer: container)
                feedName = await OffMainActor.run { await writer.feedName(serverID: articleServerID) }
            }
            return .reloaded(articleServerID: articleServerID, feedName: feedName)
        case .updateAll:
            let engine = SyncEngine(container: container, client: client, settings: settings)
            let result = (try? await engine.sync())
                ?? SyncResult(newCount: 0, updatedCount: 0, removedCount: 0)
            return .updated(newCount: result.newCount)
        }
    }

    /// Re-fetches and applies one article's content directly, bypassing `SyncEngine`'s generic
    /// `hasContent`-gated backfill entirely (an earlier version of this code went through that
    /// backfill, resetting `hasContent = false` first, and that is actively wrong: a premature
    /// backfill fetch racing the poll sets `hasContent = true` and permanently blocks any later
    /// retry, since nothing else ever resets it).
    /// `visibleArticle`, if given, is the `Article` instance a reader is currently holding and
    /// rendering for `articleServerID` -- pass it so its in-memory fields are updated directly on
    /// its own `ModelContext` rather than only through `SyncWriter`'s separate `@ModelActor`
    /// context. Without this, the write lands in the store but the already-registered `Article`
    /// object the reader observes keeps its stale, pre-reload field values (a plain `fetch` does
    /// not refresh already-registered objects' attributes from a sibling context's save), so the
    /// reader silently keeps showing the old content even though the reload succeeded.
    /// Not `private`: `UpdateAndSync.pollForReloadedContent` (still called by `ReaderActions`
    /// until Task 10 rewires those call sites onto `OperationMonitor` directly) delegates to this
    /// same implementation rather than keeping a second copy. `settings` defaults to the standard
    /// `AppSettings()` (backed by `UserDefaults.standard`) so `UpdateAndSync`'s existing callers,
    /// which have no `settings` of their own to pass, are unaffected -- production always resolves
    /// to that same store either way. A caller that *does* have an isolated `AppSettings` (this
    /// type's own `applyTerminalSuccess`, and any test) must pass it explicitly: without this, the
    /// inner `SyncEngine.sync()` call below would silently fall back to `.standard` and read/write
    /// `syncCursor`/`imagePruneNeeded` on the real, shared defaults store instead of the caller's
    /// isolated one.
    static func fetchAndApplyContent(
        articleServerID: Int, container: ModelContainer, client: YanaAPIClient,
        visibleArticle: Article?, settings: AppSettings = AppSettings()
    ) async -> Bool {
        guard let document: WireDocument = try? await client.get(
            "/api/v1/articles/\(articleServerID)/content"
        ) else { return false }
        // Update the reader's already-registered object directly, on its own context, so the
        // visible page reflects the new content immediately -- see this method's doc comment for
        // why `SyncWriter`'s write alone isn't enough.
        if let visibleArticle, visibleArticle.serverID == articleServerID {
            // Same summary carry-over rule `SyncWriter.applyContent` applies below -- a locally
            // generated summary is body content, so a reload must not wipe it. Both write paths need
            // it, or the visible object and the stored row would disagree about the summary.
            visibleArticle.blocks = Block.preservingSummary(from: visibleArticle.blocks,
                                                            in: document.blocks)
            visibleArticle.hasContent = true
            try? visibleArticle.modelContext?.save()
        }
        // `SyncWriter` is a `@ModelActor` -- per this codebase's rule, every call into one from a
        // `@MainActor` context must be hopped off-main via `OffMainActor.run`, or the write runs
        // inline on the calling (main) thread.
        let writer = SyncWriter(modelContainer: container)
        let applied = await OffMainActor.run {
            await writer.applyContent(articleServerID: articleServerID, document: document)
        }
        guard applied else { return false }

        // The reload can also change the article's title -- `yana-server`'s `handleReloadJob`
        // re-derives it from the refetched source and writes `articles.name` (e.g. AI title
        // translation, or the source correcting its own headline), but `/articles/:id/content`
        // carries only the block body, never the title. A normal sync pass picks that change up
        // through `/articles/sync`'s `updated` list (the reload also bumps `updatedAt`). Doing
        // this *after* the content is already applied, not during the poll, is what makes it
        // safe: the premature-backfill race this method's doc comment warns about only exists
        // when a generic sync races the *content* fetch before it's confirmed done -- by this
        // point this article's `hasContent` is already correctly `true`, so `backfillMissingContent`
        // has nothing to do for it.
        let engine = SyncEngine(container: container, client: client, settings: settings)
        _ = try? await engine.sync()

        if let visibleArticle, visibleArticle.serverID == articleServerID {
            let freshTitle = await OffMainActor.run { await writer.articleTitle(serverID: articleServerID) }
            if let freshTitle, freshTitle != visibleArticle.title {
                visibleArticle.title = freshTitle
                try? visibleArticle.modelContext?.save()
            }
        }
        return true
    }
}

/// A non-owning box so a monitored reload cannot keep the reader's `Article` alive past its
/// context.
private final class WeakArticle {
    weak var article: Article?
    init(_ article: Article) { self.article = article }
}
