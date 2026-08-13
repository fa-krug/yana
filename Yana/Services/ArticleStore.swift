import Foundation
import SwiftData

/// Loads the lightweight article index off the main thread. `@ModelActor` gives it a private
/// `ModelContext`; it maps to `Sendable` `ArticleSummary` values that cross back to the main actor.
@ModelActor
actor ArticleSummaryLoader {
    func load() throws -> [ArticleSummary] {
        var descriptor = FetchDescriptor<Article>(
            sortBy: [SortDescriptor(\.readRank, order: .forward), SortDescriptor(\.createdAt, order: .forward)]
        )
        // Only the light columns; the heavy body fields (`blockData`/`plainText`/`summary`) and the
        // legacy `content` stay unfetched.
        descriptor.propertiesToFetch = [\.title, \.identifier, \.author, \.date, \.createdAt, \.readRank]
        descriptor.relationshipKeyPathsForPrefetching = [\.feed, \.tags]
        let rows = try StartupTrace.measure("fullLoad.fetch") { try modelContext.fetch(descriptor) }
        let tagNamesByID = ArticleSummary.tagNameLookup(in: modelContext)
        return StartupTrace.measure("fullLoad.map") {
            rows.map { ArticleSummary($0, tagNamesByID: tagNamesByID) }
        }
    }

    /// Anchor-centered slice for the cold-cache fast path: the ~`2*radius+1` articles around the
    /// saved anchor (inclusive), ascending. Falls back to the newest `2*radius+1` when there is no
    /// anchor or it is gone. Same light columns / prefetch as `load()`.
    func loadWindow(around anchorID: String?, radius: Int) throws -> [ArticleSummary] {
        // The window splits on `createdAt` (`>= anchorCreatedAt` newer, `< anchorCreatedAt`
        // older). Under exact-timestamp ties the anchor may not land in the truncated window; that
        // is acceptable and self-healing — this is only the transient cold-cache first-paint set,
        // and the full load (ms later) plus reanchor-by-identifier resolves the true position
        // regardless.
        let tagNamesByID = ArticleSummary.tagNameLookup(in: modelContext)

        if let anchorID, let anchorCreatedAt = try anchorCreatedAt(for: anchorID) {
            var newerD = lightDescriptor(
                predicate: #Predicate { $0.createdAt >= anchorCreatedAt }, order: .forward
            )
            newerD.fetchLimit = radius + 1
            let newer = try modelContext.fetch(newerD)

            var olderD = lightDescriptor(
                predicate: #Predicate { $0.createdAt < anchorCreatedAt }, order: .reverse
            )
            olderD.fetchLimit = radius
            let older = try modelContext.fetch(olderD)

            // `newer`/`older` are two separate fetches split on `createdAt` alone, so a read row
            // with a later `createdAt` can land in `newer` alongside genuinely-adjacent unread
            // rows (and vice versa for `older`) -- the naive concatenation below is not
            // guaranteed to match `lightDescriptor`'s `(readRank, createdAt)` order. Re-sort with
            // the same comparator `SummaryIndexMerge` uses so this transient cold-start window
            // never visibly mis-orders read/unread blocks before the full reconcile lands.
            return (Array(older.reversed()) + newer)
                .map { ArticleSummary($0, tagNamesByID: tagNamesByID) }
                .sorted(by: SummaryIndexMerge.isOrderedBefore)
        }

        var newestD = lightDescriptor(predicate: nil, order: .reverse)
        newestD.fetchLimit = 2 * radius + 1
        return try modelContext.fetch(newestD).reversed().map { ArticleSummary($0, tagNamesByID: tagNamesByID) }
    }

    /// How many `Article` rows the store holds. A single SQL aggregate — cheap enough to run as a
    /// probe on every CloudKit merge notification, which a full re-read is not.
    func articleCount() throws -> Int {
        try modelContext.fetchCount(FetchDescriptor<Article>())
    }

    /// The summaries for a specific set of rows — the incremental refresh path. Rows that no longer
    /// exist are simply absent from the result, so a race with a concurrent delete resolves as a
    /// removal rather than an error. Same light columns / prefetch as `load()`.
    func summaries(for ids: [PersistentIdentifier]) throws -> [ArticleSummary] {
        guard !ids.isEmpty else { return [] }
        let wanted = Set(ids)
        var descriptor = lightDescriptor(
            predicate: #Predicate { wanted.contains($0.persistentModelID) }, order: .forward
        )
        descriptor.fetchLimit = wanted.count
        let tagNamesByID = ArticleSummary.tagNameLookup(in: modelContext)
        return try modelContext.fetch(descriptor).map { ArticleSummary($0, tagNamesByID: tagNamesByID) }
    }

    private func anchorCreatedAt(for identifier: String) throws -> Date? {
        var d = FetchDescriptor<Article>(
            predicate: #Predicate { $0.identifier == identifier },
            sortBy: [SortDescriptor(\.createdAt, order: .forward)]
        )
        d.fetchLimit = 1
        d.propertiesToFetch = [\.createdAt]
        return try modelContext.fetch(d).first?.createdAt
    }

    /// A `createdAt`-sorted descriptor restricted to the light timeline columns, with `feed`/`tags`
    /// prefetched — the same shape `load()` uses, factored out for the windowed fetches.
    private func lightDescriptor(
        predicate: Predicate<Article>?, order: SortOrder
    ) -> FetchDescriptor<Article> {
        var d = FetchDescriptor<Article>(
            predicate: predicate,
            sortBy: [SortDescriptor(\.readRank, order: order), SortDescriptor(\.createdAt, order: order)]
        )
        d.propertiesToFetch = [\.title, \.identifier, \.author, \.date, \.createdAt, \.readRank]
        d.relationshipKeyPathsForPrefetching = [\.feed, \.tags]
        return d
    }
}

