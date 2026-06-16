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
    /// unit-tested against an in-memory `AggregationService`. Errors are swallowed by the
    /// caller (`handle(task:)`) — a failed background run must never crash the app.
    static func runRefresh(service: AggregationService) async {
        await service.updateAll()
    }
}
