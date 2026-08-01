import Foundation
import SwiftData
import Testing
@testable import Yana

@MainActor
@Suite("AggregationService")
struct AggregationServiceTests {
    private func makeContext() throws -> ModelContext {
        let config = ModelConfiguration(isStoredInMemoryOnly: true)
        let container = try ModelContainer(for: Feed.self, Yana.Tag.self, Article.self, configurations: config)
        let context = ModelContext(container)
        context.insert(Yana.Tag(name: Yana.Tag.starredName, isBuiltIn: true))
        return context
    }

    /// Fresh fetch of all articles (sees writes from any sibling context of this container).
    private func allArticles(_ context: ModelContext) -> [Article] {
        (try? context.fetch(FetchDescriptor<Article>())) ?? []
    }
    /// Fresh fetch of a single feed's articles by the feed's identifier (relationship read on
    /// freshly-fetched Article objects is not stale).
    private func articles(_ context: ModelContext, feed identifier: String) -> [Article] {
        allArticles(context).filter { $0.feed?.identifier == identifier }
    }
    /// Re-resolve a feed so scalar reads (lastError/lastFetchedAt/logoHash) are refreshed.
    private func refetch(_ context: ModelContext, feed id: PersistentIdentifier) -> Feed? {
        context.model(for: id) as? Feed
    }

    /// Fake aggregator returning canned articles (no network).
    private struct FakeAggregator: Aggregator {
        let articles: [AggregatedArticle]
        var validateError: Error?
        /// Optional hook invoked at the start of `aggregate()`, on the main actor.
        var onAggregate: (@MainActor () -> Void)?
        func validate() throws { if let validateError { throw validateError } }
        func aggregate() async throws -> [AggregatedArticle] {
            await onAggregate?()
            return articles
        }
    }

    nonisolated private func aggregated(_ id: String, date: Date = .now) -> AggregatedArticle {
        AggregatedArticle(title: id, identifier: id, url: id, rawContent: "", content: "c", date: date, author: "", iconURL: nil)
    }

    @Test func updateAllImportsArticlesFromEnabledFeedsOnly() async throws {
        let context = try makeContext()
        let enabled = Feed(name: "A", aggregatorType: .feedContent, identifier: "a")
        let disabled = Feed(name: "B", aggregatorType: .feedContent, identifier: "b", enabled: false)
        context.insert(enabled); context.insert(disabled)
        try context.save()

        let enabledID = enabled.persistentModelID
        let service = AggregationService(context: context) { _, _ in
            FakeAggregator(articles: [self.aggregated("x1"), self.aggregated("x2")])
        }
        await service.updateAll()

        #expect(service.isUpdating == false)
        #expect(articles(context, feed: "a").count == 2)
        #expect(articles(context, feed: "b").isEmpty)
        let ef = refetch(context, feed: enabledID)
        #expect(ef?.lastFetchedAt != nil)
        #expect(ef?.lastError == nil)
    }

    @Test func runCapLimitsImportedArticles() async throws {
        let context = try makeContext()
        let feed = Feed(name: "A", aggregatorType: .feedContent, identifier: "a", dailyLimit: 2)
        context.insert(feed)
        try context.save()

        let service = AggregationService(context: context) { _, _ in
            FakeAggregator(articles: [self.aggregated("1"), self.aggregated("2"), self.aggregated("3")])
        }
        await service.update(feed: feed)

        #expect(articles(context, feed: "a").count == 2)
    }

    @Test func dropsArticlesOlderThanIntakeWindow() async throws {
        let context = try makeContext()
        let feed = Feed(name: "A", aggregatorType: .feedContent, identifier: "a")
        context.insert(feed)
        try context.save()
        let old = aggregated("old", date: Date.now.addingTimeInterval(-61 * 24 * 3600))

        let service = AggregationService(context: context) { _, _ in
            FakeAggregator(articles: [self.aggregated("fresh"), old])
        }
        await service.update(feed: feed)

        #expect(articles(context, feed: "a").map(\.identifier) == ["fresh"])
    }

