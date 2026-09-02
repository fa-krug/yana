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

/// One published outcome, plus the sequence number that makes its delivery independent of its
/// own value.
///
/// Views observe the *sequence*, never the outcome. `OperationOutcome` is `Equatable`, and
/// SwiftUI's `.onChange` only fires when the observed value actually changes -- so publishing the
/// bare outcome silently dropped every repeat. Reloading the same article twice produces a
/// byte-identical `.reloaded(articleServerID:feedName:)` both times, and the second delivery was
/// swallowed: no toast, and (the part that actually matters) no `reloadToken` bump, so the reader
/// kept rendering the pre-reload page after a reload the server had genuinely completed -- the
/// exact symptom this whole type exists to eliminate. Two Update All runs that both find zero new
/// articles, and two consecutive failures, had the same problem. The counter never repeats, so
/// every published outcome is delivered exactly once no matter what it contains.
struct OperationOutcomeEvent: Equatable, Sendable {
    /// Strictly increasing, starting at 1. Only its *change* is meaningful; the absolute value is
    /// not a count of anything a caller should reason about.
    let sequence: Int
    let outcome: OperationOutcome
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
    /// The most recent finished operation, wrapped in an `OperationOutcomeEvent`. Views observe
    /// `lastOutcomeEvent?.sequence` and then read `.outcome` -- see `OperationOutcomeEvent` for why
    /// keying on the outcome value itself drops identical consecutive outcomes on the floor.
    private(set) var lastOutcomeEvent: OperationOutcomeEvent?
    private var outcomeSequence = 0

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
    /// The spinner/percentage surface this monitor drives. Production always uses the app-wide
    /// `UpdateActivity.shared`; tests inject a throwaway instance so a monitor test cannot leave
    /// the shared in-flight counter or percentage perturbed for whatever runs next.
    private let activity: UpdateActivity

