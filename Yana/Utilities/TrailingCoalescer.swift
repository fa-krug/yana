import Foundation

/// Collapses a burst of triggers into as few executions as possible, combining two guarantees:
///
/// - **Trailing debounce:** `schedule()` (re)starts a quiet-period timer; the action runs only
///   once triggers stop arriving for `interval`.
/// - **Single-flight:** the action never runs concurrently with itself. If `schedule()` fires
///   while a run is in flight, exactly one follow-up run is guaranteed after the current one
///   finishes — so nothing is missed, but nothing stacks up either.
///
/// This tames the CloudKit sync storm: a merge fires `ModelContext.didSave` /
/// `.NSPersistentStoreRemoteChange` many times in quick succession, and each naive reaction
/// (a full-library re-fetch in `ArticleStore`, a full three-table scan in `LibraryDedup`) is
/// expensive and contends with the reader. Coalescing turns a burst into one run (or at most one
/// in-flight + one trailing run).
@MainActor
final class TrailingCoalescer {
    private let interval: Duration
    /// Optional ceiling: during a continuous trigger burst (each schedule() restarting the
    /// quiet-period timer), fire anyway once this much time has passed since the burst began,
    /// so a long sync burst can't starve the action indefinitely (audit P10).
    private let maxDelay: Duration?
    private let action: () async -> Void
    private var debounce: Task<Void, Never>?
    private var isRunning = false
    private var pending = false
    private var burstStart: ContinuousClock.Instant?

    init(interval: Duration, maxDelay: Duration? = nil, action: @escaping () async -> Void) {
        self.interval = interval
        self.maxDelay = maxDelay
        self.action = action
    }

    /// Register a trigger. Restarts the quiet-period timer; the action runs once triggers stop for
    /// `interval`. If `maxDelay` is set and this burst has already run that long since its first
    /// trigger, fires immediately instead of restarting the timer again.
    func schedule() {
        let now = ContinuousClock.now
        if burstStart == nil { burstStart = now }
        if let maxDelay, let start = burstStart, now - start >= maxDelay {
            debounce?.cancel()
            debounce = nil
            Task { [weak self] in await self?.fire() }
            return
        }
        debounce?.cancel()
        let interval = interval
        debounce = Task { [weak self] in
            try? await Task.sleep(for: interval)
            guard !Task.isCancelled else { return }
            await self?.fire()
        }
    }

    /// Run now, skipping the debounce (still single-flighted). Awaitable, for foreground triggers
    /// and tests.
    func fireNow() async {
        debounce?.cancel()
        debounce = nil
        await fire()
    }

    private func fire() async {
        burstStart = nil
        guard !isRunning else { pending = true; return }
        isRunning = true
        await action()
        isRunning = false
        if pending {
            pending = false
            await fire()
        }
    }
}
