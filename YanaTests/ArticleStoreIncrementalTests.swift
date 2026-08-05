import Foundation
import SwiftData
import Testing
@testable import Yana

/// The timeline index is refreshed by splicing the rows a save named, not by re-reading the
/// library. These tests pin the observable consequences: the index stays correct, and the work
/// scales with the change rather than with the library.
@MainActor
@Suite(.serialized)
struct ArticleStoreIncrementalTests {

    private func makeStore(_ fixture: LibraryFixture.Handle) -> ArticleStore {
        let cache = SummaryIndexCache(fileURL: fixture.directory.appendingPathComponent("idx.plist"))
        return ArticleStore(container: fixture.container, cache: cache, anchorProvider: { nil })
    }

    /// Wait for the store to settle on an expected count (the refresh is debounced + off-main).
    private func wait(for store: ArticleStore, toReach count: Int) async {
        for _ in 0..<80 where store.summaries.count != count {
            try? await Task.sleep(for: .milliseconds(50))
        }
    }

    @Test func insertedArticlesAppearInCreatedAtOrder() async throws {
        let fixture = try LibraryFixture.make(articleCount: 300)
        defer { try? FileManager.default.removeItem(at: fixture.directory) }
        let feedID = try #require(
            try fixture.container.mainContext.fetch(FetchDescriptor<Feed>()).first
        ).persistentModelID

        let store = makeStore(fixture)
        store.start()
        await wait(for: store, toReach: 300)
        #expect(store.summaries.count == 300)

        await LibraryFixture.importBatch(into: fixture.container, feedID: feedID,
                                         offset: 0, count: 25)
        await wait(for: store, toReach: 325)

