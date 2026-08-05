import Foundation
import SwiftData
import Testing
@testable import Yana

@MainActor
@Suite("SyncWriter")
struct SyncWriterTests {
    private func makeContainer() throws -> ModelContainer {
        try ModelContainer(for: Article.self, Feed.self, Tag.self, configurations: .init(isStoredInMemoryOnly: true))
    }

    /// Server article ids need a durable local anchor to upsert against on later syncs.
    /// `Article` gains a `serverID: Int` for exactly this (added in Step 3 below alongside
    /// the rest of `SyncWriter`, since it's this task's own new column, not an earlier one).
    @Test func upsertInsertsNewArticlesAndTagsFeedRelationship() async throws {
        let container = try makeContainer()
        let writer = SyncWriter(modelContainer: container)
        let feedID = await writer.replaceFeeds([
            SyncFeedWire(id: 1, name: "Test Feed", aggregator: "feed_content", identifier: "f1",
                         enabled: true, dailyLimit: 20, tagIds: [], logoImageHash: nil, updatedAt: .now)
        ]).first

        let now = Date.now
        let ids = await writer.upsertSummaries([
            SyncArticleSummaryWire(id: 100, feedId: 1, name: "Hello", identifier: "art-100",
                                    date: now, author: "Jane", icon: nil, read: false, starred: false,
                                    createdAt: now, updatedAt: now)
        ])
        #expect(ids.count == 1)

        let context = container.mainContext
        let articles = try context.fetch(FetchDescriptor<Article>())
        #expect(articles.count == 1)
        #expect(articles.first?.title == "Hello")
        #expect(articles.first?.serverID == 100)
        // NOTE: the brief's literal test asserted `"f1"` (the wire's own `identifier` field), but
        // `replaceFeeds` (per the brief's own literal implementation) stores the server's numeric
        // feed id as `Feed.identifier` -- `SyncFeedWire.identifier` is decoded but intentionally
        // unused. That's the only field `Feed` (already merged, Task 7) has for
        // `upsertSummaries`'s `feedId`-based lookup to match against, so the implementation can't
        // be changed to honor `"f1"` without a new numeric column on `Feed`, which is out of this
        // task's scope. Fixed the assertion to match the implementation's actual, necessary
        // behavior -- see task-9-report.md for the full trace.
        #expect(articles.first?.feed?.identifier == "1")
        _ = feedID
    }

    /// Critical 2 fix: `ArticleSummaryWire` has no separate `url` field -- the server's own
    /// aggregators set `identifier` to the article's URL/permalink directly (confirmed against
    /// yana-server's `website`/`reddit`/`youtube` aggregators). Without this, Share/Open in
    /// Browser/Copy Link are permanently inert on every synced article.
    @Test func upsertSetsArticleURLFromIdentifierOnInsertAndUpdate() async throws {
        let container = try makeContainer()
        let writer = SyncWriter(modelContainer: container)
        let now = Date.now
        _ = await writer.upsertSummaries([
            SyncArticleSummaryWire(id: 100, feedId: 1, name: "Hello", identifier: "https://example.com/a",
                                    date: now, author: "", icon: nil, read: false, starred: false,
                                    createdAt: now, updatedAt: now)
        ])
        let inserted = try container.mainContext.fetch(FetchDescriptor<Article>()).first!
        #expect(inserted.url == "https://example.com/a")

        _ = await writer.upsertSummaries([
            SyncArticleSummaryWire(id: 100, feedId: 1, name: "Hello", identifier: "https://example.com/a-moved",
                                    date: now, author: "", icon: nil, read: false, starred: false,
                                    createdAt: now, updatedAt: now.addingTimeInterval(60))
        ])
        let updated = try container.mainContext.fetch(FetchDescriptor<Article>()).first!
        #expect(updated.url == "https://example.com/a-moved")
    }

