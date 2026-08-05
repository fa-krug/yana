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

    /// Starring flips one article's `starred` boolean; the index must pick that up without a full
    /// re-read.
    @Test func updatingOneArticleRefreshesJustThatRow() async throws {
        let fixture = try LibraryFixture.make(articleCount: 150)
        defer { try? FileManager.default.removeItem(at: fixture.directory) }
        let context = fixture.container.mainContext

        let store = makeStore(fixture)
        store.start()
        await wait(for: store, toReach: 150)

        var descriptor = FetchDescriptor<Article>(sortBy: [SortDescriptor(\.createdAt)])
        descriptor.fetchLimit = 1
        let article = try #require(try context.fetch(descriptor).first)
        let target = article.identifier
        article.starred = true
        try context.save()

        for _ in 0..<80 where store.summaries.first(where: { $0.identifier == target })?.isStarred != true {
            try? await Task.sleep(for: .milliseconds(50))
        }
        #expect(store.summaries.count == 150)
        #expect(store.summaries.first { $0.identifier == target }?.isStarred == true)
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
