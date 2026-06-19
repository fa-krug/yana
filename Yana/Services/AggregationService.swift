import Foundation
import SwiftData

/// Orchestrates on-device aggregation: builds a per-feed snapshot, runs its aggregator,
/// then filters / caps / upserts the results. Concrete aggregators arrive in Phase 4b+;
/// until then the default factory returns `nil` and each feed records a "not available" error.
@MainActor
@Observable
final class AggregationService {
    var isUpdating = false

    /// A feed that failed during the most recent run.
    struct FeedFailure: Sendable, Equatable {
        let feedName: String
        let message: String
    }

    /// Failures recorded during the most recent `updateAll()` / `update(feed:)`.
    private(set) var lastRunFailures: [FeedFailure] = []

    /// Upper bound on simultaneous in-flight feed fetches in `updateAll()`. Caps the number of
    /// concurrent network/AI awaits so a large feed list does not spawn unbounded requests.
    private static let maxConcurrentFeedUpdates = 5

    /// Resolves and caches a feed's logo, returning its content hash. Injectable for tests.
    typealias LogoResolver = @Sendable (_ config: FeedConfig, _ aggregator: any Aggregator) async -> String?

    /// Default logo resolver: pick a source URL (API image / brand favicon / identifier favicon)
    /// then download + compress + cache via the shared image store.
    static let defaultLogoResolver: LogoResolver = { config, aggregator in
        guard let urlString = await FeedLogoResolver.logoImageURL(for: config, aggregator: aggregator),
              let url = URL(string: urlString) else { return nil }
        return await ImageStore.shared.store(remoteURL: url, isHeader: false)
    }

    private let context: ModelContext
    private let makeAggregator: AggregatorFactory
    private let injectedAIProcessor: AIProcessing?
    private let now: () -> Date
    private let logoResolver: LogoResolver
    private let settings: AppSettings

    init(
        context: ModelContext,
        makeAggregator: @escaping AggregatorFactory = { AggregatorRegistry.shared.makeAggregator($0, credentials: $1) },
        aiProcessor: AIProcessing? = nil,
        now: @escaping () -> Date = { .now },
        logoResolver: @escaping LogoResolver = AggregationService.defaultLogoResolver,
        settings: AppSettings = AppSettings()
    ) {
        self.context = context
        self.makeAggregator = makeAggregator
        self.injectedAIProcessor = aiProcessor
        self.now = now
        self.logoResolver = logoResolver
        self.settings = settings
    }

    /// Map an arbitrary error to a clear, non-empty user-facing string.
    /// `LocalizedError` (e.g. `AggregatorError`) and Cocoa/URL errors already carry good
    /// messages; bare Swift errors otherwise render Foundation's useless synthesized
    /// "The operation couldn't be completed. (… error 1.)", so they get a localized fallback.
    static func userFacingMessage(for error: Error) -> String {
        if let localized = error as? LocalizedError,
           let description = localized.errorDescription,
           !description.trimmingCharacters(in: .whitespacesAndNewlines).isEmpty {
            return description
        }
        let nsError = error as NSError
        if nsError.domain == NSURLErrorDomain || nsError.domain == NSCocoaErrorDomain {
            return error.localizedDescription
        }
        return String(localized: "An unexpected error occurred.")
    }

