import Foundation
import SwiftData
import Testing
@testable import Yana

/// Pins the fix for "the UI lags while a big import is running".
///
/// An import lands as a burst of saves, and every save wakes `ArticleStore`'s re-index. That runs
/// inside a `@ModelActor` — which executes on the *caller's* thread, so when a `@MainActor` type
/// awaits one the whole database pass happens on the main thread. Measured on a 4 000-article
/// library that was one ~300–600 ms freeze per import batch.
///
/// These tests assert the reaction chain leaves the main actor responsive. The thresholds are set
/// far below the pre-fix stalls and far above the post-fix noise floor (~3 ms), so they catch a
/// regression without being timing-flaky.
@MainActor
@Suite(.serialized)
struct SyncReactionMainThreadTests {

    /// A stall this long is a visibly dropped frame run; pre-fix these paths blocked 3–5× longer.
    static let maxAcceptableStallMS = 100.0

    @Test func fullLibraryReindexLeavesTheMainActorResponsive() async throws {
        let fixture = try LibraryFixture.make(articleCount: 4000)
        defer { try? FileManager.default.removeItem(at: fixture.directory) }
        let cache = SummaryIndexCache(fileURL: fixture.directory.appendingPathComponent("idx.plist"))
        let store = ArticleStore(container: fixture.container, cache: cache, anchorProvider: { nil })

        let stall = await MainActorResponsiveness.measuring {
            await store.refreshNow()
        }

        #expect(store.summaries.count == 4000)
        #expect(stall < Self.maxAcceptableStallMS,
                "ArticleStore.refreshNow() blocked the main actor for \(Int(stall)) ms")
    }

    @Test func coldStartWindowLoadLeavesTheMainActorResponsive() async throws {
        let fixture = try LibraryFixture.make(articleCount: 4000)
        defer { try? FileManager.default.removeItem(at: fixture.directory) }
        // No disk cache file, so this takes the anchor-window DB path.
        let cache = SummaryIndexCache(fileURL: fixture.directory.appendingPathComponent("absent.plist"))
        let store = ArticleStore(container: fixture.container, cache: cache, anchorProvider: { nil })

        let stall = await MainActorResponsiveness.measuring {
            await store.publishFastDataset()
        }

        #expect(store.hasLoaded)
        #expect(stall < Self.maxAcceptableStallMS,
                "ArticleStore.publishFastDataset() blocked the main actor for \(Int(stall)) ms")
    }

    /// End-to-end: import batches landing while `ArticleStore` observes saves — the actual
    /// "an update is running and the reader is on screen" situation.
    @Test func importBatchesLeaveTheMainActorResponsive() async throws {
        let fixture = try LibraryFixture.make(articleCount: 3000)
        defer { try? FileManager.default.removeItem(at: fixture.directory) }
        let context = fixture.container.mainContext
        let feedID = try #require(try context.fetch(FetchDescriptor<Feed>()).first).persistentModelID

        let cache = SummaryIndexCache(fileURL: fixture.directory.appendingPathComponent("idx.plist"))
        let store = ArticleStore(container: fixture.container, cache: cache, anchorProvider: { nil })
        store.start()
        try? await Task.sleep(for: .seconds(1))

        let stall = await MainActorResponsiveness.measuring {
            for batch in 0..<4 {
                await LibraryFixture.importBatch(into: fixture.container, feedID: feedID,
                                                 offset: batch * 400, count: 400)
                try? await Task.sleep(for: .milliseconds(400))
            }
            try? await Task.sleep(for: .seconds(2))
        }

        #expect(store.summaries.count > 3000, "the store should have picked the new rows up")
        #expect(stall < Self.maxAcceptableStallMS,
                "an import storm blocked the main actor for \(Int(stall)) ms")
    }
}
