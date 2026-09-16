import Foundation
import SwiftData
#if os(macOS)
import AppKit
#else
import BackgroundTasks
#endif

/// Best-effort periodic aggregation via `BGAppRefreshTask`. Registered once at launch,
/// scheduled at `AppSettings.updateInterval`, and re-scheduled after every run.
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
    private let secondsProvider: @MainActor () -> TimeInterval?   // nil = .off (no scheduling)
    private let now: () -> Date
    private let onScheduleAttempt: @MainActor () -> Void          // test seam; default no-op

    #if os(macOS)
    /// The Mac has no `BGTaskScheduler`, so periodic refresh runs through
    /// `NSBackgroundActivityScheduler` instead (paired with a refresh-on-launch and on-focus via
    /// `runNow()`). Held so `schedule()` can re-arm it at a new interval, and invalidate it when
    /// the interval is switched to `.off`.
    ///
    /// This replaced a repeating `Task.sleep` loop inherited from Mac Catalyst, where the
    /// scheduler was unavailable. The scheduler is not merely the tidier spelling: it gets
    /// system-managed tolerance (so several apps' periodic work coalesces into one wake), it does
    /// not park a suspended task on the main actor, and it re-fires after the machine wakes from
    /// sleep — a sleeping `Task.sleep` does not, so a laptop closed for four hours resumed
    /// mid-sleep and then waited out the whole remaining interval before refreshing.
    private var macRefreshActivity: NSBackgroundActivityScheduler?

    /// Unique per process — `NSBackgroundActivityScheduler` keys its persisted scheduling state on
    /// this, so two schedulers sharing an identifier would fight over one slot.
    static let macActivityIdentifier = "de.fa-krug.Yana.mac-background-refresh"
    #endif

    #if !os(macOS)
    /// Guards against the refresh and processing tasks both firing close together: the first to
    /// run does the sync; the other just re-arms. Each handler builds its own `SyncEngine`, so
    /// there's no shared state on that object to coordinate the two — the guard has to live on
    /// the (main-actor) manager. iOS-only: the Mac has one scheduler, so nothing to serialize.
    private var isRunning = false
    #endif

    init(
        container: ModelContainer,
        secondsProvider: @escaping @MainActor () -> TimeInterval? = { AppSettings().updateInterval.seconds },
        now: @escaping () -> Date = { .now },
        onScheduleAttempt: @escaping @MainActor () -> Void = {}
    ) {
        self.container = container
        self.secondsProvider = secondsProvider
        self.now = now
        self.onScheduleAttempt = onScheduleAttempt
    }

    /// Pure: the earliest begin date for the next request. Clamps non-positive intervals
    /// to `minimumInterval` so a misconfigured setting never produces an invalid request.
    static func nextBeginDate(from reference: Date, interval: TimeInterval) -> Date {
        let clamped = interval > 0 ? interval : minimumInterval
        return reference.addingTimeInterval(clamped)
    }

    /// The work performed for one background run, isolated from `BGTask` so it can be
    /// unit-tested. Runs the sync, then posts a "new articles" notification when the
    /// user has opted in, the system authorized it, and the run pulled down at least one new
    /// article summary. A failed sync (e.g. offline, expired pairing) is swallowed here — a
    /// failed background run must never crash the app.
    ///
    /// `postsNotification` lets a caller suppress the notification even though every other
    /// condition is met — used on the Mac to stay silent while the user is looking directly at
    /// the window (audit U4): a "new articles arrived" system notification is pointless noise
    /// when the app is already frontmost.
    @MainActor
    static func runRefresh(
        engine: SyncEngine,
        notifier: Notifying = NotificationService(),
        settings: AppSettings = AppSettings(),
        postsNotification: Bool = true
    ) async {
        guard let result = try? await engine.sync() else { return }
        let inserted = result.newCount
        guard postsNotification, settings.notificationsEnabled, inserted > 0 else { return }
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
        guard secondsProvider() != nil else { return }
        #if os(macOS)
        // No launch-time registration on the Mac: `NSBackgroundActivityScheduler` carries its own
        // block and needs no pre-launch handler. Scheduling is handled by `schedule()` (see
        // `scheduleMac`).
        #else
        registerHandler(for: Self.taskIdentifier)
        registerHandler(for: Self.processingTaskIdentifier)
        #endif
    }

    /// Run one refresh immediately. Used on the Mac at launch (and window focus) since the desktop
    /// model is "the app tends to stay open" rather than woken by the system. Best-effort; silent.
    func runNow() {
        guard secondsProvider() != nil else { return }
        Task { @MainActor in
            guard let client = AuthenticatedClient.current() else { return }   // not paired yet
            let engine = SyncEngine(container: container, client: client)
            await Self.runRefresh(
                engine: engine,
                postsNotification: !PlatformApp.isActive
            )
        }
    }

    #if !os(macOS)
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
    #endif

    /// Submit the next requests. Best-effort: submission failures are ignored (e.g. when running
    /// in the simulator or when the system declines). Both task kinds are re-armed every run:
    /// the app-refresh task keeps lightweight feeds current frequently, while the processing task
    /// is the long window that lets AI-heavy feeds finish their AI pass instead of being dropped.
    func schedule() {
        guard let seconds = secondsProvider() else {
            #if os(macOS)
            // Interval switched to .off while a scheduler is armed: kill it (audit U4).
            macRefreshActivity?.invalidate()
            macRefreshActivity = nil
            #endif
            return
        }
        onScheduleAttempt()
        #if os(macOS)
        scheduleMac(seconds: seconds)
        #else
        let begin = Self.nextBeginDate(from: now(), interval: seconds)

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
        #endif
    }

    #if os(macOS)
    /// Arm (or re-arm) the repeating `NSBackgroundActivityScheduler` that runs `runRefresh` at the
    /// configured interval. Re-armed on every call (invalidate + recreate) so a change to
    /// `AppSettings.updateInterval` takes effect immediately (audit U4); the desktop model keeps
    /// the app open, and launch/focus additionally call `runNow()`.
    ///
    /// Three things here are load-bearing and easy to get wrong:
    ///
    /// - **`repeats = true`.** Without it the activity does not fire *at all* — not even once.
    /// - **The block runs off the main thread**, so it hops onto the main actor before touching
    ///   anything on this `@MainActor` type.
    /// - **`completion` must be called exactly once.** Calling it twice, or not at all, stalls the
    ///   scheduler permanently — it will never fire again for this identifier. The `defer` at the
    ///   top of the hop is what guarantees that across every early return (not paired, cancelled)
    ///   and any error thrown inside.
    private func scheduleMac(seconds: TimeInterval) {
        macRefreshActivity?.invalidate()
        let interval = max(seconds, Self.minimumInterval)
        let activity = NSBackgroundActivityScheduler(identifier: Self.macActivityIdentifier)
        activity.repeats = true
        activity.interval = interval
        // Let the system slide the wake by up to 20% to coalesce it with other scheduled work —
        // periodic feed refresh has no deadline, and this is the whole point of using the
        // scheduler rather than a timer.
        activity.tolerance = interval * 0.2
        activity.qualityOfService = .utility
        activity.schedule { [weak self] completion in
            // `completion` is `@Sendable`, so it crosses the hop below as-is. It is called
            // exactly once, from the `defer` — see the note above about stalling the scheduler.
            Task { @MainActor in
                defer { completion(.finished) }
                guard let self else { return }
                guard let client = AuthenticatedClient.current() else { return }   // not paired yet
                let engine = SyncEngine(container: self.container, client: client)
                await Self.runRefresh(
                    engine: engine,
                    postsNotification: !PlatformApp.isActive
                )
            }
        }
        macRefreshActivity = activity
    }

    /// Test seam: whether a repeating scheduler is currently armed. `schedule()` arms one and the
    /// `.off` path tears it down, which is the behaviour `BackgroundRefreshManagerTests` pins.
    var hasArmedMacActivity: Bool { macRefreshActivity != nil }
    #endif

    #if !os(macOS)
    /// Run one background refresh, then reschedule. Always completes the task and never
    /// throws out — a background failure must be silent (spec §6).
    func handle(task: BGTask) {
        // Re-arm immediately so the chain continues even if this run is cut short.
        schedule()

        // If the sibling task already kicked off a run, this one just re-arms and completes:
        // a second concurrent `sync()` against the same container would be wasted (or racy) work.
        guard !isRunning else {
            task.setTaskCompleted(success: true)
            return
        }
        isRunning = true

        let work = Task { @MainActor in
            defer { isRunning = false }
            guard let client = AuthenticatedClient.current() else {
                // Not paired yet — nothing to do, not an error.
                task.setTaskCompleted(success: true)
                return
            }
            let engine = SyncEngine(container: container, client: client)
            await Self.runRefresh(engine: engine)
            task.setTaskCompleted(success: true)
        }

        // Set BEFORE the work can be pre-empted: if the system expires the task immediately,
        // the handler is already wired to cancel the run.
        task.expirationHandler = {
            work.cancel()
            task.setTaskCompleted(success: false)
        }
    }
    #endif
}
