import Foundation
import SwiftData

/// Orchestrates on-device aggregation: builds a per-feed snapshot, runs its aggregator,
/// then filters / caps / upserts the results. Concrete aggregators arrive in Phase 4b+;
/// until then the default factory returns `nil` and each feed records a "not available" error.
@MainActor
@Observable
final class AggregationService {
    var isUpdating = false

    private let context: ModelContext
    private let makeAggregator: AggregatorFactory
    private let now: () -> Date

    init(
        context: ModelContext,
        makeAggregator: @escaping AggregatorFactory = { AggregatorRegistry.shared.makeAggregator($0, credentials: $1) },
        now: @escaping () -> Date = { .now }
    ) {
        self.context = context
        self.makeAggregator = makeAggregator
        self.now = now
    }

    /// Update all enabled feeds. One feed's failure never aborts the run.
    func updateAll() async {
        isUpdating = true
        defer { isUpdating = false }
        let descriptor = FetchDescriptor<Feed>(predicate: #Predicate { $0.enabled })
        let feeds = (try? context.fetch(descriptor)) ?? []
        for feed in feeds {
            await aggregate(feed: feed)
        }
        cleanupAndSave()
    }

    /// Update a single feed.
    func update(feed: Feed) async {
        isUpdating = true
        defer { isUpdating = false }
        await aggregate(feed: feed)
        cleanupAndSave()
    }

    /// Re-fetch and re-process a single article by re-running its owning feed.
    /// (Phase 4b refines this to a true single-article re-fetch.)
    func update(article: Article) async {
        guard let feed = article.feed else { return }
        await update(feed: feed)
    }

    // MARK: - Core per-feed run

    private func aggregate(feed: Feed) async {
        let runNow = now()
        let collected = collectedToday(for: feed, now: runNow)
        let config = FeedConfig(feed: feed, collectedToday: collected)
        let credentials = AggregatorCredentials.resolved()

        guard let aggregator = makeAggregator(config, credentials) else {
            feed.lastError = AggregatorError.notImplemented(feed.type).errorDescription
            return
        }

        do {
            try aggregator.validate()
            let fetched = try await aggregator.aggregate()
            let fresh = fetched.filter { AggregationLogic.isWithinIntakeWindow($0.date, now: runNow) }
            let cap = AggregationLogic.runLimit(dailyLimit: config.dailyLimit, collectedToday: collected)
            let capped = Array(fresh.prefix(cap))
            ArticleUpsert.apply(capped, to: feed, starredTag: starredTag(), context: context, now: runNow)
            feed.lastFetchedAt = runNow
            feed.lastError = nil
        } catch {
            feed.lastError = error.localizedDescription
        }
    }

    // MARK: - Helpers

    private func collectedToday(for feed: Feed, now: Date) -> Int {
        let startOfDay = Calendar.current.startOfDay(for: now)
        return feed.articles.filter { $0.createdAt >= startOfDay }.count
    }

    private func starredTag() -> Tag? {
        let descriptor = FetchDescriptor<Tag>(predicate: #Predicate { $0.isBuiltIn })
        return (try? context.fetch(descriptor))?.first
    }

    private func cleanupAndSave() {
        let retentionDays = AppSettings().retentionDays
        RetentionCleanup.run(context: context, retentionDays: retentionDays, now: now())
        try? context.save()
    }
}