    @Test func feedFailureIsIsolatedAndRecorded() async throws {
        let context = try makeContext()
        let bad = Feed(name: "bad", aggregatorType: .feedContent, identifier: "bad")
        let good = Feed(name: "good", aggregatorType: .feedContent, identifier: "good")
        context.insert(bad); context.insert(good)
        try context.save()

        let badID = bad.persistentModelID
        let goodID = good.persistentModelID
        let service = AggregationService(context: context) { config, _ in
            if config.identifier == "bad" {
                return FakeAggregator(articles: [], validateError: AggregatorError.missingIdentifier)
            }
            return FakeAggregator(articles: [self.aggregated("g1")])
        }
        await service.updateAll()

        let b = refetch(context, feed: badID)
        #expect(b?.lastError != nil)
        #expect(articles(context, feed: "good").count == 1)        // one feed's failure didn't abort the run
        let g = refetch(context, feed: goodID)
        #expect(g?.lastError == nil)
    }

    @Test func missingAggregatorRecordsError() async throws {
        let context = try makeContext()
        let feed = Feed(name: "A", aggregatorType: .reddit, identifier: "swift")
        context.insert(feed)
        try context.save()

        // Default factory (registry) returns nil until Phase 4b.
        // Reddit is OFF by default; enable it so the source gate is passed and
        // the missing-aggregator path is exercised instead of the early-return.
        let feedID = feed.persistentModelID
        let settings = AppSettings(defaults: freshDefaults())
        settings.redditEnabled = true
        let service = AggregationService(context: context, settings: settings)
        await service.update(feed: feed)

        let f = refetch(context, feed: feedID)
        #expect(f?.lastError != nil)
        #expect(articles(context, feed: "swift").isEmpty)
    }

    // MARK: - AI wiring (Phase 4f)

    /// Fake processor: records what it received and returns a scripted transform.
    private final class FakeAIProcessor: AIProcessing, @unchecked Sendable {
        var received: [AggregatedArticle] = []       // last call's input
        var receivedAll: [AggregatedArticle] = []    // every article seen across calls (per-article pipeline)
        var receivedAI: AIOptions?
        let transform: @Sendable ([AggregatedArticle]) -> [AggregatedArticle]
        init(transform: @escaping @Sendable ([AggregatedArticle]) -> [AggregatedArticle] = { $0 }) {
            self.transform = transform
        }
        func process(_ input: [AggregatedArticle], ai: AIOptions) async -> [AggregatedArticle] {
            received = input
            receivedAll.append(contentsOf: input)
            receivedAI = ai
            return transform(input)
        }
    }

    @Test func aiProcessorRunsAfterCapAndBeforeUpsert() async throws {
        let context = try makeContext()
        // dailyLimit 2 so the cap trims the 3 fetched down to 2 BEFORE the processor sees them.
        let feed = Feed(name: "A", aggregatorType: .feedContent, identifier: "a", dailyLimit: 2)
        context.insert(feed)
        try context.save()

        let fake = FakeAIProcessor()    // identity transform
        let service = AggregationService(
            context: context,
            makeAggregator: { _, _ in
                FakeAggregator(articles: [self.aggregated("1"), self.aggregated("2"), self.aggregated("3")])
            },
            aiProcessor: fake
        )
        await service.update(feed: feed)

        // Per-article pipeline: the processor is invoked once per article (not one batch), and the
        // cap stops the run after 2 — so article "3" is never fetched, processed, or upserted.
        #expect(fake.receivedAll.count == 2)                    // processed the capped 2, not 3
        #expect(fake.receivedAll.map { $0.identifier } == ["1", "2"])
        #expect(articles(context, feed: "a").count == 2)
    }

    @Test func aiProcessorOutputIsWhatGetsUpserted() async throws {
        let context = try makeContext()
        let feed = Feed(name: "A", aggregatorType: .feedContent, identifier: "a")
        context.insert(feed)
        try context.save()

        // Processor drops "drop" and rewrites "keep"'s title.
        let fake = FakeAIProcessor { input in
            input.compactMap { a in
                guard a.identifier != "drop" else { return nil }
                var copy = a
                copy.title = "AI:\(a.title)"
                return copy
            }
        }
        let service = AggregationService(
            context: context,
            makeAggregator: { _, _ in
                FakeAggregator(articles: [self.aggregated("keep"), self.aggregated("drop")])
            },
            aiProcessor: fake
        )
        await service.update(feed: feed)

        let fetched = articles(context, feed: "a")
        #expect(fetched.map { $0.identifier } == ["keep"])    // dropped article never upserted
        #expect(fetched.first?.title == "AI:keep")        // AI transform persisted
    }

