import BackgroundTasks
import Foundation
import SwiftData

/// Best-effort periodic aggregation via `BGAppRefreshTask`. Registered once at launch,
/// scheduled at `AppSettings.backgroundInterval`, and re-scheduled after every run.
/// Pull-down on the reader remains the primary trigger; this path fails silently.
@MainActor
final class BackgroundRefreshManager {
    /// Must match `BGTaskSchedulerPermittedIdentifiers` in `Info-iOS.plist`.
    static let taskIdentifier = "de.fa-krug.Yana.background-refresh"

    /// A `BGProcessingTask` identifier (also in `BGTaskSchedulerPermittedIdentifiers`). Processing
    /// tasks get minutes of runtime instead of the ~30s an app-refresh task is granted, so an
    /// AI-heavy feed (e.g. Reddit with translation) can finish its AI pass before expiration.
    /// Without it the window expires mid-request, the run is cancelled, and `AIProcessor` drops
    /// every still-in-flight article — so those articles never get imported in the background.
    static let processingTaskIdentifier = "de.fa-krug.Yana.background-processing"

    /// iOS will not honour an earliest-begin sooner than a few minutes; clamp to a safe floor.
    static let minimumInterval: TimeInterval = 60

    private let container: ModelContainer
    private let intervalProvider: @MainActor () -> TimeInterval
    private let now: () -> Date

    /// Guards against the refresh and processing tasks both firing close together: the first to
    /// run does the aggregation; the other just re-arms. Each handler builds its own
    /// `AggregationService`, so that service's `isUpdating` flag can't coordinate the two — the
    /// guard has to live on the (main-actor) manager.
    private var isRunning = false

    init(
        container: ModelContainer,
        intervalProvider: @escaping @MainActor () -> TimeInterval = { AppSettings().backgroundInterval },
        now: @escaping () -> Date = { .now }
    ) {
        self.container = container
        self.intervalProvider = intervalProvider
        self.now = now
    }

    /// Pure: the earliest begin date for the next request. Clamps non-positive intervals
    /// to `minimumInterval` so a misconfigured setting never produces an invalid request.
    static func nextBeginDate(from reference: Date, interval: TimeInterval) -> Date {
        let clamped = interval > 0 ? interval : minimumInterval
        return reference.addingTimeInterval(clamped)
    }

    /// The work performed for one background run, isolated from `BGTask` so it can be
    /// unit-tested. Runs the aggregation, then posts a "new articles" notification when the
    /// user has opted in, the system authorized it, and the run imported at least one article.
    /// Errors are swallowed by the caller — a failed background run must never crash the app.
    @MainActor
    static func runRefresh(
        service: AggregationService,
        notifier: Notifying = NotificationService(),
        settings: AppSettings = AppSettings()
    ) async {
        let inserted = await service.updateAll()
        guard settings.notificationsEnabled, inserted > 0 else { return }
        let authorized = await notifier.isAuthorized()
        guard NewArticleNotification.shouldNotify(
            enabled: settings.notificationsEnabled,
            authorized: authorized,
            insertedCount: inserted
        ) else { return }
        await notifier.postNewArticles(count: inserted)
    }

    /// Register the launch handler. MUST be called before the app finishes launching
    /// (from the app delegate), exactly once per process.
    ///
    /// `BGTaskScheduler` invokes the launch handler on a background queue, so the closure
    /// must stay non-isolated and only hop onto the main actor to touch this `@MainActor`
    /// type. The `@Sendable` annotation is load-bearing: without it, the closure inherits
    /// this method's `@MainActor` isolation (the `launchHandler` parameter is not `@Sendable`,
    /// so isolation is inferred from the enclosing context), and the synthesized main-actor
    /// precondition traps (EXC_BREAKPOINT) the moment iOS runs the task off the main thread.
    func register() {
        registerHandler(for: Self.taskIdentifier)
        registerHandler(for: Self.processingTaskIdentifier)
    }

    /// Register one launch handler. Both the app-refresh and processing tasks run the same work;
    /// only their scheduling and the runtime the system grants differ.
    private func registerHandler(for identifier: String) {
        BGTaskScheduler.shared.register(
            forTaskWithIdentifier: identifier,
            using: nil
        ) { @Sendable task in
            // `BGTask` is non-Sendable, but iOS hands it to this handler exactly once and we
            // only ever touch it on the main actor below — so the hop is safe. The compiler
            // can't prove that across an escaping closure, hence `nonisolated(unsafe)`.
            nonisolated(unsafe) let task = task
            Task { @MainActor [weak self] in
                guard let self else {
                    task.setTaskCompleted(success: false)
                    return
                }
                self.handle(task: task)
            }
        }
    }

    /// Submit the next requests. Best-effort: submission failures are ignored (e.g. when running
    /// in the simulator or when the system declines). Both task kinds are re-armed every run:
    /// the app-refresh task keeps lightweight feeds current frequently, while the processing task
    /// is the long window that lets AI-heavy feeds finish their AI pass instead of being dropped.
    func schedule() {
        let begin = Self.nextBeginDate(from: now(), interval: intervalProvider())

        let refresh = BGAppRefreshTaskRequest(identifier: Self.taskIdentifier)
        refresh.earliestBeginDate = begin
        try? BGTaskScheduler.shared.submit(refresh)

        let processing = BGProcessingTaskRequest(identifier: Self.processingTaskIdentifier)
        processing.earliestBeginDate = begin
        // The run needs the network (feed fetch + AI calls); don't gate on power so updates can
        // still land through the day.
        processing.requiresNetworkConnectivity = true
        processing.requiresExternalPower = false
        try? BGTaskScheduler.shared.submit(processing)
    }

    /// Run one background refresh, then reschedule. Always completes the task and never
    /// throws out — a background failure must be silent (spec §6).
    func handle(task: BGTask) {
        // Re-arm immediately so the chain continues even if this run is cut short.
        schedule()

        // If the sibling task already kicked off a run, this one just re-arms and completes:
        // a second concurrent `updateAll()` on the same context would be wasted (or racy) work.
        guard !isRunning else {
            task.setTaskCompleted(success: true)
            return
        }
        isRunning = true

        let work = Task { @MainActor in
            defer { isRunning = false }
            let service = AggregationService(context: container.mainContext)
            await Self.runRefresh(service: service)
            task.setTaskCompleted(success: true)
        }

        // Set BEFORE the work can be pre-empted: if the system expires the task immediately,
        // the handler is already wired to cancel the run.
        task.expirationHandler = {
            work.cancel()
            task.setTaskCompleted(success: false)
        }
    }
}
