import Foundation
import SwiftData

/// Orchestrates on-device aggregation: builds a per-feed snapshot, runs its aggregator,
/// then filters / caps / upserts the results. Concrete aggregators arrive in Phase 4b+;
/// until then the default factory returns `nil` and each feed records a "not available" error.
@MainActor
@Observable
final class AggregationService {
    var isUpdating = false

    /// Counted progress for the most recent `updateAll()` run; idle otherwise. Read by the reader
    /// to show "Updating N of M…". Single-feed/article operations leave it idle.
    let updateProgress = UpdateProgress()

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
        return await ImageStore.shared.store(remoteURL: url, isHeader: false, removeWhiteBackground: true)
    }

    private let context: ModelContext
    private let makeAggregator: AggregatorFactory
    private let injectedAIProcessor: AIProcessing?
    private let now: () -> Date
    private let logoResolver: LogoResolver
    private let settings: AppSettings
    private let starredRegistry: StarredRegistry
    private let articleSync: ArticleSyncService

    init(
        context: ModelContext,
        makeAggregator: @escaping AggregatorFactory = { AggregatorRegistry.shared.makeAggregator($0, credentials: $1) },
        aiProcessor: AIProcessing? = nil,
        now: @escaping () -> Date = { .now },
        logoResolver: @escaping LogoResolver = AggregationService.defaultLogoResolver,
        settings: AppSettings = AppSettings(),
        starredRegistry: StarredRegistry = .shared,
        articleSync: ArticleSyncService = .shared
    ) {
        self.context = context
        self.makeAggregator = makeAggregator
        self.injectedAIProcessor = aiProcessor
        self.now = now
        self.logoResolver = logoResolver
        self.settings = settings
        self.starredRegistry = starredRegistry
        self.articleSync = articleSync
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
        defer { isUpdating = false; updateProgress.reset() }
        await articleSync.pull()
        let descriptor = FetchDescriptor<Feed>(predicate: #Predicate { $0.enabled })
        let feeds = ((try? context.fetch(descriptor)) ?? [])
            .filter { settings.isSourceEnabled($0.type) }

        // Flush any pending inserts so every feed has a *permanent* identifier before we capture
        // it. We carry ids across the task boundary and re-resolve each with `context.model(for:)`;
        // the per-feed `save()` below persists *all* pending inserts, so a temporary id captured
        // here would be invalidated the moment another feed saves — its later re-resolution then
        // faults on "backing data could no longer be found" (a hard SwiftData crash).
        save()

        // Run per-feed work concurrently with a bounded sliding window. Each `aggregate(feed:)`
        // stays on the main actor, so its synchronous SwiftData reads/writes remain serialized
        // and race-free; only the network/AI `await` suspension points interleave. We carry the
        // `Sendable` PersistentIdentifier across the task boundary (not the non-Sendable `Feed`)
        // and re-resolve it on the main actor inside `aggregate(feedID:)`.
        let ids = feeds.map(\.persistentModelID)
        updateProgress.start(total: ids.count)
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
                updateProgress.advance()
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
        await pushRecentlyChanged()
        return inserted
    }

    /// Update a single feed.
    @discardableResult
    func update(feed: Feed) async -> Int {
        guard settings.isSourceEnabled(feed.type) else { return 0 }
        lastRunFailures = []
        isUpdating = true
        defer { isUpdating = false }
        await articleSync.pull()
        let inserted = await aggregate(feed: feed)
        cleanupAndSave()
        await pushRecentlyChanged()
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
        await pushRecentlyChanged()
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
        // Seed identity/source fields only. The body is not seeded: `refetch` always repopulates
        // it from a fresh network fetch, so any seeded content would be overwritten anyway (the
        // article now stores native blocks, not HTML). `summary` is a derived AI field, not source
        // content: carrying it here would let a stale summary survive a reprocess that no longer
        // produces one. It is regenerated by the AI pass below.
        let seed = AggregatedArticle(
            title: article.title, identifier: article.identifier, url: article.url,
            rawContent: "", content: "", date: article.date,
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
        let inserted = ArticleUpsert.apply(
            processed, to: feed, starredTag: starredTag(),
            starredIdentifiers: starredRegistry.identifiers(forFeedIdentifier: feed.identifier, aggregatorType: feed.aggregatorType),
            context: context, now: now(),
            canonicalCreatedAt: { [articleSync] uid in articleSync.canonicalCreatedAt(forUID: uid) })
        try? context.save()
        await pushRecentlyChanged()
        return inserted
    }

    /// Summarize a single article on demand, independent of its feed's AI options. Runs a
    /// summarize-only pass through the current AI processor, copies the resulting summary onto
    /// the article (source content is left untouched), and saves. Returns false — leaving the
    /// article unchanged — when no summary was produced (AI failure, dropped item, or empty
    /// content). Callers should only invoke this when AI is configured (see `AIReadiness`).
    @discardableResult
    func summarize(_ article: Article) async -> Bool {
        // Summarize from the article's visible text (its native body is blocks, not HTML); the AI
        // processor strips chrome and caps length, and plain text summarizes fine.
        let seed = AggregatedArticle(
            title: article.title, identifier: article.identifier, url: article.url,
            rawContent: "", content: article.plainText, date: article.date,
            author: article.author, iconURL: article.iconURL
        )
        let processed = await currentAIProcessor().process([seed], ai: AIOptions(summarize: true))
        guard let summary = processed.first?.summary, !summary.isEmpty else { return false }
        article.summary = summary
        try? context.save()
        await pushRecentlyChanged()
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

        // Per-article pipeline: each article is processed (intake filter → AI → upsert) and
        // inserted into the context before the next is collected, but the context is *saved once
        // per feed* rather than once per article. Saving after every article flushed SQLite and
        // fired a `ModelContext.didSave` on the main thread N times per feed — and each didSave
        // kicks a full timeline-index reload + re-filter + reader re-render. That O(articles)
        // storm of main-thread work is what made the reader lag and stutter during a refresh.
        // Collapsing to one save per feed keeps it O(feeds). Durability is preserved: the save in
        // the catch below flushes whatever was collected before an interruption, so a
        // cancelled/failed feed never loses the articles it already handed over.
        let processor = currentAIProcessor()
        let cap = AggregationLogic.runLimit(dailyLimit: config.dailyLimit, collectedToday: collected)
        let feedID = feed.persistentModelID
        var inserted = 0
        var kept = 0

        do {
            try aggregator.validate()
            do {
                // The sink runs in the aggregator's (non–main-actor) region, so the SwiftData
                // upsert — which is `@MainActor` and touches the non-Sendable `context` — is
                // hopped onto the main actor via `upsert`, passing only Sendable values.
                try await aggregator.aggregate { article in
                    guard kept < cap else { throw CapReached() }        // run cap reached → stop fetching more
                    guard force || AggregationLogic.isWithinIntakeWindow(article.date, now: runNow) else { return }
                    let processed = await processor.process([article], ai: config.options.ai)
                    // Parse each article's HTML into native blocks OFF the main actor before the
                    // upsert hops back to it — the SwiftSoup parse is the heavy per-article cost and
                    // running it on the main thread is what made the reader stutter during a refresh.
                    let blocks = await Self.parseBlocks(processed)
                    inserted += await self.upsert(processed, blocks: blocks, feedID: feedID, now: runNow)
                    kept += 1
                }
            } catch is CapReached { /* normal stop: everything kept is upserted */ }
            feed.lastFetchedAt = runNow
            feed.lastError = nil
            if feed.logoHash == nil, let hash = await logoResolver(config, aggregator) {
                feed.logoHash = hash
            }
            save()                              // one save per feed: the upserted articles + feed state
            return inserted
        } catch {
            // A cancelled run (the user triggered a newer update, or a background window expired) is
            // not a feed failure: leave the existing error/state untouched so no spurious "Update
            // Failed" surfaces. Persist whatever was collected before the interruption so it isn't lost.
            if Task.isCancelled || error.isCancellationError {
                save()
                return inserted
            }
            let message = Self.userFacingMessage(for: error)
            feed.lastError = message
            lastRunFailures.append(FeedFailure(feedName: feed.name, message: message))
            save()                              // persist the partial batch + the recorded error
            return inserted
        }
    }

    /// Upsert one run's processed article(s) into the context, *without* saving — the owning
    /// `aggregate(feed:)` saves once per feed (see its comment). Runs on the main actor (the
    /// SwiftData `context` is non-Sendable and main-actor-isolated); takes only Sendable values so
    /// the streaming sink can call it across the actor boundary. The `blocks` were parsed off the
    /// main actor by `parseBlocks`, so this hop does only the light SwiftData writes. Returns the
    /// number of newly inserted articles.
    @MainActor
    private func upsert(
        _ processed: [AggregatedArticle], blocks: [String: [Block]], feedID: PersistentIdentifier, now: Date
    ) -> Int {
        guard let feed = self[feedID, as: Feed.self] else { return 0 }
        return ArticleUpsert.apply(
            processed, to: feed, starredTag: starredTag(),
            starredIdentifiers: starredRegistry.identifiers(forFeedIdentifier: feed.identifier, aggregatorType: feed.aggregatorType),
            context: context, now: now,
            // Every processed article is pre-parsed; the inline fallback is defensive and never hit.
            blocksFor: { blocks[$0.identifier] ?? ArticleUpsert.defaultBlocks(for: $0) },
            canonicalCreatedAt: { [articleSync] uid in articleSync.canonicalCreatedAt(forUID: uid) }
        )
    }

    /// Convert each processed article's sanitized HTML into native `[Block]`s **off the main actor**.
    /// `nonisolated` detaches this from the service's `@MainActor` isolation so the SwiftSoup parse —
    /// the heaviest per-article step — runs on the cooperative pool, leaving the main thread free for
    /// the reader. Only the resulting `Sendable` blocks cross back for the on-main upsert.
    nonisolated static func parseBlocks(_ articles: [AggregatedArticle]) async -> [String: [Block]] {
        var result: [String: [Block]] = [:]
        for article in articles {
            result[article.identifier] = ArticleUpsert.defaultBlocks(for: article)
        }
        return result
    }

    /// Persist pending context changes, ignoring the error — a failed save leaves the run's
    /// in-memory inserts intact for the next save attempt.
    private func save() {
        try? context.save()
    }

    /// Push all local articles' current state to article sync. Simpler and safe: article sync
    /// dedups by UID and skips unchanged records at the CloudKit layer, and this runs only after a
    /// user/background refresh, not per article.
    private func pushRecentlyChanged() async {
        let all = (try? context.fetch(FetchDescriptor<Article>())) ?? []
        await articleSync.push(uids: all.compactMap { ArticleUID.make(for: $0) })
    }

    /// Thrown by the per-article sink to stop the aggregator once the run cap is reached.
    private struct CapReached: Error {}

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
