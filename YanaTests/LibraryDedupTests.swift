import Foundation
import SwiftData
import Testing
@testable import Yana

@MainActor
struct LibraryDedupTests {
    private func container() throws -> ModelContainer {
        try ModelContainer(for: Feed.self, Yana.Tag.self, Article.self, StoredImage.self,
                           configurations: ModelConfiguration(isStoredInMemoryOnly: true,
                                                              cloudKitDatabase: .none))
    }

    @Test func collapsesDuplicateFeedsKeepingEarliest() async throws {
        let c = try container()
        let ctx = c.mainContext
        let older = Feed(name: "A", aggregatorType: .feedContent, identifier: "id1")
        older.createdAt = .init(timeIntervalSince1970: 100)
        let newer = Feed(name: "A", aggregatorType: .feedContent, identifier: "id1")
        newer.createdAt = .init(timeIntervalSince1970: 200)
        ctx.insert(older); ctx.insert(newer)
        // article on the newer duplicate must re-point to the survivor
        let art = Article(title: "t", identifier: "x", url: "u")
        art.feed = newer
        ctx.insert(art)
        try ctx.save()

        let deduper = LibraryDeduper(modelContainer: c)
        let deleted = try await deduper.deduplicate()
        #expect(deleted == 1)
        let feeds = try ctx.fetch(FetchDescriptor<Feed>())
        #expect(feeds.count == 1)
        #expect(feeds.first?.createdAt == .init(timeIntervalSince1970: 100))
        let arts = try ctx.fetch(FetchDescriptor<Article>())
        #expect(arts.first?.feed?.identifier == "id1")
    }

    @Test func collapsesDuplicateArticlesOrsStarred() async throws {
        let c = try container()
        let ctx = c.mainContext
        _ = Yana.Tag.ensureBuiltIns(in: ctx)
        let starred = try ctx.fetch(FetchDescriptor<Yana.Tag>(predicate: #Predicate { $0.isBuiltIn })).first!
        let feed = Feed(name: "F", aggregatorType: .feedContent, identifier: "f1")
        ctx.insert(feed)
        let a1 = Article(title: "same", identifier: "dup", url: "u"); a1.feed = feed
        a1.syncFeedIdentifier = "f1"; a1.syncAggregatorType = AggregatorType.feedContent.rawValue
        a1.createdAt = .init(timeIntervalSince1970: 10)
        let a2 = Article(title: "same", identifier: "dup", url: "u"); a2.feed = feed
        a2.syncFeedIdentifier = "f1"; a2.syncAggregatorType = AggregatorType.feedContent.rawValue
        a2.createdAt = .init(timeIntervalSince1970: 20)
        var a2Tags = a2.tags ?? []; a2Tags.append(starred); a2.tags = a2Tags   // only the loser is starred
        ctx.insert(a1); ctx.insert(a2)
        try ctx.save()

        let deleted = try await LibraryDeduper(modelContainer: c).deduplicate()
        #expect(deleted == 1)
        let arts = try ctx.fetch(FetchDescriptor<Article>())
        #expect(arts.count == 1)
        #expect(arts.first?.createdAt == .init(timeIntervalSince1970: 10))  // earliest survives
        #expect(arts.first?.isStarred == true)                              // starred OR-ed onto survivor
    }

    @Test func noDuplicatesIsNoOp() async throws {
        let c = try container()
        c.mainContext.insert(Feed(name: "A", aggregatorType: .feedContent, identifier: "id1"))
        try c.mainContext.save()
        #expect(try await LibraryDeduper(modelContainer: c).deduplicate() == 0)
    }
}