    init(pollInterval: Duration = .seconds(2), slowPollInterval: Duration = .seconds(5),
         youngPhase: Duration = .seconds(60), nudgeSlice: Duration = .milliseconds(250),
         activity: UpdateActivity = .shared) {
        self.pollInterval = pollInterval
        self.slowPollInterval = slowPollInterval
        self.youngPhase = youngPhase
        self.nudgeSlice = nudgeSlice
        self.activity = activity
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
        // Restores the spinner's begin()/end() balance that used to live in the trigger call
        // sites' `UpdateActivity.shared.restart { ... }` wrappers, removed in Task 10 once this
        // monitor became the source of truth for what's actually running. Pairing them here
        // instead means `isUpdating` reflects exactly what `track` is watching, regardless of
        // which call site triggered it.
        activity.begin()

        let task = Task { @MainActor in
            let outcome = await self.monitor(operation, settings: settings, container: container,
                                             client: client, observer: observer)
            self.inFlight[key] = nil
            self.visibleArticles[key] = nil
            self.activity.end()
            // Only clear the persisted record once an outcome was actually reached. `monitor`
            // returns `nil` solely on cancellation ("stop watching", not "the wait ended"), and
            // `TrackedOperation`'s own doc contract is that a record is removed only once a
            // terminal status has been observed and its follow-up applied -- clearing it on
            // cancellation too would defeat resume-after-relaunch, since a cancelled-at-launch
            // monitor (e.g. the app being killed mid-poll) must leave the record for `resume()`
            // to pick back up next launch.
            if let outcome {
                settings.trackedOperations.removeAll { $0.monitorKey == key }
                self.outcomeSequence += 1
                self.lastOutcomeEvent = OperationOutcomeEvent(sequence: self.outcomeSequence,
                                                              outcome: outcome)
            }
            self.isActive = !self.inFlight.isEmpty
            if !self.isActive {
                self.progressPercent = nil
                self.activity.setProgress(nil)
            }
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

        while !Task.isCancelled {
            let poll = await pollOnce(operation, client: client)
            switch poll {
            case .state(let percent, let terminal, let succeeded):
                publish(percent, observer: observer)
                if terminal {
                    guard succeeded else { return silentIfCancelled(.failed(operation.kind)) }
                    let outcome = await applyTerminalSuccess(operation, container: container,
                                                             client: client, settings: settings)
                    return silentIfCancelled(outcome)
                }
            case .gone:
                // The row was pruned out from under the poll -- whether that happened before this
                // device's first look or between two of its polls makes no difference to what can
                // be done about it. Anything fetchable is applied either way (a pruned job row
                // routinely means a *finished* job, so the content is usually there), but nothing
                // here says the work finished, so it is reported as unconfirmed and never as
                // success.
                _ = await applyTerminalSuccess(operation, container: container, client: client,
                                               settings: settings)
                return silentIfCancelled(.unconfirmed(operation.kind))
            case .permanentFailure:
                // .unauthorized, .decoding, and a well-formed .server error other than
                // "not_found" mean the row genuinely cannot be queried -- retrying will never
                // succeed. Ending
                // the wait here, rather than looping it forever, is what lets the record clear and
                // the UI report honestly that completion could not be confirmed.
                return silentIfCancelled(.unconfirmed(operation.kind))
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

    /// Swallows an outcome that was only reached because the user asked this device to stop
    /// watching. `monitor`'s loop head already treats cancellation as "no outcome," but a
    /// cancellation landing *inside* `applyTerminalSuccess` used to surface as a real result: the
    /// content `GET` throws `URLError.cancelled`, `applied` comes back false, and a reload the
    /// server had actually completed was reported as `.failed(.reloadArticle)` -- "Could not reload
    /// this article" for work that succeeded. A user-initiated stop must always be silent, so every
    /// return path in `monitor` funnels through this rather than only the loop head.
    private func silentIfCancelled(_ outcome: OperationOutcome) -> OperationOutcome? {
        Task.isCancelled ? nil : outcome
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
                // An auth rejection, an undecodable response, or a well-formed
                // (non-"not_found") server error all mean
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
        activity.setProgress(percent)
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

    /// The monitoring tasks currently in flight. Exists for tests, which must await a cancelled
    /// task's unwind before releasing `MockURLProtocol.lock` -- otherwise a still-unwinding poll
    /// can issue a request against the *next* test's global stub. Capture this before calling
    /// `stopWatching`, which clears the table.
    var inFlightTasks: [Task<Void, Never>] { Array(inFlight.values) }

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
        // `end()` for each cancelled task's `begin()` still arrives asynchronously once its own
        // `monitor` loop notices the cancellation and the `track` completion block runs -- but the
        // percentage should stop being shown immediately, not linger until that unwind completes.
        activity.setProgress(nil)
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
                    // Unpaired: there is no stream to open, and nothing this loop does can change
                    // that -- so it exits instead of waking every `reconnectDelay` forever, which
                    // is what every demo-mode session used to do for as long as the app stayed
                    // open. Clearing `eventTask` is what keeps the documented mid-session pairing
                    // working: `startEvents` refuses to start a second task while one exists, so
                    // without this the loop's exit would be permanent. A pairing that lands later
                    // calls `startEvents` again (`PairingSync.resetAndFullSync`, plus the scene's
                    // own `.active` handler in `YanaApp`), and this then starts a fresh task.
                    self.eventTask = nil
                    return
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
                        activity.setProgress(self.progressPercent)
                    }
                    if case let .run(payload) = event,
                       self.inFlight["run-\(payload.runId)"] != nil {
                        self.progressPercent = max(self.progressPercent ?? 0, payload.progress)
                        activity.setProgress(self.progressPercent)
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
    /// `private`: `UpdateAndSync` (the predecessor this type replaced, which waited ten seconds
    /// for a single SSE event and then fetched anyway and reported success regardless of what the
    /// server was actually doing) is gone as of Task 10, and `OperationMonitor.applyTerminalSuccess`
    /// is the only remaining caller, so there is no longer a second implementation to share this
    /// with. `settings` defaults to the standard `AppSettings()` (backed by `UserDefaults.standard`)
    /// but `applyTerminalSuccess` always passes its own isolated instance explicitly: without that,
    /// this method's inner `SyncEngine.sync()` call would silently fall back to `.standard` and
    /// read/write `syncCursor`/`imagePruneNeeded` on the real, shared defaults store instead of the
    /// caller's isolated one.
    private static func fetchAndApplyContent(
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
