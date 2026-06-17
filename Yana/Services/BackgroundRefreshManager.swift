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

    /// iOS will not honour an earliest-begin sooner than a few minutes; clamp to a safe floor.
    static let minimumInterval: TimeInterval = 60

    private let container: ModelContainer
    private let intervalProvider: @MainActor () -> TimeInterval
    private let now: () -> Date

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
    /// type — touching `self` synchronously here would trip a main-queue executor
    /// precondition and trap (EXC_BREAKPOINT).
    func register() {
        BGTaskScheduler.shared.register(
            forTaskWithIdentifier: Self.taskIdentifier,
            using: nil
        ) { task in
            guard let refreshTask = task as? BGAppRefreshTask else {
                task.setTaskCompleted(success: false)
                return
            }
            Task { @MainActor [weak self] in
                guard let self else {
                    refreshTask.setTaskCompleted(success: false)
                    return
                }
                self.handle(task: refreshTask)
            }
        }
    }

    /// Submit the next refresh request. Best-effort: submission failures are ignored
    /// (e.g. when running in the simulator or when the system declines).
    func schedule() {
        let request = BGAppRefreshTaskRequest(identifier: Self.taskIdentifier)
        request.earliestBeginDate = Self.nextBeginDate(from: now(), interval: intervalProvider())
        try? BGTaskScheduler.shared.submit(request)
    }

    /// Run one background refresh, then reschedule. Always completes the task and never
    /// throws out — a background failure must be silent (spec §6).
    func handle(task: BGAppRefreshTask) {
        // Re-arm immediately so the chain continues even if this run is cut short.
        schedule()

        let work = Task { @MainActor in
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
