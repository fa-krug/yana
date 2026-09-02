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
            settings.trackedOperations.removeAll { $0.monitorKey == key }
            if let outcome { self.lastOutcome = outcome }
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
            case .retryable:
                // A dropped packet, a proxy's 502, or being offline entirely. None of those are
                // the operation's outcome, so the wait continues and the record stays persisted.
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
        } catch {
            return .retryable
        }
    }

    private func publish(_ percent: Int, observer: ((Int?) -> Void)?) {
        progressPercent = percent
        observer?(percent)
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

    /// Filled in by the terminal follow-through task. Until then, nothing is fetched.
    private func applyTerminalSuccess(
        _ operation: TrackedOperation, container: ModelContainer, client: YanaAPIClient,
        settings: AppSettings
    ) async -> OperationOutcome {
        .unconfirmed(operation.kind)
    }
}

/// A non-owning box so a monitored reload cannot keep the reader's `Article` alive past its
/// context.
private final class WeakArticle {
    weak var article: Article?
    init(_ article: Article) { self.article = article }
}
