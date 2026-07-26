import Foundation
import SwiftData

enum AggregationProgress: Sendable { case start(total: Int); case advance }

struct AggregationRunInputs: Sendable {
    let makeAggregator: AggregatorFactory
    let processor: any AIProcessing
    let logoResolver: AggregationService.LogoResolver
    let credentials: AggregatorCredentials
    let now: Date
    let starredIdentifiers: @Sendable (_ feedIdentifier: String, _ aggregatorType: String) -> Set<String>
    let canonicalCreatedAt: [String: Date]
    let isSourceEnabled: @Sendable (AggregatorType) -> Bool
    let retentionDays: Int
    let skipRetention: Bool
    let progress: @Sendable (AggregationProgress) -> Void
}

struct AggregationRunResult: Sendable {
    var inserted: Int = 0
    var failures: [AggregationService.FeedFailure] = []
    var touchedUIDs: Set<String> = []
    var deletedUIDs: [String] = []
}

/// Runs the aggregation write path off the main actor in its own `ModelContext`. Everything the
/// old `AggregationService.aggregate(feed:)` did on the main context happens here instead; only
/// `Sendable` values cross the boundary (see `AggregationRunInputs`/`AggregationRunResult`).
@ModelActor
actor AggregationWriter {
    private static let maxConcurrentFeedUpdates = 5
    private struct CapReached: Error {}

    // MARK: Public run entry points

    func runUpdateAll(_ inputs: AggregationRunInputs) async -> AggregationRunResult {
        pendingTouched.removeAll()
        var result = AggregationRunResult()
        let descriptor = FetchDescriptor<Feed>(predicate: #Predicate { $0.enabled })
        let feeds = ((try? modelContext.fetch(descriptor)) ?? [])
            .filter { inputs.isSourceEnabled($0.type) }
        try? modelContext.save()   // permanent ids before we carry them across the task group
        let ids = feeds.map(\.persistentModelID)
        inputs.progress(.start(total: ids.count))

        await withTaskGroup(of: (Int, [FeedFailureBox]).self) { group in
            var next = 0
            let window = min(Self.maxConcurrentFeedUpdates, ids.count)
            while next < window { let id = ids[next]; group.addTask { await self.aggregateBoxed(feedID: id, inputs) }; next += 1 }
            while let (ins, fails) = await group.next() {
                inputs.progress(.advance)
                result.inserted += ins
                result.failures.append(contentsOf: fails.compactMap(\.failure))
                for b in fails { result.touchedUIDs.formUnion(b.touched) }
                if Task.isCancelled { break }
                if next < ids.count { let id = ids[next]; group.addTask { await self.aggregateBoxed(feedID: id, inputs) }; next += 1 }
            }
        }
        // Accumulated touched uids come back through the boxes; also gather from the shared accumulator.
        result.touchedUIDs.formUnion(pendingTouched)
        pendingTouched.removeAll()
        result.deletedUIDs = cleanup(inputs)
        return result
    }

    func runUpdate(feedID: PersistentIdentifier, _ inputs: AggregationRunInputs) async -> AggregationRunResult {
        pendingTouched.removeAll()
        var result = AggregationRunResult()
        guard let feed = modelContext.model(for: feedID) as? Feed,
              inputs.isSourceEnabled(feed.type) else { return result }
        result.inserted = await aggregate(feed: feed, force: false, inputs: inputs, failures: &result.failures)
        result.touchedUIDs.formUnion(pendingTouched); pendingTouched.removeAll()
        result.deletedUIDs = cleanup(inputs)
        return result
    }

    func runForceReloadFeed(feedID: PersistentIdentifier, _ inputs: AggregationRunInputs) async -> AggregationRunResult {
        pendingTouched.removeAll()
        var result = AggregationRunResult()
        guard let feed = modelContext.model(for: feedID) as? Feed,
              inputs.isSourceEnabled(feed.type) else { return result }
        result.inserted = await aggregate(feed: feed, force: true, inputs: inputs, failures: &result.failures)
        try? modelContext.save()
        result.touchedUIDs.formUnion(pendingTouched); pendingTouched.removeAll()
        return result   // forceReload does NOT run retention (matches current behavior)
    }

    func runForceReloadArticle(articleID: PersistentIdentifier, _ inputs: AggregationRunInputs) async -> AggregationRunResult {
        pendingTouched.removeAll()
        var result = AggregationRunResult()
        guard let article = modelContext.model(for: articleID) as? Article, let feed = article.feed else { return result }
        let config = FeedConfig(feed: feed, collectedToday: 0)
        guard let aggregator = inputs.makeAggregator(config, inputs.credentials) else { return result }
        let seed = AggregatedArticle(
            title: article.title, identifier: article.identifier, url: article.url,
            rawContent: "", content: "", date: article.date, author: article.author, iconURL: article.iconURL)
        let refreshed: AggregatedArticle?
        do { refreshed = try await aggregator.refetch(seed) }
        catch { if Task.isCancelled { return result }; refreshed = nil }
        guard let refreshed else { return result }
        let processed = await inputs.processor.process([refreshed], ai: config.options.ai)
        result.inserted = ArticleUpsert.apply(
            processed, to: feed, starredTag: starredTag(),
            starredIdentifiers: inputs.starredIdentifiers(feed.identifier, feed.aggregatorType),
            context: modelContext, now: inputs.now,
            canonicalCreatedAt: { inputs.canonicalCreatedAt[$0] },
            onUpsert: { self.pendingTouched.insert($0) })
        try? modelContext.save()
        result.touchedUIDs.formUnion(pendingTouched); pendingTouched.removeAll()
        return result
    }

    func runSummarize(articleID: PersistentIdentifier, _ inputs: AggregationRunInputs) async -> (Bool, String?) {
        pendingTouched.removeAll()
        guard let article = modelContext.model(for: articleID) as? Article else { return (false, nil) }
        let seed = AggregatedArticle(
            title: article.title, identifier: article.identifier, url: article.url,
            rawContent: "", content: article.plainText, date: article.date, author: article.author, iconURL: article.iconURL)
        let processed = await inputs.processor.process([seed], ai: AIOptions(summarize: true))
        guard let summary = processed.first?.summary, !summary.isEmpty else { return (false, nil) }
        article.summary = summary
        try? modelContext.save()
        return (true, ArticleUID.make(for: article))
    }

    // MARK: Internals

    /// Touched uids accumulated across the current run's upserts (actor-isolated state).
    private var pendingTouched: Set<String> = []

    private struct FeedFailureBox: Sendable {
        let failure: AggregationService.FeedFailure?
        let touched: Set<String>
    }

    /// Task-group adapter: runs one feed and returns its inserted count + any failure + touched uids,
    /// so the concurrent path collects everything without racing on `pendingTouched`.
    private func aggregateBoxed(feedID: PersistentIdentifier, _ inputs: AggregationRunInputs) async -> (Int, [FeedFailureBox]) {
        guard let feed = modelContext.model(for: feedID) as? Feed else { return (0, []) }
        var failures: [AggregationService.FeedFailure] = []
        let before = pendingTouched
        let inserted = await aggregate(feed: feed, force: false, inputs: inputs, failures: &failures)
        let touched = pendingTouched.subtracting(before)
        return (inserted, failures.map { FeedFailureBox(failure: $0, touched: touched) }
                    + (failures.isEmpty ? [FeedFailureBox(failure: nil, touched: touched)] : []))
    }

    /// Faithful move of the old `AggregationService.aggregate(feed:force:)`.
    private func aggregate(feed: Feed, force: Bool, inputs: AggregationRunInputs, failures: inout [AggregationService.FeedFailure]) async -> Int {
        let runNow = inputs.now
        let collected = collectedToday(for: feed, now: runNow)
        let config = FeedConfig(feed: feed, collectedToday: collected, force: force)
        guard let aggregator = inputs.makeAggregator(config, inputs.credentials) else {
            let message = AggregatorError.notImplemented(feed.type).errorDescription ?? ""
            feed.lastError = message
            failures.append(.init(feedName: feed.name, message: message))
            return 0
        }
        let cap = AggregationLogic.runLimit(dailyLimit: config.dailyLimit, collectedToday: collected)
        let feedID = feed.persistentModelID
        var inserted = 0, kept = 0
        do {
            try aggregator.validate()
            do {
                try await aggregator.aggregate { article in
                    guard kept < cap else { throw CapReached() }
                    guard force || AggregationLogic.isWithinIntakeWindow(article.date, now: runNow) else { return }
                    let processed = await inputs.processor.process([article], ai: config.options.ai)
                    let blocks = await AggregationService.parseBlocks(processed)
                    inserted += await self.upsert(processed, blocks: blocks, feedID: feedID, now: runNow, inputs: inputs)
                    kept += 1
                }
            } catch is CapReached {}
            feed.lastFetchedAt = runNow
            feed.lastError = nil
            if feed.logoHash == nil, let hash = await inputs.logoResolver(config, aggregator) { feed.logoHash = hash }
            try? modelContext.save()
            return inserted
        } catch {
            if Task.isCancelled || error.isCancellationError { try? modelContext.save(); return inserted }
            let message = AggregationService.userFacingMessage(for: error)
            feed.lastError = message
            failures.append(.init(feedName: feed.name, message: message))
            try? modelContext.save()
            return inserted
        }
    }

    private func upsert(_ processed: [AggregatedArticle], blocks: [String: [Block]], feedID: PersistentIdentifier, now: Date, inputs: AggregationRunInputs) -> Int {
        guard let feed = modelContext.model(for: feedID) as? Feed else { return 0 }
        return ArticleUpsert.apply(
            processed, to: feed, starredTag: starredTag(),
            starredIdentifiers: inputs.starredIdentifiers(feed.identifier, feed.aggregatorType),
            context: modelContext, now: now,
            blocksFor: { blocks[$0.identifier] ?? ArticleUpsert.defaultBlocks(for: $0) },
            canonicalCreatedAt: { inputs.canonicalCreatedAt[$0] },
            onUpsert: { self.pendingTouched.insert($0) })
    }

    private func cleanup(_ inputs: AggregationRunInputs) -> [String] {
        guard !inputs.skipRetention else { return [] }
        let deleted = RetentionCleanup.run(context: modelContext, retentionDays: inputs.retentionDays, now: inputs.now)
        try? modelContext.save()
        return deleted
    }

    private func collectedToday(for feed: Feed, now: Date) -> Int {
        let startOfDay = Calendar.current.startOfDay(for: now)
        let feedID = feed.persistentModelID
        let descriptor = FetchDescriptor<Article>(
            predicate: #Predicate { $0.feed?.persistentModelID == feedID && $0.createdAt >= startOfDay })
        return (try? modelContext.fetchCount(descriptor)) ?? 0
    }

    private func starredTag() -> Tag? {
        let descriptor = FetchDescriptor<Tag>(predicate: #Predicate { $0.isBuiltIn })
        return (try? modelContext.fetch(descriptor))?.first
    }

    #if DEBUG
    func contextIsSameAs(_ other: ModelContext) -> Bool { modelContext === other }
    #endif
}
