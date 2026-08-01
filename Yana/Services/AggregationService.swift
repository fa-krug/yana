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

    /// Run one write-path pass on a fresh `AggregationWriter`, off the main actor.
    ///
    /// The hop is load-bearing, not decorative. `AggregationWriter` is a `@ModelActor`, and a
    /// `@ModelActor` executes on its **caller's** thread — awaited directly from this `@MainActor`
    /// coordinator, the fetch/parse/upsert path would run on the main thread and freeze the UI for
    /// the length of the run. `AggregationRunInputs`/`AggregationRunResult` are `Sendable`, which is
    /// what makes crossing the boundary legal (see `OffMainActor`).
    private func runOffMain<T: Sendable>(
        _ body: @escaping @Sendable (AggregationWriter, AggregationRunInputs) async -> T
    ) async -> T {
        let container = context.container
        let inputs = makeRunInputs()
        return await OffMainActor.run {
            await body(AggregationWriter(modelContainer: container), inputs)
        }
    }

    /// Update all enabled feeds. One feed's failure never aborts the run.
    @discardableResult
    func updateAll() async -> Int {
        lastRunFailures = []
        isUpdating = true
        defer { isUpdating = false; updateProgress.reset() }
        try? context.save()                         // flush so the writer's fetch sees pending feeds
        let result = await runOffMain { await $0.runUpdateAll($1) }
        refreshFromStore()
        lastRunFailures = result.failures
        SyncLog.shared.info(
            "updateAll inserted \(result.inserted) article(s); \(result.failures.count) feed failure(s)",
            category: "Aggregation"
        )
        let snapshot = await syncReferencedImages()
        await pruneOrphanedImages(snapshot: snapshot)
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
        let result = await runOffMain { await $0.runUpdate(feedID: feedID, $1) }
        refreshFromStore()
        lastRunFailures = result.failures
        SyncLog.shared.info(
            "update(\(feed.name)) inserted \(result.inserted) article(s); \(result.failures.count) failure(s)",
            category: "Aggregation"
        )
        let snapshot = await syncReferencedImages()
        await pruneOrphanedImages(snapshot: snapshot)
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
        let result = await runOffMain { await $0.runForceReloadFeed(feedID: feedID, $1) }
        refreshFromStore()
        lastRunFailures = result.failures
        await syncReferencedImages()   // registration only — forceReload skips retention, so it skips prune too
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
        let result = await runOffMain { await $0.runForceReloadArticle(articleID: articleID, $1) }
        reconcileArticle(articleID)
        await syncReferencedImages()   // registration only — forceReload skips retention, so it skips prune too
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
        let (ok, _) = await runOffMain { await $0.runSummarize(articleID: articleID, $1) }
        reconcileArticle(articleID)
        return ok
    }

    // MARK: - Helpers

    /// Register `StoredImage` rows for every image the current library references.
    /// `ensureStored` skips hashes that already have a row. Returns the
    /// snapshot it computed (`nil` if the underlying fetch failed) so `pruneOrphanedImages(snapshot:)`
    /// can reuse the *same* scan instead of re-fetching every `Feed`/`Article` a second time —
    /// the two used to each run their own full pass, doubling this method's own documented cost.
    ///
    /// **Both halves run off the main actor, and must keep doing so.** The scan fetches every
    /// article and JSON-decodes every body to walk its blocks; done on the main context that was a
    /// 222 ms freeze on a 4 000-article library, after *every* update — including the reader's
    /// pull-to-refresh and every scheduled background refresh with the app on screen.
    @discardableResult
    private func syncReferencedImages() async -> ReferencedImageSnapshot? {
        let container = context.container
        guard let snapshot = await OffMainActor.run({
            await AggregationWriter(modelContainer: container).referencedImageSnapshotForPruning()
        }) else {
            SyncLog.shared.error(
                "Image sync skipped this pass: could not read the referenced-image snapshot",
                category: "ImageSync"
            )
            return nil
        }
        await ImageSync.ensureStored(hashes: snapshot.hashes, container: container, imageStore: .shared)
        return snapshot
    }

    /// Prune `StoredImage` rows (and matching `ImageStore` disk blobs) that nothing references any
    /// more. Runs right after retention on the same two entry points that run retention
    /// (`updateAll`/`update(feed:)`) — not on `forceReload`, which also skips retention — and is
    /// gated on the same `UpdateInterval == .off` condition retention already uses, so it never
    /// runs when the device is a pure-mirror. See `ImagePrunePlan` for the two-phase quarantine and
    /// the safety bail-outs that make this safe against an incomplete local article set.
    ///
    /// `snapshot` is the one `syncReferencedImages()` already computed this run (`nil` when that
    /// scan failed) — reused, not re-fetched, and a `nil` snapshot means "skip pruning too": a
    /// failed fetch must never be read as "confirmed nothing is referenced".
    private func pruneOrphanedImages(snapshot: ReferencedImageSnapshot?) async {
        guard settings.updateInterval != .off else { return }
        guard let snapshot else { return }   // syncReferencedImages() already logged the failure
        let container = context.container
        let currentTime = now()

        let storedRowHashes = await OffMainActor.run {
            await ImagePruneRunner(modelContainer: container).storedHashes()
        }
        let diskHashes = await ImageStore.shared.allHashes()

        // decide()/load()/save() off the main actor too: on the reporting library (15k+ images)
        // the candidate map is tens of thousands of entries, and both the decision loop and the
        // UserDefaults encode/decode are O(that), not the cheap O(1) they look like at a glance.
        let plan = await OffMainActor.run {
            let decided = ImagePrunePlan.decide(
                referenced: snapshot.hashes,
                stored: storedRowHashes.union(diskHashes),
                candidates: ImagePruneCandidateStore.load(),
                now: currentTime,
                hasArticles: snapshot.hasArticles,
                hasUnmigratedLegacyContent: snapshot.hasUnmigratedLegacyContent,
                hasUndecodableBlocks: snapshot.hasUndecodableBlocks
            )
            ImagePruneCandidateStore.save(decided.candidates)
            return decided
        }
        guard !plan.toDelete.isEmpty else { return }

        let rowsDeleted = await OffMainActor.run {
            await ImagePruneRunner(modelContainer: container).deleteRows(hashes: plan.toDelete)
        }
        var diskOnlyDeleted = 0
        for hash in plan.toDelete {
            let hadFile = await ImageStore.shared.remove(forHash: hash)
            if hadFile, !storedRowHashes.contains(hash) { diskOnlyDeleted += 1 }
        }
        SyncLog.shared.info(
            "Pruned \(rowsDeleted) orphaned image(s), \(diskOnlyDeleted) disk file(s)",
            category: "ImagePrune"
        )
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
