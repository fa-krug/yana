import Foundation
import SwiftData
import Testing
@testable import Yana

@MainActor
struct SummaryIndexMergeTests {

    /// Builds a container once so the summaries carry real `PersistentIdentifier`s — the merge keys
    /// on them, so synthesised values would not exercise the real path.
    private static func rows(_ count: Int) throws -> (ModelContainer, [Article], [ArticleSummary]) {
        let container = try ModelContainer(
            for: Feed.self, Tag.self, Article.self, StoredImage.self,
            configurations: ModelConfiguration(isStoredInMemoryOnly: true)
        )
        let context = ModelContext(container)
        let feed = Feed(name: "F", aggregatorType: .feedContent, identifier: "f")
        context.insert(feed)
        var articles: [Article] = []
        for i in 0..<count {
            let a = Article(title: "A\(i)", identifier: "a\(i)", url: "u\(i)",
                            date: Date(timeIntervalSince1970: Double(i)))
            a.createdAt = Date(timeIntervalSince1970: Double(i) * 10)
            a.feed = feed
            context.insert(a)
            articles.append(a)
        }
        try context.save()
        return (container, articles, articles.map(ArticleSummary.init))
    }

    @Test func insertLandsInCreatedAtOrder() throws {
        let (_, _, all) = try Self.rows(5)
        // Drop the middle row from the index, then splice it back in.
        let index = all.enumerated().filter { $0.offset != 2 }.map(\.element)
        let merged = SummaryIndexMerge.apply(to: index, changed: [all[2]], removed: [])
        #expect(merged.map(\.identifier) == all.map(\.identifier))
    }

    @Test func changedRowMovesToItsNewPosition() throws {
        let (_, articles, all) = try Self.rows(4)
        // Same row, re-dated to be the oldest — it must move to the front, not duplicate.
        articles[3].createdAt = Date(timeIntervalSince1970: -100)
        let moved = ArticleSummary(articles[3])
        let merged = SummaryIndexMerge.apply(to: all, changed: [moved], removed: [])
        #expect(merged.count == 4)
        #expect(merged.first?.identifier == all[3].identifier)
        #expect(Set(merged.map(\.identifier)).count == 4, "no duplicate of the moved row")
    }

    @Test func removedRowsAreDropped() throws {
        let (_, _, all) = try Self.rows(4)
        let removed = Set([all[1].persistentID!, all[2].persistentID!])
        let merged = SummaryIndexMerge.apply(to: all, changed: [], removed: removed)
        #expect(merged.map(\.identifier) == [all[0].identifier, all[3].identifier])
    }

    @Test func mergePreservesAscendingOrderWithManyChanges() throws {
        let (_, _, all) = try Self.rows(50)
        let index = all.enumerated().filter { $0.offset % 3 != 0 }.map(\.element)
        let changed = all.enumerated().filter { $0.offset % 3 == 0 }.map(\.element)
        let merged = SummaryIndexMerge.apply(to: index, changed: changed.shuffled(), removed: [])
        #expect(merged.count == 50)
        #expect(merged.map(\.createdAt) == merged.map(\.createdAt).sorted())
        #expect(Set(merged.map(\.identifier)).count == 50, "no duplicates")
    }

    @Test func emptyChangeIsANoOp() throws {
        let (_, _, all) = try Self.rows(3)
        #expect(SummaryIndexMerge.apply(to: all, changed: [], removed: []) == all)
    }

    /// A disk-cache-hydrated index has no `persistentID`s, so it can't be spliced.
    @Test func spliceabilityRequiresPersistentIDs() throws {
        let (_, _, all) = try Self.rows(3)
        #expect(SummaryIndexMerge.isSpliceable(all))

        let encoded = try PropertyListEncoder().encode(all)
        let rehydrated = try PropertyListDecoder().decode([ArticleSummary].self, from: encoded)
        #expect(rehydrated.allSatisfy { $0.persistentID == nil })
        #expect(SummaryIndexMerge.isSpliceable(rehydrated) == false)
    }

    @Test func emptyIndexIsSpliceable() {
        #expect(SummaryIndexMerge.isSpliceable([]))
    }
}
