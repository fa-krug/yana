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
    private let aiProcessor: AIProcessing
    private let now: () -> Date

    init(
        context: ModelContext,
        makeAggregator: @escaping AggregatorFactory = { AggregatorRegistry.shared.makeAggregator($0, credentials: $1) },
        aiProcessor: AIProcessing? = nil,
        now: @escaping () -> Date = { .now }
    ) {
        self.context = context
        self.makeAggregator = makeAggregator
        // Default: snapshot AppSettings + Keychain on the main actor into an AIProcessor.
        let settings = AppSettings()
        self.aiProcessor = aiProcessor ?? AIProcessor(
            config: Self.makeAIConfig(settings: settings),
            requestDelay: settings.aiRequestDelay
        )
        self.now = now
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
            let processed = await aiProcessor.process(capped, ai: config.options.ai)
            ArticleUpsert.apply(processed, to: feed, starredTag: starredTag(), context: context, now: runNow)
            feed.lastFetchedAt = runNow
            feed.lastError = nil
        } catch {
            feed.lastError = error.localizedDescription
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
