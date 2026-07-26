import Foundation
import SwiftData
import Testing
@testable import Yana

@MainActor
@Suite("AggregationWriter")
struct AggregationWriterTests {
    private func makeContainer() throws -> ModelContainer {
        let config = ModelConfiguration(isStoredInMemoryOnly: true, cloudKitDatabase: .none)
        let container = try ModelContainer(for: Feed.self, Yana.Tag.self, Article.self, configurations: config)
        let seed = ModelContext(container)
        seed.insert(Yana.Tag(name: Yana.Tag.starredName, isBuiltIn: true))
        try seed.save()
        return container
    }

    private struct FakeAggregator: Aggregator {
        let articles: [AggregatedArticle]
        func validate() throws {}
        func aggregate() async throws -> [AggregatedArticle] { articles }
    }
    private struct IdentityAI: AIProcessing {
        func process(_ input: [AggregatedArticle], ai: AIOptions) async -> [AggregatedArticle] { input }
    }
    private func inputs(
        makeAggregator: @escaping AggregatorFactory,
        progress: @escaping @Sendable (AggregationProgress) -> Void = { _ in }
    ) -> AggregationRunInputs {
        AggregationRunInputs(
            makeAggregator: makeAggregator, processor: IdentityAI(),
            logoResolver: { _, _ in nil }, credentials: .resolved(), now: .now,
            starredIdentifiers: { _, _ in [] }, canonicalCreatedAt: [:],
            isSourceEnabled: { _ in true }, retentionDays: 30, skipRetention: false,
            progress: progress)
    }
    nonisolated private func aggregated(_ id: String, date: Date = .now) -> AggregatedArticle {
        AggregatedArticle(title: id, identifier: id, url: id, rawContent: "", content: "c", date: date, author: "", iconURL: nil)
    }

    @Test func runUpdateAllInsertsOffOwnContextVisibleViaFreshFetch() async throws {
        let container = try makeContainer()
        let main = ModelContext(container)
        let feed = Feed(name: "A", aggregatorType: .feedContent, identifier: "a")
        main.insert(feed); try main.save()

        let writer = AggregationWriter(modelContainer: container)
        let result = await writer.runUpdateAll(inputs { _, _ in
            FakeAggregator(articles: [self.aggregated("x1"), self.aggregated("x2")])
        })

        #expect(result.inserted == 2)
        #expect(result.touchedUIDs.count == 2)
        // Fresh fetch on the main context sees the background inserts.
        #expect((try main.fetch(FetchDescriptor<Article>())).count == 2)
    }

    @Test func runUpdateAllEmitsProgressStartThenAdvances() async throws {
        let container = try makeContainer()
        let main = ModelContext(container)
        for i in 0..<3 { main.insert(Feed(name: "F\(i)", aggregatorType: .feedContent, identifier: "f\(i)")) }
        try main.save()

        final class Rec: @unchecked Sendable { var started = -1; var advances = 0 }
        let rec = Rec()
        let writer = AggregationWriter(modelContainer: container)
        _ = await writer.runUpdateAll(inputs(makeAggregator: { _, _ in FakeAggregator(articles: []) }) { ev in
            switch ev { case .start(let t): rec.started = t; case .advance: rec.advances += 1 }
        })

        #expect(rec.started == 3)
        #expect(rec.advances == 3)
    }

    @Test func runUpdateSkipsDisabledSourceWithoutError() async throws {
        let container = try makeContainer()
        let main = ModelContext(container)
        let reddit = Feed(name: "r", aggregatorType: .reddit, identifier: "swift")
        main.insert(reddit); try main.save()
        let feedID = reddit.persistentModelID

        let writer = AggregationWriter(modelContainer: container)
        var ins = inputs { _, _ in FakeAggregator(articles: [self.aggregated("x")]) }
        ins = AggregationRunInputs(
            makeAggregator: ins.makeAggregator, processor: ins.processor, logoResolver: ins.logoResolver,
            credentials: ins.credentials, now: ins.now, starredIdentifiers: ins.starredIdentifiers,
            canonicalCreatedAt: ins.canonicalCreatedAt, isSourceEnabled: { $0 != .reddit },
            retentionDays: ins.retentionDays, skipRetention: ins.skipRetention, progress: ins.progress)
        let result = await writer.runUpdate(feedID: feedID, ins)

        #expect(result.inserted == 0)
        #expect((try main.fetch(FetchDescriptor<Article>())).isEmpty)
    }

    @Test func writerUsesADistinctContextFromMain() async throws {
        let container = try makeContainer()
        let main = ModelContext(container)
        let writer = AggregationWriter(modelContainer: container)
        // distinct context → not the same → false
        let sameAsMain = await writer.contextIsSameAs(main)
        #expect(sameAsMain == false)
    }

    @Test func retentionDeletesAgedOutAndReportsDeletedUIDs() async throws {
        let container = try makeContainer()
        let main = ModelContext(container)
        let feed = Feed(name: "A", aggregatorType: .feedContent, identifier: "a")
        main.insert(feed)
        let old = Article(title: "old", identifier: "old", url: "u", date: .now, author: "", iconURL: nil)
        old.feed = feed
        old.createdAt = Date.now.addingTimeInterval(-40 * 24 * 3600)   // beyond 30-day retention
        main.insert(old); try main.save()

        let writer = AggregationWriter(modelContainer: container)
        let result = await writer.runUpdateAll(inputs { _, _ in FakeAggregator(articles: [self.aggregated("fresh")]) })

        let ids = Set((try main.fetch(FetchDescriptor<Article>())).map(\.identifier))
        #expect(ids == ["fresh"])                      // aged-out removed, new kept
        #expect(!result.deletedUIDs.isEmpty)           // reported for remote tombstoning
    }
}