    /// Per-article durability: an aggregator that hands two articles to the sink and is then
    /// interrupted (the run errors out) must keep those two — they were each saved before the next
    /// was collected — rather than losing the whole batch.
    @Test func interruptedRunKeepsArticlesSavedBeforeFailure() async throws {
        struct InterruptedAggregator: Aggregator {
            let yield: [AggregatedArticle]
            func validate() throws {}
            func aggregate() async throws -> [AggregatedArticle] {
                var collected: [AggregatedArticle] = []
                try await aggregate { collected.append($0) }
                return collected
            }
            func aggregate(_ sink: sending (AggregatedArticle) async throws -> Void) async throws {
                for article in yield { try await sink(article) }
                throw URLError(.cancelled)        // window expired after handing off `yield`
            }
        }

        let context = try makeContext()
        let feed = Feed(name: "A", aggregatorType: .feedContent, identifier: "a", dailyLimit: 10)
        context.insert(feed)
        try context.save()
        let feedID = feed.persistentModelID
        let service = AggregationService(
            context: context,
            makeAggregator: { _, _ in InterruptedAggregator(yield: [self.aggregated("a1"), self.aggregated("a2")]) }
        )

        let inserted = await service.update(feed: feed)

        #expect(inserted == 2)
        #expect(articles(context, feed: "a").map(\.identifier).sorted() == ["a1", "a2"])   // saved despite the failure
        let f = refetch(context, feed: feedID)
        #expect(f?.lastError == nil)                                       // cancellation isn't a failure
    }

    @Test func aiProcessorReceivesFeedsAIOptions() async throws {
        let context = try makeContext()
        var options = FeedContentOptions()
        options.ai = AIOptions(summarize: true, improveWriting: false, translate: true, translateLanguage: "German")
        let feed = Feed(name: "A", aggregatorType: .feedContent, identifier: "a")
        feed.options = .feedContent(options)
        context.insert(feed)

        let fake = FakeAIProcessor()
        let service = AggregationService(
            context: context,
            makeAggregator: { _, _ in FakeAggregator(articles: [self.aggregated("x")]) },
            aiProcessor: fake
        )
        await service.update(feed: feed)

        #expect(fake.receivedAI?.summarize == true)
        #expect(fake.receivedAI?.translate == true)
        #expect(fake.receivedAI?.translateLanguage == "German")
    }

    @Test func updateAllReturnsTotalInsertedCount() async throws {
        let context = try makeContext()
        let a = Feed(name: "A", aggregatorType: .feedContent, identifier: "a")
        let b = Feed(name: "B", aggregatorType: .feedContent, identifier: "b")
        context.insert(a); context.insert(b)

        let service = AggregationService(context: context) { _, _ in
            FakeAggregator(articles: [self.aggregated("x1"), self.aggregated("x2")])
        }
        let inserted = await service.updateAll()
        #expect(inserted == 4)
    }

    /// Fake aggregator that yields/sleeps before returning, so multiple invocations
    /// interleave their suspension points under the concurrent `updateAll` path.
    private struct SlowFakeAggregator: Aggregator {
        let articles: [AggregatedArticle]
        func validate() throws {}
        func aggregate() async throws -> [AggregatedArticle] {
            try? await Task.sleep(nanoseconds: 5_000_000) // 5ms
            return articles
        }
    }

