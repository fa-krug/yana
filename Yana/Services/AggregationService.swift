import Foundation
import SwiftData

/// Orchestrates on-device aggregation: builds a per-feed snapshot, runs its aggregator,
/// then filters / caps / upserts the results. Concrete aggregators arrive in Phase 4b+;
/// until then the default factory returns `nil` and each feed records a "not available" error.
@MainActor
@Observable
final class AggregationService {
    var isUpdating = false

    /// Upper bound on simultaneous in-flight feed fetches in `updateAll()`. Caps the number of
    /// concurrent network/AI awaits so a large feed list does not spawn unbounded requests.
    private static let maxConcurrentFeedUpdates = 5

    private let context: ModelContext
    private let makeAggregator: AggregatorFactory
    private let injectedAIProcessor: AIProcessing?
    private let now: () -> Date

    init(
        context: ModelContext,
        makeAggregator: @escaping AggregatorFactory = { AggregatorRegistry.shared.makeAggregator($0, credentials: $1) },
        aiProcessor: AIProcessing? = nil,
        now: @escaping () -> Date = { .now }
    ) {
        self.context = context
        self.makeAggregator = makeAggregator
        self.injectedAIProcessor = aiProcessor
        self.now = now
    }

    /// The processor for this run: the injected one (tests) or a fresh snapshot of current
    /// settings + Keychain so provider/model/key edits take effect on the next update.
    private func currentAIProcessor() -> AIProcessing {
        if let injectedAIProcessor { return injectedAIProcessor }
        let settings = AppSettings()
        return AIProcessor(config: Self.makeAIConfig(settings: settings), requestDelay: settings.aiRequestDelay)
    }

    /// Build the `AIConfig` snapshot from settings + Keychain. Returns a `.none`-provider
    /// config when AI is off; the processor then no-ops. Per-provider model + key are read
    /// from the dedicated AppSettings properties and the matching Keychain item. `loadKey`
    /// is injectable so tests stay hermetic (no real Keychain access).
    static func makeAIConfig(
        settings: AppSettings,
        loadKey: (KeychainService.APIKeyItem) -> String? = { KeychainService.loadAPIKey(for: $0) }
    ) -> AIConfig {
        let provider = settings.activeAIProvider
        let model: String
        let keyItem: KeychainService.APIKeyItem?
        switch provider {
        case .none:
            model = ""
            keyItem = nil
        case .openai:
            model = settings.openaiModel
            keyItem = .openaiAPIKey
        case .anthropic:
            model = settings.anthropicModel
            keyItem = .anthropicAPIKey
        case .gemini:
            model = settings.geminiModel
            keyItem = .geminiAPIKey
        }
        let key = keyItem.flatMap(loadKey) ?? ""
        return AIConfig(
            provider: provider,
            model: model,
            apiKey: key,
            openaiAPIURL: settings.openaiAPIURL,
            temperature: settings.aiTemperature,
            maxTokens: settings.aiMaxTokens,
            requestTimeout: settings.aiRequestTimeout,
            maxRetries: settings.aiMaxRetries,
            retryDelay: settings.aiRetryDelay,
            maxRetryTime: 60
        )
    }

    /// Update all enabled feeds. One feed's failure never aborts the run.
    @discardableResult
    func updateAll() async -> Int {
        isUpdating = true
        defer { isUpdating = false }
        let descriptor = FetchDescriptor<Feed>(predicate: #Predicate { $0.enabled })
        let feeds = (try? context.fetch(descriptor)) ?? []

        // Run per-feed work concurrently with a bounded sliding window. Each `aggregate(feed:)`
        // stays on the main actor, so its synchronous SwiftData reads/writes remain serialized
        // and race-free; only the network/AI `await` suspension points interleave. We carry the
        // `Sendable` PersistentIdentifier across the task boundary (not the non-Sendable `Feed`)
        // and re-resolve it on the main actor inside `aggregate(feedID:)`.
        let ids = feeds.map(\.persistentModelID)
        var inserted = 0
        await withTaskGroup(of: Int.self) { group in
            var nextIndex = 0
            let window = min(Self.maxConcurrentFeedUpdates, ids.count)
            while nextIndex < window {
                let id = ids[nextIndex]
                group.addTask { await self.aggregate(feedID: id) }
                nextIndex += 1
            }
            while let result = await group.next() {
                inserted += result
                if nextIndex < ids.count {
                    let id = ids[nextIndex]
                    group.addTask { await self.aggregate(feedID: id) }
                    nextIndex += 1
                }
            }
        }

        cleanupAndSave()
        return inserted
    }

    /// Update a single feed.
    @discardableResult
    func update(feed: Feed) async -> Int {
        isUpdating = true
        defer { isUpdating = false }
        let inserted = await aggregate(feed: feed)
        cleanupAndSave()
        return inserted
    }

    /// Re-fetch and re-process a single article by re-running its owning feed.
    /// (Phase 4b refines this to a true single-article re-fetch.)
    @discardableResult
    func update(article: Article) async -> Int {
        guard let feed = article.feed else { return 0 }
        return await update(feed: feed)
    }

    // MARK: - Core per-feed run

    /// Resolve a feed from its `Sendable` identifier on the main actor, then run the per-feed
    /// work. Used by `updateAll()`'s task group so the non-Sendable `Feed` never crosses an
    /// isolation boundary.
    @discardableResult
    private func aggregate(feedID: PersistentIdentifier) async -> Int {
        guard let feed = self[feedID, as: Feed.self] else { return 0 }
        return await aggregate(feed: feed)
    }

    /// Look up a model by identifier in this service's context.
    private subscript<T: PersistentModel>(id: PersistentIdentifier, as type: T.Type) -> T? {
        context.model(for: id) as? T
    }

    @discardableResult
    private func aggregate(feed: Feed) async -> Int {
        let runNow = now()
        let collected = collectedToday(for: feed, now: runNow)
        let config = FeedConfig(feed: feed, collectedToday: collected)
        let credentials = AggregatorCredentials.resolved()

        guard let aggregator = makeAggregator(config, credentials) else {
            feed.lastError = AggregatorError.notImplemented(feed.type).errorDescription
            return 0
        }

        do {
            try aggregator.validate()
            let fetched = try await aggregator.aggregate()
            let fresh = fetched.filter { AggregationLogic.isWithinIntakeWindow($0.date, now: runNow) }
            let cap = AggregationLogic.runLimit(dailyLimit: config.dailyLimit, collectedToday: collected)
            let capped = Array(fresh.prefix(cap))
            let processed = await currentAIProcessor().process(capped, ai: config.options.ai)
            let inserted = ArticleUpsert.apply(processed, to: feed, starredTag: starredTag(), context: context, now: runNow)
            feed.lastFetchedAt = runNow
            feed.lastError = nil
            return inserted
        } catch {
            feed.lastError = error.localizedDescription
            return 0
        }
    }

    // MARK: - Helpers

    private func collectedToday(for feed: Feed, now: Date) -> Int {
        let startOfDay = Calendar.current.startOfDay(for: now)
        let feedID = feed.persistentModelID
        let descriptor = FetchDescriptor<Article>(
            predicate: #Predicate { $0.feed?.persistentModelID == feedID && $0.createdAt >= startOfDay }
        )
        return (try? context.fetchCount(descriptor)) ?? 0
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
