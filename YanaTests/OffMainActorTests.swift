import Foundation
import SwiftData
import Testing
@testable import Yana

/// Reports which thread its body actually ran on. Exists to pin SwiftData's `@ModelActor`
/// execution model, which is the reason `OffMainActor` exists at all.
@ModelActor
actor ThreadReportingActor {
    func ranOnMainThread() -> Bool { Thread.isMainThread }
}

@MainActor
struct OffMainActorTests {

    private static func container() throws -> ModelContainer {
        try ModelContainer(
            for: Feed.self, Tag.self, Article.self, StoredImage.self,
            configurations: ModelConfiguration(isStoredInMemoryOnly: true)
        )
    }

    /// Documents the trap. A `@ModelActor` does **not** own a background queue: SwiftData's
    /// `DefaultSerialModelExecutor` runs enqueued jobs inline on the calling thread, so awaiting one
    /// from the main actor performs its fetches and saves on the main thread. If a future SwiftData
    /// release changes this, this test fails and `OffMainActor` can be retired.
    @Test func modelActorAwaitedFromMainActorRunsOnTheMainThread() async throws {
        let actor = ThreadReportingActor(modelContainer: try Self.container())
        #expect(await actor.ranOnMainThread() == true)
    }

    /// The guard: routing the call through `OffMainActor.run` moves the work off the main thread.
    @Test func offMainActorRunKeepsModelActorWorkOffTheMainThread() async throws {
        let container = try Self.container()
        let ranOnMain = await OffMainActor.run {
            await ThreadReportingActor(modelContainer: container).ranOnMainThread()
        }
        #expect(ranOnMain == false)
    }

    /// Creating the actor off-main is not enough on its own — the *caller* decides the thread — so
    /// the helper has to wrap the await, not just the construction.
    @Test func creatingOffMainButAwaitingOnMainStillRunsOnTheMainThread() async throws {
        let container = try Self.container()
        let actor = await Task.detached { ThreadReportingActor(modelContainer: container) }.value
        #expect(await actor.ranOnMainThread() == true)
    }

    @Test func offMainActorRunReturnsTheBodysValue() async throws {
        #expect(await OffMainActor.run { 6 * 7 } == 42)
    }
}