    @Test func updateAllAggregatesFeedsConcurrentlyWithCorrectCounts() async throws {
        let context = try makeContext()
        // More feeds than the bounded-concurrency window to exercise the sliding window.
        let feeds = (0..<12).map { i -> Feed in
            let feed = Feed(name: "F\(i)", aggregatorType: .feedContent, identifier: "f\(i)")
            context.insert(feed)
            return feed
        }
        try context.save()
        let feedIDs = feeds.map(\.persistentModelID)

        // Each feed gets a distinct number of articles: feed i -> i+1 articles.
        let service = AggregationService(context: context) { config, _ in
            let count = (Int(config.identifier.dropFirst()) ?? 0) + 1
            let articles = (0..<count).map { self.aggregated("\(config.identifier)-\($0)") }
            return SlowFakeAggregator(articles: articles)
        }

        let inserted = await service.updateAll()

        #expect(service.isUpdating == false)
        let expectedTotal = (1...12).reduce(0, +) // 78
        #expect(inserted == expectedTotal)
        for (i, id) in feedIDs.enumerated() {
            #expect(articles(context, feed: "f\(i)").count == i + 1)
            let f = refetch(context, feed: id)
            #expect(f?.lastError == nil)
            #expect(f?.lastFetchedAt != nil)
        }
    }

    @Test func updateAllReturnsZeroWhenNothingNew() async throws {
        let context = try makeContext()
        let feed = Feed(name: "A", aggregatorType: .feedContent, identifier: "a")
        context.insert(feed)
        let service = AggregationService(context: context) { _, _ in
            FakeAggregator(articles: [self.aggregated("x1")])
        }
        _ = await service.updateAll()
        let second = await service.updateAll()
        #expect(second == 0)
    }

    // MARK: - Off-main block parsing (background-refresh lag)

    /// The heavy SwiftSoup HTML → `[Block]` parse now runs off the main actor before the on-main
    /// upsert, so it can't stutter the reader during a refresh. Verify the helper still produces the
    /// same blocks `BlockParser` does, keyed by identifier.
    @Test func parseBlocksMatchesBlockParserKeyedByIdentifier() async {
        let a = AggregatedArticle(title: "A", identifier: "id-a", url: "https://x/a", rawContent: "",
                                  content: "<p>Hello <b>world</b></p>", date: .now, author: "", iconURL: nil)
        let b = AggregatedArticle(title: "B", identifier: "id-b", url: "https://x/b", rawContent: "",
                                  content: "<h2>Heading</h2>", date: .now, author: "", iconURL: nil)

        let parsed = await AggregationService.parseBlocks([a, b])

        #expect(parsed["id-a"] == BlockParser.blocks(fromHTML: a.content, baseURL: URL(string: a.url)))
        #expect(parsed["id-b"] == BlockParser.blocks(fromHTML: b.content, baseURL: URL(string: b.url)))
    }

    /// End-to-end: a bulk `updateAll()` run must still populate each imported article's native body
    /// (the off-main parse feeds the on-main upsert), not just insert empty rows.
    @Test func updateAllPopulatesArticleBodyViaOffMainParse() async throws {
        let context = try makeContext()
        let feed = Feed(name: "A", aggregatorType: .feedContent, identifier: "a")
        context.insert(feed)
        try context.save()

        var item = self.aggregated("x1")
        item.content = "<p>Body text</p>"
        let article = item
        let service = AggregationService(context: context) { _, _ in
            FakeAggregator(articles: [article])
        }
        await service.updateAll()

        let fetched = articles(context, feed: "a")
        #expect(fetched.count == 1)
        #expect(fetched.first?.plainText.contains("Body text") == true)
    }

    // MARK: - User-facing error messages

    @Test func userFacingMessageUsesLocalizedErrorDescription() {
        let error = AggregatorError.missingIdentifier
        #expect(AggregationService.userFacingMessage(for: error) == error.errorDescription)
    }

    @Test func userFacingMessageUsesURLErrorLocalizedDescription() {
        let error = URLError(.notConnectedToInternet)
        #expect(AggregationService.userFacingMessage(for: error) == error.localizedDescription)
    }

