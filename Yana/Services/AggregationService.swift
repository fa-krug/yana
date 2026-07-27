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

    init(
        context: ModelContext,
        makeAggregator: @escaping AggregatorFactory = { AggregatorRegistry.shared.makeAggregator($0, credentials: $1) },
        aiProcessor: AIProcessing? = nil,
        now: @escaping () -> Date = { .now },
        logoResolver: @escaping LogoResolver = AggregationService.defaultLogoResolver,
        settings: AppSettings = AppSettings(),
        starredRegistry: StarredRegistry = .shared
    ) {
        self.context = context
        self.makeAggregator = makeAggregator
        self.injectedAIProcessor = aiProcessor
        self.now = now
        self.logoResolver = logoResolver
        self.settings = settings
        self.starredRegistry = starredRegistry
    }

    /// Map an arbitrary error to a clear, non-empty user-facing string.
    /// `LocalizedError` (e.g. `AggregatorError`) and Cocoa/URL errors already carry good
    /// messages; bare Swift errors otherwise render Foundation's useless synthesized
    /// "The operation couldn't be completed. (… error 1.)", so they get a localized fallback.
    nonisolated static func userFacingMessage(for error: Error) -> String {
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

    /// Snapshot all main-actor inputs the writer needs, as Sendable values. `AppSettings` is a
    /// `@MainActor @Observable` class (not Sendable), so its enabled-source set is precomputed on the
    /// main actor and the resulting `Set<AggregatorType>` is captured by the `@Sendable` closure.
    private func makeRunInputs() -> AggregationRunInputs {
        let marks = starredRegistry.snapshotMarks()
        let canonical: [String: Date] = [:]
        let enabledSources = Set(AggregatorType.allCases.filter { settings.isSourceEnabled($0) })
        return AggregationRunInputs(
            makeAggregator: makeAggregator,
            processor: currentAIProcessor(),
            logoResolver: logoResolver,
            credentials: AggregatorCredentials.resolved(),
            now: now(),
            starredIdentifiers: { feedIdentifier, aggregatorType in
                Set(marks.compactMap {
                    $0.feedIdentifier == feedIdentifier && $0.aggregatorType == aggregatorType
                        ? $0.articleIdentifier : nil
                })
            },
            canonicalCreatedAt: canonical,
            isSourceEnabled: { enabledSources.contains($0) },
            retentionDays: settings.retentionDays,
            skipRetention: settings.updateInterval == .off,
            // Each event hops to the main actor in its own Task, so ordering isn't guaranteed;
            // UpdateProgress currently has no UI consumer, so this is presently unobservable.
            // Funnel through an ordered path before any view reads updateProgress.
            progress: { [weak self] event in
                Task { @MainActor in
                    guard let self else { return }
                    switch event {
                    case .start(let total): self.updateProgress.start(total: total)
                    case .advance: self.updateProgress.advance()
                    }
                }
            })
    }

    /// Update all enabled feeds. One feed's failure never aborts the run.
    @discardableResult
    func updateAll() async -> Int {
        lastRunFailures = []
        isUpdating = true
        defer { isUpdating = false; updateProgress.reset() }
        try? context.save()                         // flush so the writer's fetch sees pending feeds
        let writer = AggregationWriter(modelContainer: context.container)
        let result = await writer.runUpdateAll(makeRunInputs())
        refreshFromStore()
        lastRunFailures = result.failures
        SyncLog.shared.info(
            "updateAll inserted \(result.inserted) article(s); \(result.failures.count) feed failure(s)",
            category: "Aggregation"
        )
        await syncReferencedImages()
        return result.inserted
    }

    /// Update a single feed.
    @discardableResult
    func update(feed: Feed) async -> Int {
        guard settings.isSourceEnabled(feed.type) else { return 0 }
        lastRunFailures = []
        isUpdating = true
        defer { isUpdating = false }
        try? context.save()
        let feedID = feed.persistentModelID
        let writer = AggregationWriter(modelContainer: context.container)
        let result = await writer.runUpdate(feedID: feedID, makeRunInputs())
        refreshFromStore()
        lastRunFailures = result.failures
        SyncLog.shared.info(
            "update(\(feed.name)) inserted \(result.inserted) article(s); \(result.failures.count) failure(s)",
            category: "Aggregation"
        )
        await syncReferencedImages()
        return result.inserted
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
        try? context.save()
        let feedID = feed.persistentModelID
        let writer = AggregationWriter(modelContainer: context.container)
        let result = await writer.runForceReloadFeed(feedID: feedID, makeRunInputs())
        refreshFromStore()
        lastRunFailures = result.failures
        await syncReferencedImages()
        return result.inserted
    }

    /// Re-fetch and re-process a single article by re-running its owning feed.
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
        guard article.feed != nil else { return 0 }
        lastRunFailures = []
        isUpdating = true
        defer { isUpdating = false }
        try? context.save()
        let articleID = article.persistentModelID
        let writer = AggregationWriter(modelContainer: context.container)
        let result = await writer.runForceReloadArticle(articleID: articleID, makeRunInputs())
        reconcileArticle(articleID)
        await syncReferencedImages()
        return result.inserted
    }

    /// Summarize a single article on demand, independent of its feed's AI options. Runs a
    /// summarize-only pass through the current AI processor, copies the resulting summary onto
    /// the article (source content is left untouched), and saves. Returns false — leaving the
    /// article unchanged — when no summary was produced (AI failure, dropped item, or empty
    /// content). Callers should only invoke this when AI is configured (see `AIReadiness`).
    @discardableResult
    func summarize(_ article: Article) async -> Bool {
        try? context.save()
        let articleID = article.persistentModelID
        let writer = AggregationWriter(modelContainer: context.container)
        let (ok, _) = await writer.runSummarize(articleID: articleID, makeRunInputs())
        reconcileArticle(articleID)
        return ok
    }

    // MARK: - Helpers

    /// Register `StoredImage` rows for every image the current library references, so CloudKit
    /// mirrors the blobs. Cheap: `ensureStored` skips hashes that already have a row.
    private func syncReferencedImages() async {
        let feeds = (try? context.fetch(FetchDescriptor<Feed>())) ?? []
        let articles = (try? context.fetch(FetchDescriptor<Article>())) ?? []
        var hashes = Set<String>()
        for feed in feeds { if let h = feed.logoHash, !h.isEmpty { hashes.insert(h) } }
        for article in articles {
            if !article.leadImageRef.isEmpty { hashes.insert(Self.hash(fromRef: article.leadImageRef)) }
            for ref in Self.imageRefs(in: article.blocks) { hashes.insert(Self.hash(fromRef: ref)) }
        }
        hashes.remove("")
        await ImageSync.ensureStored(hashes: hashes, context: context, imageStore: .shared)
    }

    /// All `yana-img://` refs referenced anywhere in a block tree — top-level `.image` blocks,
    /// `.embed` poster thumbnails, and refs nested inside `.list` items or `.blockquote` content.
    private static func imageRefs(in blocks: [Block]) -> [String] {
        var refs: [String] = []
        for block in blocks {
            switch block {
            case let .image(ref, _):
                refs.append(ref)
            case let .embed(embed):
                if let thumb = embed.thumbnailRef { refs.append(thumb) }
            case let .list(_, items):
                for item in items { refs.append(contentsOf: imageRefs(in: item)) }
            case let .blockquote(inner):
                refs.append(contentsOf: imageRefs(in: inner))
            default:
                break
            }
        }
        return refs
    }

    /// Strip the `yana-img://` scheme prefix to get the bare content hash.
    private static func hash(fromRef ref: String) -> String {
        let prefix = "\(ReaderWeb.imageScheme)://"
        return ref.hasPrefix(prefix) ? String(ref.dropFirst(prefix.count)) : ref
    }

    /// Refresh this (main) context's registered `Feed` objects from the store after the background
    /// writer committed on a sibling context. `context.model(for:)` returns a cached registered
    /// instance without re-reading the store, so scalar edits the writer made (lastError,
    /// lastFetchedAt, logoHash) would otherwise look stale to callers holding the pre-run feed. A
    /// same-type fetch reconciles the registered instances with the persisted rows.
    ///
    /// Feeds are few, so this whole-table fetch is cheap. Per-article reconciliation is bounded to
    /// the single touched row in the single-article paths (`forceReload(article:)`, `summarize`) —
    /// this deliberately does NOT fetch the whole `Article` table, which would reintroduce the
    /// O(library-size) main-thread cost the background writer exists to remove.
    private func refreshFromStore() {
        _ = try? context.fetch(FetchDescriptor<Feed>())
    }

    /// Reconcile only the single touched `Article` after the writer committed on a sibling context,
    /// so callers reading its scalars via `context.model(for: articleID)` (e.g. `plainText`,
    /// `summary`) see the writer's edits instead of the stale cached instance. Bounded to one row.
    private func reconcileArticle(_ articleID: PersistentIdentifier) {
        var descriptor = FetchDescriptor<Article>(
            predicate: #Predicate { $0.persistentModelID == articleID })
        descriptor.fetchLimit = 1
        _ = try? context.fetch(descriptor)
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
}
