import Foundation

/// Serializes async work app-wide behind one FIFO queue. Used exclusively to wrap every
/// `SyncEngine.sync()` call site -- background refresh, pull-to-refresh/"Update All",
/// (re-)pairing, the initial post-onboarding sync, reload's post-poll sync -- so two syncs can
/// never run concurrently against the same `ModelContainer`.
///
/// Without this, two independent `SyncWriter` instances (each its own `@ModelActor`, its own
/// private `ModelContext`) can race the same server article: both fetch "no local row with this
/// `serverID`," both `insert()`, both `save()` -- producing a duplicate `Article` row, since
/// `Article.serverID` has no `@Attribute(.unique)` to catch this at the SwiftData layer (see
/// `DuplicateArticleCleaner`, which sweeps up whatever a device already accumulated before this
/// existed). The existing per-call-site guards (`BackgroundRefreshManager.isRunning`,
/// `UpdateActivity.restart`) only ever coordinate calls *within* their own call site -- a BGTask
/// sync and a manual pull-to-refresh had no shared lock between them at all, and Mac's `runNow()`/
/// periodic loop had no lock whatsoever.
///
/// Callers are queued, not coalesced: each call still runs its own real operation rather than
/// reusing a possibly-stale in-flight result, so a caller that specifically wants to observe the
/// outcome of a just-triggered server run (`UpdateAndSync.pollForFreshContent`) is guaranteed its
/// own pass, just never one that overlaps another. Generic over the operation (rather than typed
/// to `SyncEngine` directly) purely so tests can drive the queueing behavior with a plain async
/// closure instead of a real network-backed `SyncEngine`.
@MainActor
final class SyncCoordinator {
    static let shared = SyncCoordinator()

    /// A standing task that resolves once the most recently queued operation (and every one
    /// before it) has finished, success or failure. Each `run` call chains its own work onto
    /// this, then replaces it -- reading and replacing happens with no `await` in between, so two
    /// calls arriving back-to-back on the main actor can never both chain onto the same value and
    /// run side by side.
    private var tail: Task<Void, Never> = Task {}

    init() {}

    @discardableResult
    func run<T: Sendable>(_ operation: @Sendable @escaping () async throws -> T) async throws -> T {
        let previous = tail
        let resultTask = Task<T, Error> { @MainActor in
            await previous.value
            return try await operation()
        }
        tail = Task { _ = try? await resultTask.value }
        return try await resultTask.value
    }
}
