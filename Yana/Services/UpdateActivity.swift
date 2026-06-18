import Foundation

/// App-lifetime tracker of in-flight aggregation runs.
///
/// Update operations are launched as detached `Task`s that outlive the views that start them.
/// A per-view `@State` flag is destroyed when the user navigates away, so the spinner would
/// vanish even though the work keeps running. Routing the in-flight count through this shared
/// observable instead keeps the spinner visible across navigation for as long as any update runs.
@MainActor
@Observable
final class UpdateActivity {
    static let shared = UpdateActivity()

    /// Number of update operations currently in flight.
    private(set) var inFlight = 0

    /// True while at least one update is running.
    var isUpdating: Bool { inFlight > 0 }

    /// The most recently started update. A new `restart` cancels it before running.
    private var current: Task<Void, Never>?

    func begin() { inFlight += 1 }
    func end() { inFlight = max(0, inFlight - 1) }

    /// Runs `operation` while keeping `isUpdating` true for its entire duration,
    /// balancing `begin()`/`end()` even if the work throws or the caller is cancelled.
    func run<T>(_ operation: () async -> T) async -> T {
        begin()
        defer { end() }
        return await operation()
    }

    /// Start `operation` as the current update, cancelling any in-flight one first.
    ///
    /// Instead of ignoring a new trigger while an update is running, this cancels the ongoing
    /// run and waits for it to unwind before starting the new one, so the counter/spinner stay
    /// balanced and the two runs never overlap. `operation` should check `Task.isCancelled`
    /// before applying any user-visible side effects so a superseded run stays silent.
    @discardableResult
    func restart(_ operation: @escaping () async -> Void) -> Task<Void, Never> {
        let previous = current
        let task = Task {
            previous?.cancel()
            await previous?.value
            await self.run(operation)
        }
        current = task
        return task
    }

    /// Cancel the current update, if any. The operation unwinds on its next
    /// `Task.isCancelled` check and `run`'s `defer` rebalances the in-flight count.
    func cancel() { current?.cancel() }
}