    /// The processor for this run: the injected one (tests) or a fresh snapshot of current
    /// settings + Keychain so provider/model/key edits take effect on the next update.
    private func currentAIProcessor() -> AIProcessing {
        if let injectedAIProcessor { return injectedAIProcessor }
        let settings = AppSettings()
        let config = Self.makeAIConfig(settings: settings)
        if config.provider == .appleIntelligence {
            return AppleIntelligenceProcessor(
                generator: AppleIntelligenceClient(),
                temperature: config.temperature,
                maxTokens: config.maxTokens
            )
        }
        return AIProcessor(config: config, requestDelay: settings.aiRequestDelay)
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
        case .mistral:
            model = settings.mistralModel
            keyItem = .mistralAPIKey
        case .qwen:
            model = settings.qwenModel
            keyItem = .qwenAPIKey
        case .deepseek:
            model = settings.deepseekModel
            keyItem = .deepseekAPIKey
        case .appleIntelligence:
            model = ""
            keyItem = nil
        }
        let key = keyItem.flatMap(loadKey) ?? ""
        // OpenAI honors the user-overridable URL; the other OpenAI-compatible providers use
        // their fixed base. Non-compatible providers (Anthropic/Gemini) ignore this field.
        let apiBaseURL = provider == .openai ? settings.openaiAPIURL : provider.baseURL
        return AIConfig(
            provider: provider,
            model: model,
            apiKey: key,
            apiBaseURL: apiBaseURL,
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
        lastRunFailures = []
        isUpdating = true
        defer { isUpdating = false }
        let descriptor = FetchDescriptor<Feed>(predicate: #Predicate { $0.enabled })
        let feeds = ((try? context.fetch(descriptor)) ?? [])
            .filter { settings.isSourceEnabled($0.type) }

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
                // Stop scheduling new feeds once a newer update has cancelled this run;
                // in-flight children unwind on their own as the group scope exits.
                if Task.isCancelled { break }
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
        guard settings.isSourceEnabled(feed.type) else { return 0 }
        lastRunFailures = []
        isUpdating = true
        defer { isUpdating = false }
        let inserted = await aggregate(feed: feed)
        cleanupAndSave()
        return inserted
    }

    /// Force reload a single feed: re-import every article the source currently offers,
    /// bypassing the intake-window filter and the daily cap. Existing articles upsert
    /// (content refreshed; createdAt + Starred preserved); older/over-cap items are imported too.
    @discardableResult
    func forceReload(feed: Feed) async -> Int {
        guard settings.isSourceEnabled(feed.type) else { return 0 }
        lastRunFailures = []
        isUpdating = true
        defer { isUpdating = false }
        let inserted = await aggregate(feed: feed, force: true)
        try? context.save()
        return inserted
    }

    /// Re-fetch and re-process a single article by re-running its owning feed.
    /// (Phase 4b refines this to a true single-article re-fetch.)
    @discardableResult
    func update(article: Article) async -> Int {
        guard let feed = article.feed else { return 0 }
        return await update(feed: feed)
    }

    /// Force reload a single article: re-fetch its content directly from the source (`refetch`),
    /// upserting in place (content refreshed; createdAt + Starred preserved).
    /// Returns 0 when the source can't re-fetch the lone item (the article is left untouched);
    /// never reloads the parent feed.
    @discardableResult
    func forceReload(article: Article) async -> Int {
        guard let feed = article.feed else { return 0 }
        lastRunFailures = []
        isUpdating = true
        defer { isUpdating = false }

        let config = FeedConfig(feed: feed, collectedToday: 0)
        let credentials = AggregatorCredentials.resolved()
        guard let aggregator = makeAggregator(config, credentials) else { return 0 }
        // Seed source fields only. `summary` is a derived AI field, not source content: carrying
        // it here would let a stale summary survive a reprocess that no longer produces one (e.g.
        // summarization disabled, translation enabled). It is regenerated by the AI pass below.
        let seed = AggregatedArticle(
            title: article.title, identifier: article.identifier, url: article.url,
            rawContent: article.rawContent, content: article.content, date: article.date,
            author: article.author, iconURL: article.iconURL
        )
        let refreshed: AggregatedArticle?
        do {
            refreshed = try await aggregator.refetch(seed)
        } catch {
            if Task.isCancelled { return 0 }
            refreshed = nil
        }
        guard let refreshed else { return 0 }
        let processed = await currentAIProcessor().process([refreshed], ai: config.options.ai)
        let inserted = ArticleUpsert.apply(processed, to: feed, starredTag: starredTag(),
                                           context: context, now: now())
        try? context.save()
        return inserted
    }

    /// Summarize a single article on demand, independent of its feed's AI options. Runs a
    /// summarize-only pass through the current AI processor, copies the resulting summary onto
    /// the article (source content is left untouched), and saves. Returns false — leaving the
    /// article unchanged — when no summary was produced (AI failure, dropped item, or empty
    /// content). Callers should only invoke this when AI is configured (see `AIReadiness`).
    @discardableResult
    func summarize(_ article: Article) async -> Bool {
        let seed = AggregatedArticle(
            title: article.title, identifier: article.identifier, url: article.url,
            rawContent: article.rawContent, content: article.content, date: article.date,
            author: article.author, iconURL: article.iconURL
        )
        let processed = await currentAIProcessor().process([seed], ai: AIOptions(summarize: true))
        guard let summary = processed.first?.summary, !summary.isEmpty else { return false }
        article.summary = summary
        try? context.save()
        return true
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
    private func aggregate(feed: Feed, force: Bool = false) async -> Int {
        let runNow = now()
        let collected = collectedToday(for: feed, now: runNow)
        let config = FeedConfig(feed: feed, collectedToday: collected, force: force)
        let credentials = AggregatorCredentials.resolved()

        guard let aggregator = makeAggregator(config, credentials) else {
            let message = AggregatorError.notImplemented(feed.type).errorDescription ?? ""
            feed.lastError = message
            lastRunFailures.append(FeedFailure(feedName: feed.name, message: message))
            return 0
        }

        do {
            try aggregator.validate()
            let fetched = try await aggregator.aggregate()
            let fresh = force ? fetched : fetched.filter { AggregationLogic.isWithinIntakeWindow($0.date, now: runNow) }
            let cap = AggregationLogic.runLimit(dailyLimit: config.dailyLimit, collectedToday: collected)
            let capped = Array(fresh.prefix(cap))
            let processed = await currentAIProcessor().process(capped, ai: config.options.ai)
            let inserted = ArticleUpsert.apply(processed, to: feed, starredTag: starredTag(), context: context, now: runNow)
            feed.lastFetchedAt = runNow
            feed.lastError = nil
            if feed.logoHash == nil, let hash = await logoResolver(config, aggregator) {
                feed.logoHash = hash
            }
            return inserted
        } catch {
            // A cancelled run (the user triggered a newer update) is not a feed failure:
            // leave the existing error/state untouched so no spurious "Update Failed" surfaces.
            if Task.isCancelled { return 0 }
            let message = Self.userFacingMessage(for: error)
            feed.lastError = message
            lastRunFailures.append(FeedFailure(feedName: feed.name, message: message))
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
