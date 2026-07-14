import Foundation
import os

/// Lightweight startup instrumentation. Each measured stage emits an `os_signpost` interval
/// (visible in Instruments via the **os_signpost** instrument, subsystem `de.fa-krug.Yana`,
/// category `startup`) and a console log line reporting the stage's duration in milliseconds
/// plus the elapsed time since the first trace call (≈ process launch).
///
/// To read the timings:
/// - **Xcode console:** filter on `⏱` to see one line per stage, longest stages stand out.
/// - **Instruments:** add the *os_signpost* instrument, set the subsystem to `de.fa-krug.Yana`;
///   each stage shows as a named interval on the timeline.
///
/// Signposts and `Logger` are cheap no-ops when nothing is recording the subsystem, so the
/// instrumentation can stay in place. Console lines are emitted in `DEBUG` builds only.
enum StartupTrace {
    private static let subsystem = AppConstants.bundleID
    private static let logger = Logger(subsystem: subsystem, category: "startup")
    private static let signposter = OSSignposter(subsystem: subsystem, category: "startup")

    /// Monotonic reference captured at first use (the earliest measured stage), so each line can
    /// report "+Nms since launch" — useful for spotting gaps between stages, not just stage cost.
    private static let origin = ContinuousClock.now

    /// Measure a synchronous stage.
    static func measure<T>(_ name: StaticString, _ body: () throws -> T) rethrows -> T {
        _ = origin // Establish the launch reference before timing the first stage.
        let id = signposter.makeSignpostID()
        let state = signposter.beginInterval(name, id: id)
        let start = ContinuousClock.now
        defer {
            signposter.endInterval(name, state)
            log(name, since: start)
        }
        return try body()
    }

    /// Measure an asynchronous stage. Inherits the caller's isolation (`#isolation`) so the body
    /// runs on the caller's actor — no hop, and non-`Sendable` captures stay legal.
    static func measure<T>(
        _ name: StaticString,
        isolation: isolated (any Actor)? = #isolation,
        _ body: () async throws -> T
    ) async rethrows -> T {
        _ = origin // Establish the launch reference before timing the first stage.
        let id = signposter.makeSignpostID()
        let state = signposter.beginInterval(name, id: id)
        let start = ContinuousClock.now
        defer {
            signposter.endInterval(name, state)
            log(name, since: start)
        }
        return try await body()
    }

    /// Mark a single point in time (e.g. "first frame", "store hasLoaded") relative to launch.
    static func event(_ name: StaticString) {
        signposter.emitEvent(name)
        #if DEBUG
        logger.log("⏱ \(name.description, privacy: .public) — at +\(elapsedMillis(from: origin))ms")
        #endif
    }

    // MARK: - Cold-start one-shot markers (fire only for the first reader page)

    @MainActor private static var didMarkFirstViewDidLoad = false
    @MainActor private static var didMarkWarmupTake = false

    /// Returns true exactly once — for the first reader page's `viewDidLoad` (the anchor page).
    @MainActor static func firstPageViewDidLoadOnce() -> Bool {
        guard !didMarkFirstViewDidLoad else { return false }
        didMarkFirstViewDidLoad = true
        event("firstPage.viewDidLoad")
        return true
    }

    @MainActor static func warmupTakeOnce(hit: Bool) {
        guard !didMarkWarmupTake else { return }
        didMarkWarmupTake = true
        event(hit ? "warmupTake.HIT" : "warmupTake.MISS")
    }

    private static func log(_ name: StaticString, since start: ContinuousClock.Instant) {
        #if DEBUG
        let took = elapsedMillis(from: start, to: .now)
        let atLaunch = elapsedMillis(from: origin, to: start)
        logger.log("⏱ \(name.description, privacy: .public) took \(took)ms (start +\(atLaunch)ms)")
        #endif
    }

    /// Milliseconds between two instants, rounded to one decimal place.
    private static func elapsedMillis(
        from start: ContinuousClock.Instant, to end: ContinuousClock.Instant = .now
    ) -> String {
        let c = start.duration(to: end).components
        let ms = Double(c.seconds) * 1000 + Double(c.attoseconds) / 1_000_000_000_000_000
        return String(format: "%.1f", ms)
    }
}