/// Single source of truth for the timeline/list dataset. On cold start it paints from the disk
/// cache (warm) or a small anchor-centered window (cold cache), then reconciles to the full DB
/// index and keeps in sync with every `ModelContext` save.
@MainActor
@Observable
final class ArticleStore {
    private(set) var summaries: [ArticleSummary] = []
    private(set) var hasLoaded = false
    /// `summaries` filtered by the reader's tag/feed/starred timeline filter and pinned to the
    /// currently displayed article (see `TimelinePinning`). Kept current here — recomputed
    /// alongside `summaries` and on every `UserDefaults` change — rather than in a separate object,
    /// so the article list sheet (`ArticleListView`) always has it ready without depending on that
    /// view's own render cycle to recompute it.
    private(set) var browsingArticles: [ArticleSummary] = []

    /// Half-width of the cold-cache window; ~`2*radius+1` articles around the anchor.
    private static let windowRadius = 25

    /// Above this many changed rows in one burst, re-reading the whole index beats splicing: the
    /// splice re-fetches every changed row anyway, and a single unbounded fetch is cheaper than a
    /// large `IN (…)` predicate plus a large merge.
    private static let spliceLimit = 1000

    /// How long the disk cache may lag the in-memory index. The cache only speeds up the *next*
    /// cold start, so rewriting the whole plist on every splice would reintroduce exactly the
    /// per-save full-library cost this class now avoids. Losing the last few seconds of writes to a
    /// kill is harmless — a stale cache is reconciled by the full load that follows it.
    private static let cacheWriteDelay: Duration = .seconds(5)

    private let container: ModelContainer
    private let cache: SummaryIndexCache
    private let anchorProvider: () -> String?
    private var observer: NSObjectProtocol?
    /// Backs `browsingArticles`; a plain `AppSettings()` like every other reader/settings view
    /// uses. Since `AppSettings` instances don't observe each other's writes (each wraps the same
    /// `UserDefaults` independently), `defaultsObserver` below is what picks up a filter changed
    /// through any other instance.
    @ObservationIgnored private let settings = AppSettings()
    @ObservationIgnored private var defaultsObserver: NSObjectProtocol?

    /// Rows reported by saves since the last refresh, folded together. Drained by the coalescer.
    @ObservationIgnored private var pending = LibraryChangeSet()
    /// Set when a refresh must re-read everything (an explicit refresh, an oversized burst, or an
    /// index that can't be spliced) rather than splice `pending`.
    @ObservationIgnored private var needsFullReload = true

    /// Diagnostics: how many refreshes re-read the whole library versus spliced a change set.
    /// Exposed so tests can pin the invariant that ordinary saves never re-read the library.
    @ObservationIgnored private(set) var fullReloadCount = 0
    @ObservationIgnored private(set) var spliceCount = 0

    /// Coalesces a save burst into one refresh, and single-flights it so two fetches never run
    /// concurrently and contend with the reader. Created in `start()`, where `self` is fully
    /// initialized.
    @ObservationIgnored private var refreshCoalescer: TrailingCoalescer?

    /// Defers the disk-cache rewrite (see `cacheWriteDelay`).
    @ObservationIgnored private var cacheCoalescer: TrailingCoalescer?