    /// Critical 3 fix: a server-side content update must be re-pulled. `upsertSummaries`'s
    /// update branch didn't reset `hasContent`, so `SyncEngine.backfillMissingContent()`'s
    /// `hasContent == false` scan never re-fetched an updated article's body.
    @Test func upsertResetsHasContentOnUpdateSoStaleBodyGetsBackfilled() async throws {
        let container = try makeContainer()
        let writer = SyncWriter(modelContainer: container)
        let now = Date.now
        _ = await writer.upsertSummaries([
            SyncArticleSummaryWire(id: 100, feedId: 1, name: "Original", identifier: "art-100",
                                    date: now, author: "", icon: nil, read: false, starred: false,
                                    createdAt: now, updatedAt: now)
        ])
        let doc = try JSONDecoder().decode(WireDocument.self, from: #"{"version":1,"blocks":[]}"#.data(using: .utf8)!)
        _ = await writer.applyContent(articleServerID: 100, document: doc)
        #expect(try container.mainContext.fetch(FetchDescriptor<Article>()).first!.hasContent == true)

        _ = await writer.upsertSummaries([
            SyncArticleSummaryWire(id: 100, feedId: 1, name: "Updated Title", identifier: "art-100",
                                    date: now, author: "", icon: nil, read: false, starred: false,
                                    createdAt: now, updatedAt: now.addingTimeInterval(60))
        ])
        #expect(try container.mainContext.fetch(FetchDescriptor<Article>()).first!.hasContent == false)

        let missing = await writer.articlesMissingContent(limit: 10)
        #expect(missing.map(\.serverID) == [100])
    }

    /// Important 7 fix: `replaceFeeds` is upsert-only despite its name -- a feed the server stops
    /// returning must be deleted locally too, or it keeps showing in `TagFilterView`'s Feeds
    /// section forever.
    @Test func replaceFeedsRemovesLocalFeedsTheServerNoLongerReturns() async throws {
        let container = try makeContainer()
        let writer = SyncWriter(modelContainer: container)
        _ = await writer.replaceFeeds([
            SyncFeedWire(id: 1, name: "Feed One", aggregator: "feed_content", identifier: "f1",
                         enabled: true, dailyLimit: 20, tagIds: [], logoImageHash: nil, updatedAt: .now),
            SyncFeedWire(id: 2, name: "Feed Two", aggregator: "feed_content", identifier: "f2",
                         enabled: true, dailyLimit: 20, tagIds: [], logoImageHash: nil, updatedAt: .now),
        ])
        _ = await writer.replaceFeeds([
            SyncFeedWire(id: 1, name: "Feed One", aggregator: "feed_content", identifier: "f1",
                         enabled: true, dailyLimit: 20, tagIds: [], logoImageHash: nil, updatedAt: .now)
        ])
        let feeds = try container.mainContext.fetch(FetchDescriptor<Feed>())
        #expect(feeds.map(\.name) == ["Feed One"])
    }

    /// Critical 1 fix: `SyncWriter` never populated any `Tag` row, so `TagFilterView`'s Tags
    /// section was always empty and every article read as "untagged." `syncTags` upserts by
    /// `Tag.serverID`, mirroring `replaceFeeds`.
    @Test func syncTagsUpsertsByServerID() async throws {
        let container = try makeContainer()
        let writer = SyncWriter(modelContainer: container)
        let ids = await writer.syncTags([SyncTagWire(id: 1, name: "News", color: "#ff0000")])
        #expect(ids.count == 1)

        var tags = try container.mainContext.fetch(FetchDescriptor<Yana.Tag>())
        #expect(tags.count == 1)
        #expect(tags.first?.name == "News")
        #expect(tags.first?.colorHex == "#ff0000")
        #expect(tags.first?.serverID == 1)

        _ = await writer.syncTags([SyncTagWire(id: 1, name: "News Renamed", color: "#00ff00")])
        tags = try container.mainContext.fetch(FetchDescriptor<Yana.Tag>())
        #expect(tags.count == 1)
        #expect(tags.first?.name == "News Renamed")
        #expect(tags.first?.colorHex == "#00ff00")
    }

    @Test func syncTagsRemovesLocalTagsTheServerNoLongerReturns() async throws {
        let container = try makeContainer()
        let writer = SyncWriter(modelContainer: container)
        _ = await writer.syncTags([
            SyncTagWire(id: 1, name: "News", color: "#ff0000"),
            SyncTagWire(id: 2, name: "Fun", color: "#00ff00"),
        ])
        _ = await writer.syncTags([SyncTagWire(id: 1, name: "News", color: "#ff0000")])
        let tags = try container.mainContext.fetch(FetchDescriptor<Yana.Tag>())
        #expect(tags.map(\.name) == ["News"])
    }

    @Test func upsertUpdatesExistingArticleByServerIDPreservingCreatedAt() async throws {
        let container = try makeContainer()
        let writer = SyncWriter(modelContainer: container)
        let now = Date.now
        _ = await writer.upsertSummaries([
            SyncArticleSummaryWire(id: 100, feedId: 1, name: "Original", identifier: "art-100",
                                    date: now, author: "Jane", icon: nil, read: false, starred: false,
                                    createdAt: now, updatedAt: now)
        ])
        let originalCreatedAt = try container.mainContext.fetch(FetchDescriptor<Article>()).first!.createdAt

        _ = await writer.upsertSummaries([
            SyncArticleSummaryWire(id: 100, feedId: 1, name: "Updated Title", identifier: "art-100",
                                    date: now, author: "Jane", icon: nil, read: false, starred: true,
                                    createdAt: now, updatedAt: now.addingTimeInterval(60))
        ])
        let updated = try container.mainContext.fetch(FetchDescriptor<Article>()).first!
        #expect(updated.title == "Updated Title")
        #expect(updated.starred == true)
        #expect(updated.createdAt == originalCreatedAt)
    }

    @Test func applyRemovalsDeletesByServerID() async throws {
        let container = try makeContainer()
        let writer = SyncWriter(modelContainer: container)
        let now = Date.now
        _ = await writer.upsertSummaries([
            SyncArticleSummaryWire(id: 100, feedId: 1, name: "Gone Soon", identifier: "art-100",
                                    date: now, author: "", icon: nil, read: false, starred: false,
                                    createdAt: now, updatedAt: now)
        ])
        await writer.applyRemovals([100])
        let remaining = try container.mainContext.fetch(FetchDescriptor<Article>())
        #expect(remaining.isEmpty)
    }

    @Test func applyContentDecodesBlocksAndMarksHasContent() async throws {
        let container = try makeContainer()
        let writer = SyncWriter(modelContainer: container)
        let now = Date.now
        _ = await writer.upsertSummaries([
            SyncArticleSummaryWire(id: 100, feedId: 1, name: "Body Coming", identifier: "art-100",
                                    date: now, author: "", icon: nil, read: false, starred: false,
                                    createdAt: now, updatedAt: now)
        ])
        let doc = try JSONDecoder().decode(WireDocument.self, from: #"""
        {"version":1,"blocks":[{"type":"paragraph","runs":[{"text":"Body text","styles":[],"link":null}]}]}
        """#.data(using: .utf8)!)
        let applied = await writer.applyContent(articleServerID: 100, document: doc)
        #expect(applied)
        let article = try container.mainContext.fetch(FetchDescriptor<Article>()).first!
        #expect(article.hasContent)
        #expect(article.blocks.count == 1)
    }

    @Test func articlesMissingContentReturnsOnlyUnfetchedOnes() async throws {
        let container = try makeContainer()
        let writer = SyncWriter(modelContainer: container)
        let now = Date.now
        _ = await writer.upsertSummaries([
            SyncArticleSummaryWire(id: 100, feedId: 1, name: "A", identifier: "a", date: now,
                                    author: "", icon: nil, read: false, starred: false, createdAt: now, updatedAt: now),
            SyncArticleSummaryWire(id: 101, feedId: 1, name: "B", identifier: "b", date: now,
                                    author: "", icon: nil, read: false, starred: false, createdAt: now, updatedAt: now),
        ])
        let doc = try JSONDecoder().decode(WireDocument.self, from: #"{"version":1,"blocks":[]}"#.data(using: .utf8)!)
        _ = await writer.applyContent(articleServerID: 100, document: doc)

        let missing = await writer.articlesMissingContent(limit: 10)
        #expect(missing.count == 1)
        #expect(missing.first?.serverID == 101)
    }
}