    @Test func userFacingMessageFallsBackForBareError() {
        struct Bare: Error {}
        #expect(AggregationService.userFacingMessage(for: Bare())
                == String(localized: "An unexpected error occurred."))
    }

    // MARK: - Per-run failure tracking

    @Test func updateAllRecordsFailureWithFeedNameAndMessage() async throws {
        let context = try makeContext()
        let bad = Feed(name: "Bad Feed", aggregatorType: .feedContent, identifier: "bad")
        context.insert(bad)
        let service = AggregationService(context: context) { _, _ in
            FakeAggregator(articles: [], validateError: AggregatorError.missingIdentifier)
        }
        await service.updateAll()

        #expect(service.lastRunFailures.count == 1)
        #expect(service.lastRunFailures.first?.feedName == "Bad Feed")
        #expect(service.lastRunFailures.first?.message == AggregatorError.missingIdentifier.errorDescription)
    }

    @Test func successfulRunLeavesNoFailures() async throws {
        let context = try makeContext()
        let feed = Feed(name: "A", aggregatorType: .feedContent, identifier: "a")
        context.insert(feed)
        let service = AggregationService(context: context) { _, _ in
            FakeAggregator(articles: [self.aggregated("x")])
        }
        await service.updateAll()
        #expect(service.lastRunFailures.isEmpty)
    }

    @Test func laterSuccessfulRunClearsPriorFailures() async throws {
        final class Toggle: @unchecked Sendable { var fail = true }
        let toggle = Toggle()
        let context = try makeContext()
        let feed = Feed(name: "A", aggregatorType: .feedContent, identifier: "a")
        context.insert(feed)
        let service = AggregationService(context: context) { _, _ in
            toggle.fail
                ? FakeAggregator(articles: [], validateError: AggregatorError.missingIdentifier)
                : FakeAggregator(articles: [self.aggregated("x")])
        }
        await service.update(feed: feed)
        #expect(service.lastRunFailures.count == 1)
        toggle.fail = false
        await service.update(feed: feed)
        #expect(service.lastRunFailures.isEmpty)
    }

    @Test func missingAggregatorRecordsFailure() async throws {
        let context = try makeContext()
        let feed = Feed(name: "No Aggregator", aggregatorType: .feedContent, identifier: "x")
        context.insert(feed)
        try context.save()
        let feedID = feed.persistentModelID
        // Factory returns nil → exercises the `notImplemented` guard's failure-recording path.
        let service = AggregationService(context: context) { _, _ in nil }
        await service.update(feed: feed)

        #expect(service.lastRunFailures.count == 1)
        #expect(service.lastRunFailures.first?.feedName == "No Aggregator")
        let f = refetch(context, feed: feedID)
        #expect(f?.lastError != nil)
    }

    // MARK: - Force reload

    @Test func forceReloadBypassesIntakeWindow() async throws {
        let context = try makeContext()
        let feed = Feed(name: "A", aggregatorType: .feedContent, identifier: "a")
        context.insert(feed)
        try context.save()
        let old = aggregated("old", date: Date.now.addingTimeInterval(-200 * 24 * 3600))

        let service = AggregationService(context: context) { _, _ in
            FakeAggregator(articles: [self.aggregated("fresh"), old])
        }
        let inserted = await service.forceReload(feed: feed)

        #expect(inserted == 2)
        #expect(Set(articles(context, feed: "a").map(\.identifier)) == ["fresh", "old"])  // old NOT dropped
        #expect(service.isUpdating == false)
    }

    @Test func forceReloadBypassesDailyCap() async throws {
        let context = try makeContext()
        let feed = Feed(name: "A", aggregatorType: .feedContent, identifier: "a", dailyLimit: 2)
        context.insert(feed)
        try context.save()

        let service = AggregationService(context: context) { _, _ in
            FakeAggregator(articles: [self.aggregated("1"), self.aggregated("2"), self.aggregated("3")])
        }
        await service.forceReload(feed: feed)

        #expect(articles(context, feed: "a").count == 3)  // cap of 2 ignored under force
    }

    @Test func normalUpdateStillAppliesWindowAndCap() async throws {
        let context = try makeContext()
        let feed = Feed(name: "A", aggregatorType: .feedContent, identifier: "a", dailyLimit: 2)
        context.insert(feed)
        try context.save()
        let old = aggregated("old", date: Date.now.addingTimeInterval(-200 * 24 * 3600))

        let service = AggregationService(context: context) { _, _ in
            FakeAggregator(articles: [self.aggregated("1"), self.aggregated("2"), self.aggregated("3"), old])
        }
        await service.update(feed: feed)

        let fetched = articles(context, feed: "a")
        #expect(fetched.count == 2)                       // cap still applies
        #expect(!fetched.map(\.identifier).contains("old"))  // window still applies
    }

    // MARK: - Force reload article

    /// Fake whose `refetch` returns a scripted article (or nil to force the fallback path).
    private struct RefetchFakeAggregator: Aggregator {
        let articles: [AggregatedArticle]
        let refetchResult: AggregatedArticle?
        func validate() throws {}
        func aggregate() async throws -> [AggregatedArticle] { articles }
        func refetch(_ seed: AggregatedArticle) async throws -> AggregatedArticle? { refetchResult }
    }

    /// Fake whose `refetch` mirrors the real aggregators (e.g. `FullWebsiteAggregator.enrich`):
    /// it mutates the seed's content and returns the *same* struct, so every other seed field
    /// (including the carried `summary`) rides through unchanged.
    private struct EchoRefetchAggregator: Aggregator {
        func validate() throws {}
        func aggregate() async throws -> [AggregatedArticle] { [] }
        func refetch(_ seed: AggregatedArticle) async throws -> AggregatedArticle? {
            var refreshed = seed
            refreshed.content = "REFRESHED"
            return refreshed
        }
    }

    @Test func forceReloadArticleClearsStaleSummaryWhenReprocessProducesNone() async throws {
        let context = try makeContext()
        let feed = Feed(name: "A", aggregatorType: .fullWebsite, identifier: "a")
        context.insert(feed)
        let article = Article(title: "Old", identifier: "id1", url: "https://x/1",
                              date: .now, author: "", iconURL: nil,
                              summary: "STALE SUMMARY")
        article.feed = feed
        context.insert(article)
        try context.save()

        let articleID = article.persistentModelID
        // Identity AI transform models a run that no longer summarizes (e.g. translate-only):
        // the processor leaves the carried summary untouched. The stale summary must NOT survive.
        let service = AggregationService(context: context, makeAggregator: { _, _ in
            EchoRefetchAggregator()
        }, aiProcessor: FakeAIProcessor())
        await service.forceReload(article: article)

        let a = context.model(for: articleID) as? Article
        #expect(a?.plainText == "REFRESHED")   // content refreshed via refetch (now native blocks)
        #expect(a?.summary == "")             // derived AI summary cleared, not carried over
    }

    @Test func forceReloadArticleRefreshesContentPreservingIdentity() async throws {
        let context = try makeContext()
        let starred = try #require((try? context.fetch(FetchDescriptor<Yana.Tag>()))?.first { $0.isBuiltIn })
        let feed = Feed(name: "A", aggregatorType: .feedContent, identifier: "a")
        context.insert(feed)
        let article = Article(title: "Old", identifier: "id1", url: "https://x/1",
                              date: .now, author: "", iconURL: nil)
        article.feed = feed
        let pinnedCreatedAt = Date.now.addingTimeInterval(-90 * 24 * 3600)
        article.createdAt = pinnedCreatedAt
        article.setStarred(true, using: starred)
        context.insert(article)
        try context.save()

        let articleID = article.persistentModelID
        let refreshed = self.aggregated("id1")          // same identifier, content "c"
        let service = AggregationService(context: context, makeAggregator: { _, _ in
            RefetchFakeAggregator(articles: [], refetchResult: refreshed)
        }, aiProcessor: FakeAIProcessor())
        await service.forceReload(article: article)

        let a = context.model(for: articleID) as? Article
        #expect(a?.plainText == "c")               // content refreshed (now native blocks)
        #expect(a?.createdAt == pinnedCreatedAt)    // timeline position preserved
        #expect(a?.isStarred == true)                       // Starred preserved
        #expect(articles(context, feed: "a").count == 1)                // updated, not duplicated
    }

    @Test func forceReloadArticleDoesNotReloadFeedWhenRefetchReturnsNil() async throws {
        let context = try makeContext()
        let feed = Feed(name: "A", aggregatorType: .feedContent, identifier: "a")
        context.insert(feed)
        let article = Article(title: "Old", identifier: "id1", url: "https://x/1",
                              date: .now, author: "", iconURL: nil)
        article.feed = feed
        context.insert(article)
        try context.save()

        let articleID = article.persistentModelID
        // refetch returns nil, and the aggregator also offers a feed article — which must NOT be imported.
        var feedOnly = self.aggregated("id1"); feedOnly.content = "FROM_FEED"
        let feedArticle = feedOnly
        let service = AggregationService(context: context, makeAggregator: { _, _ in
            RefetchFakeAggregator(articles: [feedArticle], refetchResult: nil)
        }, aiProcessor: FakeAIProcessor())
        let inserted = await service.forceReload(article: article)

        #expect(inserted == 0)                       // nothing reloaded
        let a = context.model(for: articleID) as? Article
        #expect(a?.plainText.isEmpty == true)           // current article untouched (no feed reload)
        #expect(articles(context, feed: "a").count == 1)            // no extra articles imported
    }

    @Test func forceReloadArticleReturnsZeroWhenAggregatorUnavailable() async throws {
        let context = try makeContext()
        let feed = Feed(name: "A", aggregatorType: .feedContent, identifier: "a")
        context.insert(feed)
        let article = Article(title: "Old", identifier: "id1", url: "https://x/1",
                              date: .now, author: "", iconURL: nil)
        article.feed = feed
        context.insert(article)
        try context.save()

        let articleID = article.persistentModelID
        let service = AggregationService(context: context, makeAggregator: { _, _ in nil },
                                         aiProcessor: FakeAIProcessor())
        let inserted = await service.forceReload(article: article)

        #expect(inserted == 0)
        let a = context.model(for: articleID) as? Article
        #expect(a?.plainText.isEmpty == true)
    }

    @Test func forceReloadDoesNotRetentionCleanupRefreshedArticles() async throws {
        let context = try makeContext()
        let feed = Feed(name: "A", aggregatorType: .feedContent, identifier: "a")
        context.insert(feed)
        // Un-starred article discovered far beyond the default 30-day retention window.
        let article = Article(title: "Old", identifier: "id1", url: "https://x/1",
                              date: .now, author: "", iconURL: nil)
        article.feed = feed
        article.createdAt = Date.now.addingTimeInterval(-40 * 24 * 3600)
        context.insert(article)
        try context.save()

        let service = AggregationService(context: context, makeAggregator: { _, _ in
            FakeAggregator(articles: [self.aggregated("id1")])   // same identifier → in-place refresh
        }, aiProcessor: FakeAIProcessor())
        await service.forceReload(feed: feed)

        let fetched = articles(context, feed: "a")
        #expect(fetched.map(\.identifier) == ["id1"])   // survived retention cleanup
        #expect(fetched.first?.plainText == "c")        // and was refreshed (now native blocks)
    }

    @Test func forceReloadArticleReturnsZeroWithoutFeed() async throws {
        let context = try makeContext()
        let article = Article(title: "Orphan", identifier: "id1", url: "u",
                              date: .now, author: "", iconURL: nil)
        context.insert(article)
        let service = AggregationService(context: context) { _, _ in FakeAggregator(articles: []) }
        let inserted = await service.forceReload(article: article)
        #expect(inserted == 0)
    }

    // MARK: - Source toggle (Task 2)

    private func freshDefaults() -> UserDefaults {
        UserDefaults(suiteName: "AggregationServiceTests.\(UUID().uuidString)")!
    }

    @Test func updateAllSkipsFeedsOfDisabledSource() async throws {
        let context = try makeContext()
        let rss = Feed(name: "rss", aggregatorType: .feedContent, identifier: "a")
        let reddit = Feed(name: "r", aggregatorType: .reddit, identifier: "swift")
        context.insert(rss); context.insert(reddit)
        try context.save()

        let redditID = reddit.persistentModelID
        // Reddit toggle off (default) -> reddit feed skipped.
        let settings = AppSettings(defaults: freshDefaults())
        let service = AggregationService(
            context: context,
            makeAggregator: { _, _ in FakeAggregator(articles: [self.aggregated("x1")]) },
            settings: settings
        )
        await service.updateAll()

        #expect(articles(context, feed: "a").count == 1)
        #expect(articles(context, feed: "swift").isEmpty)
        let r = refetch(context, feed: redditID)
        #expect(r?.lastError == nil)
    }

    @Test func updateFeedSkipsDisabledSourceWithoutError() async throws {
        let context = try makeContext()
        let reddit = Feed(name: "r", aggregatorType: .reddit, identifier: "swift")
        context.insert(reddit)
        try context.save()

        let redditID = reddit.persistentModelID
        let settings = AppSettings(defaults: freshDefaults()) // reddit off
        let service = AggregationService(
            context: context,
            makeAggregator: { _, _ in FakeAggregator(articles: [self.aggregated("x1")]) },
            settings: settings
        )
        let inserted = await service.update(feed: reddit)

        #expect(inserted == 0)
        #expect(articles(context, feed: "swift").isEmpty)
        let r = refetch(context, feed: redditID)
        #expect(r?.lastError == nil)
        #expect(r?.lastFetchedAt == nil)
    }

    @Test func updateFeedRunsWhenSourceEnabled() async throws {
        let context = try makeContext()
        let reddit = Feed(name: "r", aggregatorType: .reddit, identifier: "swift")
        context.insert(reddit)
        try context.save()

        let redditID = reddit.persistentModelID
        let settings = AppSettings(defaults: freshDefaults())
        settings.redditEnabled = true
        let service = AggregationService(
            context: context,
            makeAggregator: { _, _ in FakeAggregator(articles: [self.aggregated("x1")]) },
            settings: settings
        )
        let inserted = await service.update(feed: reddit)

        #expect(inserted == 1)
        #expect(articles(context, feed: "swift").count == 1)
    }

    // MARK: - Logo resolution (Task 10)

    @Test func setsLogoHashWhenMissing() async throws {
        let context = try makeContext()
        let feed = Feed(name: "A", aggregatorType: .feedContent, identifier: "https://e.com/f.xml")
        context.insert(feed)
        try context.save()

        let feedID = feed.persistentModelID
        let service = AggregationService(
            context: context,
            makeAggregator: { _, _ in FakeAggregator(articles: [self.aggregated("x1")]) },
            logoResolver: { _, _ in "cafef00d" })
        await service.update(feed: feed)

        let f = refetch(context, feed: feedID)
        #expect(f?.logoHash == "cafef00d")
    }

    @Test func doesNotReResolveLogoWhenAlreadySet() async throws {
        let context = try makeContext()
        let feed = Feed(name: "A", aggregatorType: .feedContent, identifier: "https://e.com/f.xml")
        feed.logoHash = "existing"
        context.insert(feed)
        try context.save()

        let feedID = feed.persistentModelID
        let service = AggregationService(
            context: context,
            makeAggregator: { _, _ in FakeAggregator(articles: [self.aggregated("x1")]) },
            logoResolver: { _, _ in "newvalue" })
        await service.update(feed: feed)

        let f = refetch(context, feed: feedID)
        #expect(f?.logoHash == "existing")
    }

    // MARK: - Update progress (Task 9)

    /// Box to observe a value captured on the main actor inside a factory closure.
    private final class Box<T>: @unchecked Sendable {
        var value: T
        init(_ value: T) { self.value = value }
    }

    @Test func updateAllReportsProgressThenResets() async throws {
        let context = try makeContext()
        // Seed 3 enabled feeds.
        for i in 0..<3 {
            context.insert(Feed(name: "F\(i)", aggregatorType: .feedContent, identifier: "f\(i)"))
        }

        let totalBox = Box(0)
        // Use `nonisolated(unsafe)` to let the closure capture `service` before it is initialised;
        // the closure is only *called* during `updateAll()`, after the `let service = …` line
        // completes, so the reference is always valid by the time it is read.
        nonisolated(unsafe) var serviceRef: AggregationService? = nil
        let service = AggregationService(
            context: context,
            makeAggregator: { _, _ in
                FakeAggregator(
                    articles: [],
                    onAggregate: { totalBox.value = serviceRef?.updateProgress.total ?? -1 }
                )
            }
        )
        serviceRef = service

        await service.updateAll()

        #expect(totalBox.value == 3)               // total was live during the run
        #expect(service.updateProgress.total == 0)     // reset to idle afterward
        #expect(service.updateProgress.completed == 0)
    }
}