    init(
        container: ModelContainer,
        cache: SummaryIndexCache = .shared,
        anchorProvider: @escaping () -> String? = { AppSettings().timelineAnchorIdentifier }
    ) {
        self.container = container
        self.cache = cache
        self.anchorProvider = anchorProvider
    }

    /// Begin observing saves and run the first load. Idempotent.
    ///
    /// `ModelContext.didSave` names the exact rows that changed, so the index is **spliced**. It
    /// fires for every save made through a SwiftData `ModelContext` — every local write
    /// (`SyncWriter`, starring, image registration) — which is the only write path there is now
    /// that CloudKit mirroring is gone (`AppContainer.shared` no longer configures a
    /// `cloudKitDatabase`, so there is no below-SwiftData remote-merge path left to observe).
    func start() {
        guard observer == nil else { return }
        refreshCoalescer = TrailingCoalescer(interval: .milliseconds(200)) { [weak self] in
            await self?.applyPending()
        }
        cacheCoalescer = TrailingCoalescer(interval: Self.cacheWriteDelay) { [weak self] in
            guard let self else { return }
            await cache.save(summaries)
        }
        observer = NotificationCenter.default.addObserver(
            forName: ModelContext.didSave, object: nil, queue: .main
        ) { [weak self] note in
            let change = LibraryChangeSet(userInfo: note.userInfo)
            // Nothing in the timeline moved (a feed logo, a tag rename, a `StoredImage` row) —
            // don't pay for a refresh at all.
            guard !change.isEmpty else { return }
            Task { @MainActor [weak self] in self?.enqueue(change) }
        }
        defaultsObserver = NotificationCenter.default.addObserver(
            forName: UserDefaults.didChangeNotification, object: nil, queue: .main
        ) { [weak self] _ in
            Task { @MainActor [weak self] in self?.recomputeBrowsingArticles() }
        }
        Task { await bootstrap() }
    }

    /// Fold a save's changes into the pending set and arm the coalescer.
    private func enqueue(_ change: LibraryChangeSet) {
        pending.formUnion(change)
        refreshCoalescer?.schedule()
    }

    /// Cold-start path: publish a fast first dataset (disk cache when present, else an
    /// anchor-centered DB window) and flip `hasLoaded`, yield so SwiftUI can build the pager off
    /// it, then reconcile to the authoritative full load.
    func bootstrap() async {
        await publishFastDataset()
        // Let the reader build + adopt the warmed web view before the full DB fetch competes for
        // the main thread; the full load self-heals the displayed position by identifier, so
        // deferring it never strands the anchor.
        await Task.yield()
        // Through `refreshNow` rather than `fullLoad` directly, so it drains anything a save
        // enqueued during launch and clears `needsFullReload` under the same rules.
        await refreshNow()
    }

    /// Publish the fast first dataset (disk cache, else an anchor-centered DB window) and flip
    /// `hasLoaded`. Does NOT reconcile to the full DB — `bootstrap()` does that after a yield.
    ///
    /// Assigns `summaries` directly instead of going through `publish`: the anchor window is a
    /// *partial* index, and writing it to the disk cache would leave the next cold start painting a
    /// 51-row timeline. The cache is only ever rewritten from a full load or a splice on top of one.
    func publishFastDataset() async {
        if let cached = await StartupTrace.measure("ArticleStore.cache.load", { await cache.load() }) {
            summaries = cached
        } else {
            let container = container
            let anchor = anchorProvider()
            let window = await StartupTrace.measure("ArticleStore.loadWindow") { () -> [ArticleSummary] in
                // `OffMainActor`: a `@ModelActor` runs on its caller's thread, so awaiting the
                // loader straight from here would put the fetch on the main thread.
                await OffMainActor.run(priority: .userInitiated) {
                    let loader = ArticleSummaryLoader(modelContainer: container)
                    return (try? await loader.loadWindow(
                        around: anchor, radius: Self.windowRadius
                    )) ?? []
                }
            }
            summaries = window
        }
        recomputeBrowsingArticles()
        hasLoaded = true
        StartupTrace.event("ArticleStore.hasLoaded")
    }