        #expect(store.summaries.count == 325)
        #expect(store.summaries.map(\.createdAt) == store.summaries.map(\.createdAt).sorted(),
                "the spliced index must stay createdAt-ascending")
        #expect(Set(store.summaries.map(\.identifier)).count == 325, "no duplicated rows")
    }

    /// The spliced index must match what a full re-read would have produced.
    @Test func splicedIndexMatchesAFullReload() async throws {
        let fixture = try LibraryFixture.make(articleCount: 200)
        defer { try? FileManager.default.removeItem(at: fixture.directory) }
        let context = fixture.container.mainContext
        let feedID = try #require(try context.fetch(FetchDescriptor<Feed>()).first).persistentModelID

        let store = makeStore(fixture)
        store.start()
        await wait(for: store, toReach: 200)

        await LibraryFixture.importBatch(into: fixture.container, feedID: feedID,
                                         offset: 0, count: 30)
        await wait(for: store, toReach: 230)
        let spliced = store.summaries.map(\.identifier)

        let reference = try await ArticleSummaryLoader(modelContainer: fixture.container).load()
        #expect(spliced == reference.map(\.identifier))
    }

    @Test func deletedArticlesLeaveTheIndex() async throws {
        let fixture = try LibraryFixture.make(articleCount: 100)
        defer { try? FileManager.default.removeItem(at: fixture.directory) }
        let context = fixture.container.mainContext

        let store = makeStore(fixture)
        store.start()
        await wait(for: store, toReach: 100)

        var descriptor = FetchDescriptor<Article>(sortBy: [SortDescriptor(\.createdAt)])
        descriptor.fetchLimit = 3
        let doomed = try context.fetch(descriptor)
        let goneIDs = Set(doomed.map(\.identifier))
        doomed.forEach { context.delete($0) }
        try context.save()

        await wait(for: store, toReach: 97)
        #expect(store.summaries.count == 97)
        #expect(store.summaries.allSatisfy { !goneIDs.contains($0.identifier) })
    }

    /// A save that touches no `Article` — a tag, a feed — must not disturb the index at all.
    /// Before this, every such save cost a full-library re-read.
    @Test func savesThatTouchNoArticleDoNotRefreshTheIndex() async throws {
        let fixture = try LibraryFixture.make(articleCount: 200)
        defer { try? FileManager.default.removeItem(at: fixture.directory) }
        let context = fixture.container.mainContext

        let store = makeStore(fixture)
        store.start()
        await wait(for: store, toReach: 200)
        let before = store.summaries

        context.insert(Tag(name: "Fresh Tag", sortOrder: 99))
        try context.save()
        try? await Task.sleep(for: .milliseconds(600))

        #expect(store.summaries == before, "a non-article save must leave the index untouched")
    }

    /// Starring writes a tag onto one article; the index must pick that up without a full re-read.
    @Test func updatingOneArticleRefreshesJustThatRow() async throws {
        let fixture = try LibraryFixture.make(articleCount: 150)
        defer { try? FileManager.default.removeItem(at: fixture.directory) }
        let context = fixture.container.mainContext

        let store = makeStore(fixture)
        store.start()
        await wait(for: store, toReach: 150)

        let starred = Tag(name: Tag.starredName, isBuiltIn: true, sortOrder: -1)
        context.insert(starred)
        var descriptor = FetchDescriptor<Article>(sortBy: [SortDescriptor(\.createdAt)])
        descriptor.fetchLimit = 1
        let article = try #require(try context.fetch(descriptor).first)
        let target = article.identifier
        article.setStarred(true, using: starred)
        try context.save()

        for _ in 0..<80 where store.summaries.first(where: { $0.identifier == target })?.isStarred != true {
            try? await Task.sleep(for: .milliseconds(50))
        }
        #expect(store.summaries.count == 150)
        #expect(store.summaries.first { $0.identifier == target }?.isStarred == true)
    }

    /// On a `.automatic` (CloudKit) store a local save posts `.NSPersistentStoreRemoteChange` as
    /// well — several times per save. The remote-change observer therefore must **not** treat that
    /// as "re-read the library", or ordinary local writes would cost a full-library read again.
    /// This runs on the store shape the app actually ships and pins both halves: the notifications
    /// really do fire, and the store still refreshes by splicing.
    @Test func localSavesOnACloudKitStoreStillSpliceRatherThanReload() async throws {
        let fixture = try LibraryFixture.make(articleCount: 200, cloudKit: true)
        defer { try? FileManager.default.removeItem(at: fixture.directory) }
        let feedID = try #require(
            try fixture.container.mainContext.fetch(FetchDescriptor<Feed>()).first
        ).persistentModelID

        final class Counter: @unchecked Sendable { var value = 0 }
        let remoteChanges = Counter()
        let observer = NotificationCenter.default.addObserver(
            forName: .NSPersistentStoreRemoteChange, object: nil, queue: .main
        ) { _ in remoteChanges.value += 1 }
        defer { NotificationCenter.default.removeObserver(observer) }

        let store = makeStore(fixture)
        store.start()
        await wait(for: store, toReach: 200)
        let reloadsAfterLaunch = store.fullReloadCount

        await LibraryFixture.importBatch(into: fixture.container, feedID: feedID,
                                         offset: 0, count: 10)
        await wait(for: store, toReach: 210)
        try? await Task.sleep(for: .milliseconds(600))   // let any count probe settle

        #expect(store.summaries.count == 210)
        #expect(remoteChanges.value > 0,
                "expected a local save on a CloudKit store to post remote-change notifications")
        #expect(store.fullReloadCount == reloadsAfterLaunch,
                "a local save must not trigger a full library re-read")
        #expect(store.spliceCount > 0)
    }

    /// The count probe is the safety net for a change the store can't splice — a CloudKit merge
    /// names no rows of ours. A *second container over the same store file* reproduces that: its
    /// writes reach the same database, but the identifiers they announce are not ones this store's
    /// index can be keyed on. The store must still converge.
    @Test func aChangeFromOutsideThisContainerStillReachesTheIndex() async throws {
        let fixture = try LibraryFixture.make(articleCount: 100)
        defer { try? FileManager.default.removeItem(at: fixture.directory) }

        let store = makeStore(fixture)
        store.start()
        await wait(for: store, toReach: 100)

        let outside = try ModelContainer(
            for: Feed.self, Tag.self, Article.self,
            configurations: ModelConfiguration(
                url: fixture.directory.appendingPathComponent("test.store"), cloudKitDatabase: .none
            )
        )
        let outsideFeedID = try #require(
            try outside.mainContext.fetch(FetchDescriptor<Feed>()).first
        ).persistentModelID
        await LibraryFixture.importBatch(into: outside, feedID: outsideFeedID,
                                         offset: 5000, count: 7)
        // Mirroring posts this after it merges; the store's probe turns it into a re-read.
        NotificationCenter.default.post(name: .NSPersistentStoreRemoteChange, object: nil)

        await wait(for: store, toReach: 107)
        #expect(store.summaries.count == 107,
                "the store must converge on rows written outside its own container")
    }

    /// The whole point: refreshing after a small change reads only the changed rows. Measured on
    /// the loader, where the cost actually is — a 25-row fetch against a 4 000-row one.
    @Test func readingChangedRowsCostsFarLessThanReadingTheLibrary() async throws {
        let fixture = try LibraryFixture.make(articleCount: 4000)
        defer { try? FileManager.default.removeItem(at: fixture.directory) }
        let loader = ArticleSummaryLoader(modelContainer: fixture.container)

        _ = try await loader.load()                    // warm the store's caches for a fair race
        let fullStart = Date()
        let all = try await loader.load()
        let fullMS = Date().timeIntervalSince(fullStart) * 1000

        let someIDs = Array(all.suffix(25).compactMap(\.persistentID))
        #expect(someIDs.count == 25)
        let spliceStart = Date()
        let changed = try await loader.summaries(for: someIDs)
        let spliceMS = Date().timeIntervalSince(spliceStart) * 1000

        #expect(changed.count == 25)
        #expect(spliceMS < fullMS / 3,
                "25-row read took \(Int(spliceMS)) ms vs \(Int(fullMS)) ms for all 4 000")
    }
}
