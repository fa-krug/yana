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

    /// Fake aggregator returning canned articles (no network).
    private struct FakeAggregator: Aggregator {
        let articles: [AggregatedArticle]
        var validateError: Error?
        func validate() throws { if let validateError { throw validateError } }
        func aggregate() async throws -> [AggregatedArticle] { articles }
    }

    nonisolated private func aggregated(_ id: String, date: Date = .now) -> AggregatedArticle {
        AggregatedArticle(title: id, identifier: id, url: id, rawContent: "", content: "c", date: date, author: "", iconURL: nil)
    }

    @Test func updateAllImportsArticlesFromEnabledFeedsOnly() async throws {
        let context = try makeContext()
        let enabled = Feed(name: "A", aggregatorType: .feedContent, identifier: "a")
        let disabled = Feed(name: "B", aggregatorType: .feedContent, identifier: "b", enabled: false)
        context.insert(enabled); context.insert(disabled)

        let service = AggregationService(context: context) { _, _ in
            FakeAggregator(articles: [self.aggregated("x1"), self.aggregated("x2")])
        }
        await service.updateAll()

        #expect(service.isUpdating == false)
        #expect(enabled.articles.count == 2)
        #expect(disabled.articles.isEmpty)
        #expect(enabled.lastFetchedAt != nil)
        #expect(enabled.lastError == nil)
    }

    @Test func runCapLimitsImportedArticles() async throws {
        let context = try makeContext()
        let feed = Feed(name: "A", aggregatorType: .feedContent, identifier: "a", dailyLimit: 2)
        context.insert(feed)

        let service = AggregationService(context: context) { _, _ in
            FakeAggregator(articles: [self.aggregated("1"), self.aggregated("2"), self.aggregated("3")])
        }
        await service.update(feed: feed)

        #expect(feed.articles.count == 2)
    }

    @Test func dropsArticlesOlderThanIntakeWindow() async throws {
        let context = try makeContext()
        let feed = Feed(name: "A", aggregatorType: .feedContent, identifier: "a")
        context.insert(feed)
        let old = aggregated("old", date: Date.now.addingTimeInterval(-61 * 24 * 3600))

        let service = AggregationService(context: context) { _, _ in
            FakeAggregator(articles: [self.aggregated("fresh"), old])
        }
        await service.update(feed: feed)

        #expect(feed.articles.map(\.identifier) == ["fresh"])
    }

    @Test func feedFailureIsIsolatedAndRecorded() async throws {
        let context = try makeContext()
        let bad = Feed(name: "bad", aggregatorType: .feedContent, identifier: "bad")
        let good = Feed(name: "good", aggregatorType: .feedContent, identifier: "good")
        context.insert(bad); context.insert(good)

        let service = AggregationService(context: context) { config, _ in
            if config.identifier == "bad" {
                return FakeAggregator(articles: [], validateError: AggregatorError.missingIdentifier)
            }
            return FakeAggregator(articles: [self.aggregated("g1")])
        }
        await service.updateAll()

        #expect(bad.lastError != nil)
        #expect(good.articles.count == 1)        // one feed's failure didn't abort the run
        #expect(good.lastError == nil)
    }

    @Test func missingAggregatorRecordsError() async throws {
        let context = try makeContext()
        let feed = Feed(name: "A", aggregatorType: .reddit, identifier: "swift")
        context.insert(feed)

        // Default factory (registry) returns nil until Phase 4b.
        let service = AggregationService(context: context)
        await service.update(feed: feed)

        #expect(feed.lastError != nil)
        #expect(feed.articles.isEmpty)
    }

    // MARK: - AI wiring (Phase 4f)

    /// Fake processor: records what it received and returns a scripted transform.
    private final class FakeAIProcessor: AIProcessing, @unchecked Sendable {
        var received: [AggregatedArticle] = []
        var receivedAI: AIOptions?
        let transform: @Sendable ([AggregatedArticle]) -> [AggregatedArticle]
        init(transform: @escaping @Sendable ([AggregatedArticle]) -> [AggregatedArticle] = { $0 }) {
            self.transform = transform
        }
        func process(_ input: [AggregatedArticle], ai: AIOptions) async -> [AggregatedArticle] {
            received = input
            receivedAI = ai
            return transform(input)
        }
    }

    @Test func aiProcessorRunsAfterCapAndBeforeUpsert() async throws {
        let context = try makeContext()
        // dailyLimit 2 so the cap trims the 3 fetched down to 2 BEFORE the processor sees them.
        let feed = Feed(name: "A", aggregatorType: .feedContent, identifier: "a", dailyLimit: 2)
        context.insert(feed)

        let fake = FakeAIProcessor()    // identity transform
        let service = AggregationService(
            context: context,
            makeAggregator: { _, _ in
                FakeAggregator(articles: [self.aggregated("1"), self.aggregated("2"), self.aggregated("3")])
            },
            aiProcessor: fake
        )
        await service.update(feed: feed)

        #expect(fake.received.count == 2)                       // saw the capped list, not 3
        #expect(fake.received.map { $0.identifier } == ["1", "2"])
        #expect(feed.articles.count == 2)
    }

    @Test func aiProcessorOutputIsWhatGetsUpserted() async throws {
        let context = try makeContext()
        let feed = Feed(name: "A", aggregatorType: .feedContent, identifier: "a")
        context.insert(feed)

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

        #expect(feed.articles.map { $0.identifier } == ["keep"])    // dropped article never upserted
        #expect(feed.articles.first?.title == "AI:keep")        // AI transform persisted
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
        for (i, feed) in feeds.enumerated() {
            #expect(feed.articles.count == i + 1)
            #expect(feed.lastError == nil)
            #expect(feed.lastFetchedAt != nil)
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
        // Factory returns nil → exercises the `notImplemented` guard's failure-recording path.
        let service = AggregationService(context: context) { _, _ in nil }
        await service.update(feed: feed)

        #expect(service.lastRunFailures.count == 1)
        #expect(service.lastRunFailures.first?.feedName == "No Aggregator")
        #expect(feed.lastError != nil)
    }

    // MARK: - Force reload

    @Test func forceReloadBypassesIntakeWindow() async throws {
        let context = try makeContext()
        let feed = Feed(name: "A", aggregatorType: .feedContent, identifier: "a")
        context.insert(feed)
        let old = aggregated("old", date: Date.now.addingTimeInterval(-200 * 24 * 3600))

        let service = AggregationService(context: context) { _, _ in
            FakeAggregator(articles: [self.aggregated("fresh"), old])
        }
        let inserted = await service.forceReload(feed: feed)

        #expect(inserted == 2)
        #expect(Set(feed.articles.map(\.identifier)) == ["fresh", "old"])  // old NOT dropped
        #expect(service.isUpdating == false)
    }

    @Test func forceReloadBypassesDailyCap() async throws {
        let context = try makeContext()
        let feed = Feed(name: "A", aggregatorType: .feedContent, identifier: "a", dailyLimit: 2)
        context.insert(feed)

        let service = AggregationService(context: context) { _, _ in
            FakeAggregator(articles: [self.aggregated("1"), self.aggregated("2"), self.aggregated("3")])
        }
        await service.forceReload(feed: feed)

        #expect(feed.articles.count == 3)  // cap of 2 ignored under force
    }

    @Test func normalUpdateStillAppliesWindowAndCap() async throws {
        let context = try makeContext()
        let feed = Feed(name: "A", aggregatorType: .feedContent, identifier: "a", dailyLimit: 2)
        context.insert(feed)
        let old = aggregated("old", date: Date.now.addingTimeInterval(-200 * 24 * 3600))

        let service = AggregationService(context: context) { _, _ in
            FakeAggregator(articles: [self.aggregated("1"), self.aggregated("2"), self.aggregated("3"), old])
        }
        await service.update(feed: feed)

        #expect(feed.articles.count == 2)                       // cap still applies
        #expect(!feed.articles.map(\.identifier).contains("old"))  // window still applies
    }
}