    /// Re-read the whole index and publish it, now — the "make the index authoritative" entry
    /// point, for callers that can't know what changed. Splicing is the *observer's* optimisation;
    /// an explicit refresh always reloads in full.
    ///
    /// Routed through the coalescer so it is **single-flighted with the debounced path**. Both read
    /// `pending` and then `summaries` across an `await`; running two concurrently would let one
    /// drain the change set while the other merges against a stale index, silently losing rows.
    func refreshNow() async {
        needsFullReload = true
        if let refreshCoalescer {
            await refreshCoalescer.fireNow()
        } else {
            await applyPending()   // not started (tests, cold paths) — nothing to race with
        }
    }

    /// Splice the named rows when possible, otherwise re-read everything.
    private func applyPending() async {
        let change = pending
        let mustReload = needsFullReload
            || change.count > Self.spliceLimit
            || !SummaryIndexMerge.isSpliceable(summaries)
        pending = LibraryChangeSet()
        needsFullReload = false

        if mustReload {
            await fullLoad()
        } else {
            await splice(change)
        }
        hasLoaded = true
    }

    /// Re-read only the rows a save named and merge them into the index — work proportional to the
    /// change, not to the library. A feed update that adds 20 articles costs a 20-row fetch instead
    /// of re-reading all 6 000.
    private func splice(_ change: LibraryChangeSet) async {
        guard !change.isEmpty else { return }
        spliceCount += 1
        let container = container
        let ids = change.changed
        let changed = await StartupTrace.measure("ArticleStore.splice") { () -> [ArticleSummary] in
            await OffMainActor.run(priority: .userInitiated) {
                let loader = ArticleSummaryLoader(modelContainer: container)
                return (try? await loader.summaries(for: ids)) ?? []
            }
        }
        // Rows named as changed but absent from the store were deleted between the save and this
        // fetch; dropping them is the same outcome the delete itself would have produced.
        let removed = Set(change.deleted).union(
            Set(change.changed).subtracting(changed.compactMap(\.persistentID))
        )
        publish(SummaryIndexMerge.apply(to: summaries, changed: changed, removed: removed))
    }

    /// Fetch the entire light index off-main, publish it, and refresh the disk cache.
    ///
    /// The fetch **must** stay inside `OffMainActor`. `ArticleSummaryLoader` being a `@ModelActor`
    /// does not put it on a background thread — a `@ModelActor` executes on its caller's thread —
    /// so awaiting it directly from this `@MainActor` type ran the whole full-library fetch on the
    /// main thread, a ~300 ms UI freeze each time (`SyncReactionMainThreadTests` guards it).
    private func fullLoad() async {
        fullReloadCount += 1
        let container = container
        let all = await StartupTrace.measure("ArticleStore.fullLoad") { () -> [ArticleSummary] in
            await OffMainActor.run(priority: .userInitiated) {
                let loader = StartupTrace.measure("fullLoad.loaderInit") {
                    ArticleSummaryLoader(modelContainer: container)
                }
                return (try? await loader.load()) ?? []
            }
        }
        publish(all)
    }

    /// Publish a new index and schedule the disk-cache rewrite.
    ///
    /// Assigning an identical array would still be an observable mutation: SwiftUI would re-run the
    /// timeline filter and the pager would reconcile its pages, for nothing. A CloudKit reconcile
    /// that finds no local difference is exactly that case, so the equality check pays for itself.
    private func publish(_ next: [ArticleSummary]) {
        guard next != summaries else { return }
        summaries = next
        UnreadBadgeUpdater.refresh(summaries: next)
        recomputeBrowsingArticles()
        cacheCoalescer?.schedule()
    }

    /// Re-derive `browsingArticles` from the current `summaries` and filter settings. Called
    /// whenever either changes — see `browsingArticles`'s doc comment.
    private func recomputeBrowsingArticles() {
        let byTag = TagFilter.apply(
            to: summaries,
            disabledTagNames: settings.disabledTagNames,
            includeUntagged: settings.includeUntagged
        )
        let byFeed = FeedFilter.apply(to: byTag, disabledFeedNames: settings.disabledFeedNames)
        let canonical = StarredFilter.apply(to: byFeed, starredOnly: settings.starredOnly)
        let next = TimelinePinning.apply(to: canonical, pinning: settings.timelineAnchorIdentifier)
        guard next != browsingArticles else { return }
        browsingArticles = next
    }

    /// Flush the deferred disk-cache write now — for scene-background, where the app may be
    /// suspended before `cacheWriteDelay` elapses.
    func flushCache() async {
        await cacheCoalescer?.fireNow()
    }

    isolated deinit {
        if let observer { NotificationCenter.default.removeObserver(observer) }
        if let defaultsObserver { NotificationCenter.default.removeObserver(defaultsObserver) }
    }
}
