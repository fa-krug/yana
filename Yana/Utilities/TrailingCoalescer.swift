import Foundation

/// Collapses a burst of triggers into as few executions as possible, combining two guarantees:
///
/// - **Trailing debounce:** `schedule()` (re)starts a quiet-period timer; the action runs only
///   once triggers stop arriving for `interval`.
/// - **Single-flight:** the action never runs concurrently with itself. If `schedule()` fires
///   while a run is in flight, exactly one follow-up run is guaranteed after the current one
///   finishes — so nothing is missed, but nothing stacks up either.
///
/// This tames an aggregation run's save storm: a multi-feed update fires `ModelContext.didSave`
/// many times in quick succession, and the naive reaction (a full-library re-fetch in
/// `ArticleStore`) is expensive and contends with the reader. Coalescing turns a burst into one run
/// (or at most one in-flight + one trailing run).
@MainActor
final class TrailingCoalescer {
    private let interval: Duration
    private let action: () async -> Void
    private var debounce: Task<Void, Never>?
    private var isRunning = false
    private var pending = false

    init(interval: Duration, action: @escaping () async -> Void) {
        self.interval = interval
        self.action = action
    }

    /// Register a trigger. Restarts the quiet-period timer; the action runs once triggers stop for
    /// `interval`.
    func schedule() {
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
