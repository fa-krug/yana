import Foundation

/// Runs work outside the main actor.
///
/// **Why this exists.** A `@ModelActor` does not own a background queue. SwiftData's
/// `DefaultSerialModelExecutor` runs enqueued jobs *inline on the calling thread*, so the actor's
/// body executes wherever the caller happens to be — and `await someModelActor.work()` from a
/// `@MainActor` type therefore performs the whole fetch/save **on the main thread**, blocking it for
/// the full duration. Declaring the type `@ModelActor` is not, by itself, "off the main thread";
/// only the caller's isolation decides. Constructing the actor off-main doesn't help either — the
/// thread is picked at the `await`, not at `init` (`OffMainActorTests` pins all three behaviours).
///
/// That trap is what made the UI lag during a large import: an aggregation run lands as a burst of
/// saves, each waking `ArticleStore`'s re-index, and on a 4 000-article library each burst froze the
/// main thread for ~300–600 ms.
///
/// Hopping through a detached task first puts the work on the cooperative pool, which is where the
/// executor then runs it.
///
/// **Caveat:** a detached task inherits neither task-local values nor cancellation from its caller,
/// so cancelling the awaiting task does not cancel `body`. Every current caller is a
/// run-to-completion database pass, for which that is the desired behaviour.
enum OffMainActor {
    static func run<T: Sendable>(
        priority: TaskPriority = .utility,
        _ body: @escaping @Sendable () async -> T
    ) async -> T {
        await Task.detached(priority: priority, operation: body).value
    }
}
